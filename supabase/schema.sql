-- =====================================================================
-- 305 Pink Pack Dashboard: database schema
-- Run this once in Supabase: Dashboard > SQL Editor > New query > paste > Run.
-- Safe to re-run: it drops and recreates functions, policies and triggers,
-- and only creates tables that do not exist yet.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------

-- People allowed into the dashboard. Google sign-in alone is not enough:
-- the signed-in email must be on this list.
create table if not exists public.staff (
  email       text primary key,
  full_name   text,
  role        text not null default 'staff' check (role in ('admin', 'staff')),
  created_at  timestamptz not null default now()
);

-- People Pink Pack serves. No diagnosis or medical detail is stored.
create table if not exists public.clients (
  id                  uuid primary key default gen_random_uuid(),
  first_name          text not null check (length(trim(first_name)) > 0),
  last_name           text not null default '',
  email               text,
  phone               text,
  in_treatment        boolean not null default true,
  request_token       text not null unique default replace(gen_random_uuid()::text, '-', ''),
  request_link_active boolean not null default true,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

-- Funding pools and voucher stock.
create table if not exists public.resources (
  id          uuid primary key default gen_random_uuid(),
  name        text not null unique,
  kind        text not null check (kind in ('funding', 'voucher')),
  notes       text,
  active      boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- Ride requests submitted through a client's private link.
create table if not exists public.ride_requests (
  id                uuid primary key default gen_random_uuid(),
  client_id         uuid not null references public.clients(id) on delete restrict,
  pickup_at         timestamptz not null,
  pickup_address    text not null,
  dropoff_address   text not null,
  return_trip       boolean not null default false,
  return_at         timestamptz,
  reason_category   text not null check (reason_category in
                      ('treatment', 'doctor_visit', 'labs_scans', 'pharmacy', 'support_service', 'other')),
  reason_details    text check (length(reason_details) <= 300),
  contact_phone     text,
  status            text not null default 'submitted' check (status in
                      ('submitted', 'in_review', 'approved', 'denied', 'fulfilled')),
  decision_note     text,
  ride_provider     text,
  confirmation_code text,
  booked_at         timestamptz,
  fulfilled_at      timestamptz,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);
create index if not exists ride_requests_status_idx on public.ride_requests(status);
create index if not exists ride_requests_client_idx on public.ride_requests(client_id);

-- Every movement of money or vouchers. Positive adds, negative uses.
-- Balance = sum(amount) per resource.
create table if not exists public.resource_transactions (
  id               uuid primary key default gen_random_uuid(),
  resource_id      uuid not null references public.resources(id) on delete restrict,
  amount           numeric(12,2) not null check (amount <> 0),
  description      text not null,
  ride_request_id  uuid unique references public.ride_requests(id) on delete set null,
  occurred_on      date not null default current_date,
  created_by       text,
  created_at       timestamptz not null default now()
);
create index if not exists resource_tx_resource_idx on public.resource_transactions(resource_id);

-- Audit trail. Written only by triggers.
create table if not exists public.audit_log (
  id          bigint generated always as identity primary key,
  table_name  text not null,
  record_id   text,
  action      text not null,
  changed_by  text not null,
  old_data    jsonb,
  new_data    jsonb,
  changed_at  timestamptz not null default now()
);
create index if not exists audit_log_changed_at_idx on public.audit_log(changed_at desc);

-- ---------------------------------------------------------------------
-- 2. Helper functions
-- ---------------------------------------------------------------------

create or replace function public.current_email()
returns text language sql stable as $$
  select lower(coalesce(auth.jwt() ->> 'email', ''))
$$;

create or replace function public.is_staff()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.staff where email = public.current_email())
$$;

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.staff where email = public.current_email() and role = 'admin')
$$;

-- Keeps updated_at current.
create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

-- Writes one audit row per insert, update or delete.
create or replace function public.write_audit()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  actor text := nullif(public.current_email(), '');
  rec_id text;
begin
  actor := coalesce(actor, nullif(current_setting('app.actor', true), ''), 'system (SQL editor)');
  if tg_op = 'DELETE' then
    rec_id := coalesce(to_jsonb(old) ->> 'id', to_jsonb(old) ->> 'email');
    insert into public.audit_log(table_name, record_id, action, changed_by, old_data)
    values (tg_table_name, rec_id, 'delete', actor, to_jsonb(old));
    return old;
  elsif tg_op = 'UPDATE' then
    if to_jsonb(new) - 'updated_at' = to_jsonb(old) - 'updated_at' then
      return new; -- nothing meaningful changed
    end if;
    rec_id := coalesce(to_jsonb(new) ->> 'id', to_jsonb(new) ->> 'email');
    insert into public.audit_log(table_name, record_id, action, changed_by, old_data, new_data)
    values (tg_table_name, rec_id, 'update', actor, to_jsonb(old), to_jsonb(new));
    return new;
  else
    rec_id := coalesce(to_jsonb(new) ->> 'id', to_jsonb(new) ->> 'email');
    insert into public.audit_log(table_name, record_id, action, changed_by, new_data)
    values (tg_table_name, rec_id, 'insert', actor, to_jsonb(new));
    return new;
  end if;
end $$;

-- Stores staff emails in lowercase so sign-in matching never fails on case.
create or replace function public.normalize_staff_email()
returns trigger language plpgsql as $$
begin
  new.email := lower(trim(new.email));
  return new;
end $$;

-- Stamps who recorded a transaction.
create or replace function public.stamp_created_by()
returns trigger language plpgsql as $$
begin
  new.created_by := coalesce(nullif(public.current_email(), ''), new.created_by);
  return new;
end $$;

-- ---------------------------------------------------------------------
-- 3. Triggers
-- ---------------------------------------------------------------------

drop trigger if exists touch_clients on public.clients;
create trigger touch_clients before update on public.clients
  for each row execute function public.touch_updated_at();

drop trigger if exists touch_resources on public.resources;
create trigger touch_resources before update on public.resources
  for each row execute function public.touch_updated_at();

drop trigger if exists touch_ride_requests on public.ride_requests;
create trigger touch_ride_requests before update on public.ride_requests
  for each row execute function public.touch_updated_at();

drop trigger if exists normalize_staff_email on public.staff;
create trigger normalize_staff_email before insert or update on public.staff
  for each row execute function public.normalize_staff_email();

drop trigger if exists stamp_resource_tx on public.resource_transactions;
create trigger stamp_resource_tx before insert on public.resource_transactions
  for each row execute function public.stamp_created_by();

do $$
declare t text;
begin
  foreach t in array array['staff', 'clients', 'resources', 'ride_requests', 'resource_transactions'] loop
    execute format('drop trigger if exists audit_%1$s on public.%1$I', t);
    execute format('create trigger audit_%1$s after insert or update or delete on public.%1$I
                    for each row execute function public.write_audit()', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- 4. Views
-- ---------------------------------------------------------------------

create or replace view public.resource_balances
with (security_invoker = true) as
select r.id, r.name, r.kind, r.notes, r.active,
       coalesce(sum(t.amount), 0)::numeric(12,2) as balance,
       coalesce(sum(t.amount) filter (where t.amount < 0), 0)::numeric(12,2) as total_used,
       count(t.id) as transaction_count
from public.resources r
left join public.resource_transactions t on t.resource_id = r.id
group by r.id;

-- ---------------------------------------------------------------------
-- 5. Row level security
-- Anonymous visitors can read and write nothing directly.
-- Staff on the allowlist can work with everything.
-- Only admins can manage the staff list.
-- ---------------------------------------------------------------------

alter table public.staff                 enable row level security;
alter table public.clients               enable row level security;
alter table public.resources             enable row level security;
alter table public.ride_requests         enable row level security;
alter table public.resource_transactions enable row level security;
alter table public.audit_log             enable row level security;

revoke all on public.staff, public.clients, public.resources, public.ride_requests,
              public.resource_transactions, public.audit_log, public.resource_balances
  from anon;

grant select, insert, update, delete on public.staff, public.clients, public.resources,
      public.ride_requests, public.resource_transactions to authenticated;
grant select on public.audit_log, public.resource_balances to authenticated;

drop policy if exists staff_read on public.staff;
create policy staff_read on public.staff for select to authenticated using (public.is_staff());
drop policy if exists staff_admin_write on public.staff;
create policy staff_admin_write on public.staff for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

do $$
declare t text;
begin
  foreach t in array array['clients', 'resources', 'ride_requests', 'resource_transactions'] loop
    execute format('drop policy if exists %1$s_staff_all on public.%1$I', t);
    execute format('create policy %1$s_staff_all on public.%1$I for all to authenticated
                    using (public.is_staff()) with check (public.is_staff())', t);
  end loop;
end $$;

drop policy if exists audit_staff_read on public.audit_log;
create policy audit_staff_read on public.audit_log for select to authenticated using (public.is_staff());

-- An admin cannot remove or demote themselves, so the dashboard always has an admin.
create or replace function public.protect_self_admin()
returns trigger language plpgsql as $$
begin
  if old.email = public.current_email()
     and (tg_op = 'DELETE' or new.role <> 'admin' or new.email <> old.email) then
    raise exception 'You cannot remove or demote your own admin access.';
  end if;
  return coalesce(new, old);
end $$;
drop trigger if exists protect_self_admin on public.staff;
create trigger protect_self_admin before update or delete on public.staff
  for each row execute function public.protect_self_admin();

-- ---------------------------------------------------------------------
-- 6. Functions the public request form can call
-- A client can only submit with a valid, active private link.
-- ---------------------------------------------------------------------

-- Checks a link and returns only the client's first name.
create or replace function public.check_request_link(p_token text)
returns table (first_name text)
language sql stable security definer set search_path = public as $$
  select c.first_name
  from public.clients c
  where c.request_token = p_token and c.request_link_active
$$;

create or replace function public.submit_ride_request(
  p_token           text,
  p_pickup_at       timestamptz,
  p_pickup_address  text,
  p_dropoff_address text,
  p_reason_category text,
  p_reason_details  text default null,
  p_return_trip     boolean default false,
  p_return_at       timestamptz default null,
  p_contact_phone   text default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_client uuid;
  v_open   int;
  v_id     uuid;
begin
  select id into v_client from public.clients
  where request_token = p_token and request_link_active;
  if v_client is null then
    raise exception 'This request link is not valid. Please contact 305 Pink Pack.';
  end if;
  perform set_config('app.actor', 'client request form', true);

  if p_reason_category is null or p_reason_category not in
     ('treatment', 'doctor_visit', 'labs_scans', 'pharmacy', 'support_service', 'other') then
    raise exception 'Please choose why you need the ride.';
  end if;

  if p_pickup_at is null or p_pickup_at < now() - interval '1 hour' then
    raise exception 'Please choose a pickup time in the future.';
  end if;
  if p_pickup_at > now() + interval '180 days' then
    raise exception 'Please choose a pickup time within the next 6 months.';
  end if;
  if coalesce(trim(p_pickup_address), '') = '' or coalesce(trim(p_dropoff_address), '') = '' then
    raise exception 'Please enter both a pickup and a destination address.';
  end if;
  if p_return_trip and (p_return_at is null or p_return_at <= p_pickup_at) then
    raise exception 'Please choose a return time after the pickup time.';
  end if;

  select count(*) into v_open from public.ride_requests
  where client_id = v_client and status in ('submitted', 'in_review');
  if v_open >= 5 then
    raise exception 'You already have 5 requests waiting for review. Please contact 305 Pink Pack.';
  end if;

  insert into public.ride_requests(client_id, pickup_at, pickup_address, dropoff_address,
    return_trip, return_at, reason_category, reason_details, contact_phone)
  values (v_client, p_pickup_at, left(trim(p_pickup_address), 300), left(trim(p_dropoff_address), 300),
    coalesce(p_return_trip, false), case when p_return_trip then p_return_at end,
    p_reason_category, nullif(left(trim(coalesce(p_reason_details, '')), 300), ''),
    nullif(left(trim(coalesce(p_contact_phone, '')), 30), ''))
  returning id into v_id;

  return v_id;
end $$;

-- ---------------------------------------------------------------------
-- 7. Staff-only functions
-- ---------------------------------------------------------------------

-- Saves booking details and records what the ride cost against a resource,
-- in one step. Re-running it replaces the earlier charge for that ride.
create or replace function public.book_ride(
  p_request_id    uuid,
  p_provider      text,
  p_confirmation  text,
  p_resource_id   uuid default null,
  p_amount_used   numeric default null
) returns void
language plpgsql security invoker set search_path = public as $$
declare
  v_status text;
  v_name   text;
begin
  if not public.is_staff() then
    raise exception 'Not authorized.';
  end if;
  select r.status, c.first_name || ' ' || c.last_name into v_status, v_name
  from public.ride_requests r join public.clients c on c.id = r.client_id
  where r.id = p_request_id;
  if v_status is null then raise exception 'Request not found.'; end if;
  if v_status not in ('approved', 'fulfilled') then
    raise exception 'Approve the request before booking it.';
  end if;

  update public.ride_requests
     set ride_provider = nullif(trim(p_provider), ''),
         confirmation_code = nullif(trim(p_confirmation), ''),
         booked_at = coalesce(booked_at, now())
   where id = p_request_id;

  delete from public.resource_transactions where ride_request_id = p_request_id;
  if p_resource_id is not null and coalesce(p_amount_used, 0) > 0 then
    insert into public.resource_transactions(resource_id, amount, description, ride_request_id)
    values (p_resource_id, -abs(p_amount_used), 'Ride for ' || trim(v_name), p_request_id);
  end if;
end $$;

-- Used by the GitHub Action that stops the free project from pausing.
create or replace function public.keepalive()
returns timestamptz language sql stable as $$ select now() $$;

revoke all on function public.check_request_link(text) from public;
revoke all on function public.submit_ride_request(text, timestamptz, text, text, text, text, boolean, timestamptz, text) from public;
revoke all on function public.book_ride(uuid, text, text, uuid, numeric) from public;
grant execute on function public.check_request_link(text) to anon, authenticated;
grant execute on function public.submit_ride_request(text, timestamptz, text, text, text, text, boolean, timestamptz, text) to anon, authenticated;
grant execute on function public.book_ride(uuid, text, text, uuid, numeric) to authenticated;
grant execute on function public.keepalive() to anon, authenticated;
grant execute on function public.is_staff(), public.is_admin(), public.current_email() to authenticated;

-- ---------------------------------------------------------------------
-- 8. Live updates
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['clients', 'resources', 'ride_requests', 'resource_transactions', 'staff'] loop
    begin
      execute format('alter publication supabase_realtime add table public.%I', t);
    exception when duplicate_object then null;
    end;
  end loop;
end $$;
