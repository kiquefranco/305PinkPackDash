-- =====================================================================
-- Migration 002: every member gets their own funding balance
-- Run once in Supabase: Dashboard > SQL Editor > New query > paste > Run.
-- Safe to re-run. Run 001_services.sql first.
--
-- Why: members did not know what their balance was. Each member now has
-- their own allocation ($2,000 by default, editable), every funded
-- service draws it down, and the dashboard shows what is left.
--
-- Vouchers are counted in units, not dollars, so voucher charges never
-- touch a member's dollar balance.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Settings an admin can change without editing code
-- ---------------------------------------------------------------------
create table if not exists public.app_settings (
  key         text primary key,
  value       text not null,
  description text,
  updated_at  timestamptz not null default now()
);

insert into public.app_settings(key, value, description)
values ('default_allocation', '2000',
        'Dollars granted to each new member automatically. Changing this affects new members only.')
on conflict (key) do nothing;

-- ---------------------------------------------------------------------
-- 2. Allocations. One row per grant, so a top-up or a renewal is just
--    another row and the history stays readable.
-- ---------------------------------------------------------------------
create table if not exists public.client_allocations (
  id          uuid primary key default gen_random_uuid(),
  client_id   uuid not null references public.clients(id) on delete cascade,
  amount      numeric(12,2) not null check (amount <> 0),
  note        text,
  granted_on  date not null default current_date,
  created_by  text,
  created_at  timestamptz not null default now()
);
create index if not exists client_allocations_client_idx
  on public.client_allocations(client_id);

-- ---------------------------------------------------------------------
-- 3. Every new member gets the default allocation automatically
-- ---------------------------------------------------------------------
create or replace function public.grant_default_allocation()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_default numeric;
begin
  select nullif(value, '')::numeric into v_default
  from public.app_settings where key = 'default_allocation';
  if coalesce(v_default, 0) > 0 then
    insert into public.client_allocations(client_id, amount, note, created_by)
    values (new.id, v_default, 'Starting allocation',
            coalesce(nullif(public.current_email(), ''), 'system'));
  end if;
  return new;
end $$;

drop trigger if exists grant_default_allocation on public.clients;
create trigger grant_default_allocation after insert on public.clients
  for each row execute function public.grant_default_allocation();

-- Members who already existed before this migration get theirs too,
-- so nobody is left without a balance. Runs once.
insert into public.client_allocations(client_id, amount, note, created_by)
select c.id,
       coalesce((select nullif(value, '')::numeric from public.app_settings
                 where key = 'default_allocation'), 2000),
       'Starting allocation (backfilled)', 'system'
from public.clients c
where not exists (select 1 from public.client_allocations a where a.client_id = c.id);

-- ---------------------------------------------------------------------
-- 4. Balances
--    Spent counts dollars only: a voucher is a unit of stock, not money,
--    so a voucher charge must never reduce a member's dollar balance.
-- ---------------------------------------------------------------------
create or replace view public.client_balances
with (security_invoker = true) as
select
  c.id as client_id,
  coalesce(a.allocated, 0)::numeric(12,2) as allocated,
  coalesce(s.spent, 0)::numeric(12,2)     as spent,
  (coalesce(a.allocated, 0) - coalesce(s.spent, 0))::numeric(12,2) as remaining,
  a.last_granted_on
from public.clients c
left join (
  select client_id, sum(amount) as allocated, max(granted_on) as last_granted_on
  from public.client_allocations group by client_id
) a on a.client_id = c.id
left join (
  select r.client_id, sum(abs(t.amount)) as spent
  from public.resource_transactions t
  join public.service_requests r on r.id = t.service_request_id
  join public.resources res      on res.id = t.resource_id
  where t.amount < 0 and res.kind = 'funding'
  group by r.client_id
) s on s.client_id = c.id;

-- ---------------------------------------------------------------------
-- 5. Housekeeping: timestamps, audit, security
-- ---------------------------------------------------------------------
drop trigger if exists stamp_client_allocations on public.client_allocations;
create trigger stamp_client_allocations before insert on public.client_allocations
  for each row execute function public.stamp_created_by();

drop trigger if exists touch_app_settings on public.app_settings;
create trigger touch_app_settings before update on public.app_settings
  for each row execute function public.touch_updated_at();

drop trigger if exists audit_client_allocations on public.client_allocations;
create trigger audit_client_allocations after insert or update or delete
  on public.client_allocations
  for each row execute function public.write_audit();

drop trigger if exists audit_app_settings on public.app_settings;
create trigger audit_app_settings after insert or update or delete
  on public.app_settings
  for each row execute function public.write_audit();

alter table public.client_allocations enable row level security;
alter table public.app_settings       enable row level security;
revoke all on public.client_allocations, public.app_settings, public.client_balances from anon;
grant select, insert, update, delete on public.client_allocations to authenticated;
grant select on public.app_settings, public.client_balances to authenticated;
grant update on public.app_settings to authenticated;

drop policy if exists client_allocations_staff_all on public.client_allocations;
create policy client_allocations_staff_all on public.client_allocations for all to authenticated
  using (public.is_staff()) with check (public.is_staff());

-- Any staff member can read settings; only an admin can change them.
drop policy if exists app_settings_staff_read on public.app_settings;
create policy app_settings_staff_read on public.app_settings for select to authenticated
  using (public.is_staff());
drop policy if exists app_settings_admin_write on public.app_settings;
create policy app_settings_admin_write on public.app_settings for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

do $$
begin
  begin
    alter publication supabase_realtime add table public.client_allocations;
  exception when duplicate_object then null;
  end;
  begin
    alter publication supabase_realtime add table public.app_settings;
  exception when duplicate_object then null;
  end;
end $$;

-- ---------------------------------------------------------------------
-- 6. Booking now checks the member's own balance
--    A dollar charge cannot take a member past their allocation.
--    Voucher charges are stock, not dollars, and are not checked here.
-- ---------------------------------------------------------------------
create or replace function public.fulfill_request(
  p_request_id    uuid,
  p_provider      text,
  p_confirmation  text,
  p_resource_id   uuid default null,
  p_amount_used   numeric default null
) returns void
language plpgsql security invoker set search_path = public as $$
declare
  v_status    text;
  v_type      text;
  v_name      text;
  v_label     text;
  v_client    uuid;
  v_kind      text;
  v_remaining numeric;
  v_prior     numeric;
begin
  if not public.is_staff() then
    raise exception 'Not authorized.';
  end if;

  select r.status, r.service_type, r.client_id, trim(c.first_name || ' ' || c.last_name)
    into v_status, v_type, v_client, v_name
  from public.service_requests r join public.clients c on c.id = r.client_id
  where r.id = p_request_id;
  if v_status is null then raise exception 'Request not found.'; end if;
  if v_status not in ('approved', 'fulfilled') then
    raise exception 'Approve the request before booking it.';
  end if;

  -- Check the member's balance before anything is written.
  if p_resource_id is not null and coalesce(p_amount_used, 0) > 0 then
    select kind into v_kind from public.resources where id = p_resource_id;
    if v_kind = 'funding' then
      select remaining into v_remaining from public.client_balances where client_id = v_client;

      -- Re-booking replaces the earlier charge, so that charge is not
      -- competing with the new one. Add it back before comparing.
      select coalesce(abs(t.amount), 0) into v_prior
      from public.resource_transactions t
      join public.resources res on res.id = t.resource_id
      where t.service_request_id = p_request_id and res.kind = 'funding';

      v_remaining := coalesce(v_remaining, 0) + coalesce(v_prior, 0);

      if p_amount_used > v_remaining then
        raise exception
          '% has % left. This charge of % would go over their balance.',
          v_name,
          to_char(v_remaining, 'FM$999,999,990.00'),
          to_char(p_amount_used, 'FM$999,999,990.00');
      end if;
    end if;
  end if;

  update public.service_requests
     set provider_name = nullif(trim(p_provider), ''),
         confirmation_code = nullif(trim(p_confirmation), ''),
         booked_at = coalesce(booked_at, now())
   where id = p_request_id;

  v_label := case v_type
    when 'ride'       then 'Ride'
    when 'self_care'  then 'Self-care service'
    when 'gift_card'  then 'Gift card'
    when 'child_care' then 'Child care'
    else 'Service' end;

  delete from public.resource_transactions where service_request_id = p_request_id;
  if p_resource_id is not null and coalesce(p_amount_used, 0) > 0 then
    insert into public.resource_transactions(resource_id, amount, description, service_request_id)
    values (p_resource_id, -abs(p_amount_used), v_label || ' for ' || v_name, p_request_id);
  end if;
end $$;

revoke all on function public.fulfill_request(uuid, text, text, uuid, numeric) from public;
grant execute on function public.fulfill_request(uuid, text, text, uuid, numeric) to authenticated;
