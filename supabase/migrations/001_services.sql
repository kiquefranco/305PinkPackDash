-- =====================================================================
-- Migration 001: rides become one service among several
-- Run once in Supabase: Dashboard > SQL Editor > New query > paste > Run.
-- Safe to re-run.
--
-- What changes:
--   ride_requests            -> service_requests, with a service_type column
--   pickup_at                -> needed_at (every service has a date it is needed)
--   pickup/dropoff addresses -> optional, required only for rides
--   book_ride()              -> fulfill_request()
--   submit_ride_request()    -> submit_service_request()
--   resource_transactions.ride_request_id -> service_request_id
--
-- No client, resource, staff or audit data is moved or deleted.
-- Existing rows become service_type = 'ride'.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Rename the table and its ride-specific column
-- ---------------------------------------------------------------------
do $$
begin
  if to_regclass('public.ride_requests') is not null
     and to_regclass('public.service_requests') is null then
    alter table public.ride_requests rename to service_requests;
  end if;
end $$;

do $$
begin
  if exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = 'service_requests'
               and column_name = 'pickup_at') then
    alter table public.service_requests rename column pickup_at to needed_at;
  end if;
end $$;

do $$
begin
  if exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = 'resource_transactions'
               and column_name = 'ride_request_id') then
    alter table public.resource_transactions rename column ride_request_id to service_request_id;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 2. New columns
-- ---------------------------------------------------------------------
alter table public.service_requests
  add column if not exists service_type    text not null default 'ride',
  add column if not exists requested_amount numeric(12,2),
  add column if not exists provider_name   text;

-- ride_provider was the Lyft/Uber field. It becomes the generic provider
-- for every service: the massage therapist, the store, the care agency.
do $$
begin
  if exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = 'service_requests'
               and column_name = 'ride_provider') then
    update public.service_requests
       set provider_name = coalesce(provider_name, ride_provider)
     where ride_provider is not null;
    alter table public.service_requests drop column ride_provider;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 3. Addresses become optional; rides still require them
-- ---------------------------------------------------------------------
alter table public.service_requests alter column pickup_address  drop not null;
alter table public.service_requests alter column dropoff_address drop not null;

-- ---------------------------------------------------------------------
-- 4. Constraints
-- ---------------------------------------------------------------------
-- Constraints created before the rename still carry the old name.
-- Rename them so a later migration can find them.
do $$
declare r record;
begin
  for r in
    select conname from pg_constraint
    where conrelid = 'public.service_requests'::regclass
      and conname like 'ride\_requests\_%'
  loop
    execute format('alter table public.service_requests rename constraint %I to %I',
                   r.conname, replace(r.conname, 'ride_requests_', 'service_requests_'));
  end loop;
end $$;

alter table public.service_requests
  drop constraint if exists ride_requests_reason_category_check,
  drop constraint if exists service_requests_reason_category_check,
  drop constraint if exists service_requests_service_type_check,
  drop constraint if exists service_requests_ride_addresses_check,
  drop constraint if exists service_requests_requested_amount_check;

alter table public.service_requests
  add constraint service_requests_service_type_check check (service_type in
    ('ride', 'self_care', 'gift_card', 'child_care')),
  add constraint service_requests_reason_category_check check (reason_category in
    ('treatment', 'doctor_visit', 'labs_scans', 'pharmacy', 'support_service',
     'groceries', 'household', 'wellness', 'child_care', 'other')),
  add constraint service_requests_ride_addresses_check check (
    service_type <> 'ride'
    or (coalesce(trim(pickup_address), '') <> '' and coalesce(trim(dropoff_address), '') <> '')),
  add constraint service_requests_requested_amount_check check (
    requested_amount is null or requested_amount > 0);

-- ---------------------------------------------------------------------
-- 5. Indexes
-- ---------------------------------------------------------------------
alter index if exists ride_requests_status_idx rename to service_requests_status_idx;
alter index if exists ride_requests_client_idx rename to service_requests_client_idx;
create index if not exists service_requests_type_idx on public.service_requests(service_type);

-- ---------------------------------------------------------------------
-- 6. Triggers under their new names
-- ---------------------------------------------------------------------
drop trigger if exists touch_ride_requests on public.service_requests;
drop trigger if exists touch_service_requests on public.service_requests;
create trigger touch_service_requests before update on public.service_requests
  for each row execute function public.touch_updated_at();

drop trigger if exists audit_ride_requests on public.service_requests;
drop trigger if exists audit_service_requests on public.service_requests;
create trigger audit_service_requests after insert or update or delete on public.service_requests
  for each row execute function public.write_audit();

-- ---------------------------------------------------------------------
-- 7. Policies and grants under the new table name
-- ---------------------------------------------------------------------
alter table public.service_requests enable row level security;
revoke all on public.service_requests from anon;
grant select, insert, update, delete on public.service_requests to authenticated;

drop policy if exists ride_requests_staff_all on public.service_requests;
drop policy if exists service_requests_staff_all on public.service_requests;
create policy service_requests_staff_all on public.service_requests for all to authenticated
  using (public.is_staff()) with check (public.is_staff());

-- ---------------------------------------------------------------------
-- 8. Replace the old functions
-- ---------------------------------------------------------------------
drop function if exists public.submit_ride_request(text, timestamptz, text, text, text, text, boolean, timestamptz, text);
drop function if exists public.book_ride(uuid, text, text, uuid, numeric);

-- Checks a link and returns only the client's first name.
create or replace function public.check_request_link(p_token text)
returns table (first_name text)
language sql stable security definer set search_path = public as $$
  select c.first_name
  from public.clients c
  where c.request_token = p_token and c.request_link_active
$$;

-- Submits any service request through a client's private link.
-- Rides require a pickup and destination; the other services do not.
create or replace function public.submit_service_request(
  p_token            text,
  p_service_type     text,
  p_needed_at        timestamptz,
  p_reason_category  text,
  p_pickup_address   text default null,
  p_dropoff_address  text default null,
  p_reason_details   text default null,
  p_return_trip      boolean default false,
  p_return_at        timestamptz default null,
  p_contact_phone    text default null,
  p_requested_amount numeric default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_client uuid;
  v_open   int;
  v_id     uuid;
  v_ride   boolean := p_service_type = 'ride';
begin
  select id into v_client from public.clients
  where request_token = p_token and request_link_active;
  if v_client is null then
    raise exception 'This request link is not valid. Please contact 305 Pink Pack.';
  end if;
  perform set_config('app.actor', 'client request form', true);

  if p_service_type is null or p_service_type not in
     ('ride', 'self_care', 'gift_card', 'child_care') then
    raise exception 'Please choose which kind of support you need.';
  end if;

  if p_reason_category is null or p_reason_category not in
     ('treatment', 'doctor_visit', 'labs_scans', 'pharmacy', 'support_service',
      'groceries', 'household', 'wellness', 'child_care', 'other') then
    raise exception 'Please choose why you need this.';
  end if;

  if p_needed_at is null or p_needed_at < now() - interval '1 hour' then
    raise exception 'Please choose a date and time in the future.';
  end if;
  if p_needed_at > now() + interval '180 days' then
    raise exception 'Please choose a date within the next 6 months.';
  end if;

  if v_ride then
    if coalesce(trim(p_pickup_address), '') = '' or coalesce(trim(p_dropoff_address), '') = '' then
      raise exception 'Please enter both a pickup and a destination address.';
    end if;
    if p_return_trip and (p_return_at is null or p_return_at <= p_needed_at) then
      raise exception 'Please choose a return time after the pickup time.';
    end if;
  end if;

  if p_requested_amount is not null and p_requested_amount <= 0 then
    raise exception 'Please enter an amount greater than zero.';
  end if;

  select count(*) into v_open from public.service_requests
  where client_id = v_client and status in ('submitted', 'in_review');
  if v_open >= 5 then
    raise exception 'You already have 5 requests waiting for review. Please contact 305 Pink Pack.';
  end if;

  insert into public.service_requests(client_id, service_type, needed_at,
    pickup_address, dropoff_address, return_trip, return_at,
    reason_category, reason_details, contact_phone, requested_amount)
  values (v_client, p_service_type, p_needed_at,
    case when v_ride then left(trim(p_pickup_address), 300) end,
    case when v_ride then left(trim(p_dropoff_address), 300) end,
    v_ride and coalesce(p_return_trip, false),
    case when v_ride and p_return_trip then p_return_at end,
    p_reason_category, nullif(left(trim(coalesce(p_reason_details, '')), 300), ''),
    nullif(left(trim(coalesce(p_contact_phone, '')), 30), ''),
    p_requested_amount)
  returning id into v_id;

  return v_id;
end $$;

-- Saves who provided the service and what it cost, in one step.
-- Re-running it replaces the earlier charge for that request.
create or replace function public.fulfill_request(
  p_request_id    uuid,
  p_provider      text,
  p_confirmation  text,
  p_resource_id   uuid default null,
  p_amount_used   numeric default null
) returns void
language plpgsql security invoker set search_path = public as $$
declare
  v_status text;
  v_type   text;
  v_name   text;
  v_label  text;
begin
  if not public.is_staff() then
    raise exception 'Not authorized.';
  end if;
  select r.status, r.service_type, trim(c.first_name || ' ' || c.last_name)
    into v_status, v_type, v_name
  from public.service_requests r join public.clients c on c.id = r.client_id
  where r.id = p_request_id;
  if v_status is null then raise exception 'Request not found.'; end if;
  if v_status not in ('approved', 'fulfilled') then
    raise exception 'Approve the request before booking it.';
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

-- Used by the GitHub Action that stops the free project from pausing.
create or replace function public.keepalive()
returns timestamptz language sql stable as $$ select now() $$;

revoke all on function public.check_request_link(text) from public;
revoke all on function public.submit_service_request(text, text, timestamptz, text, text, text, text, boolean, timestamptz, text, numeric) from public;
revoke all on function public.fulfill_request(uuid, text, text, uuid, numeric) from public;
grant execute on function public.check_request_link(text) to anon, authenticated;
grant execute on function public.submit_service_request(text, text, timestamptz, text, text, text, text, boolean, timestamptz, text, numeric) to anon, authenticated;
grant execute on function public.fulfill_request(uuid, text, text, uuid, numeric) to authenticated;
grant execute on function public.keepalive() to anon, authenticated;
grant execute on function public.is_staff(), public.is_admin(), public.current_email() to authenticated;

-- ---------------------------------------------------------------------
-- 9. Live updates follow the renamed table automatically.
--    Audit rows written before this migration still say "ride_requests";
--    that history is left alone on purpose.
-- ---------------------------------------------------------------------
