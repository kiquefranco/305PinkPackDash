-- =====================================================================
-- Migration 003: member details, the provider directory, and the
-- fields each service actually needs
-- Run once in Supabase: SQL Editor > New query > paste > Run.
-- Safe to re-run. Run 001 and 002 first.
--
-- From Rosemary's 11/10 notes:
--   members need to see when they joined, when their funding runs out,
--   and what they can spend it on, with the real vendors and prices.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Member details
--    member_since is a real join date, not the day they were typed into
--    this dashboard: Pink Pack has been running since 2020.
--    services_expire_on null means the funding does not expire.
-- ---------------------------------------------------------------------
alter table public.clients
  add column if not exists member_since       date,
  add column if not exists member_group       text,
  add column if not exists services_expire_on date;

-- Existing members: fall back to the day they were added, which is the
-- best date on hand. Staff can correct it.
update public.clients set member_since = created_at::date where member_since is null;

alter table public.clients drop constraint if exists clients_member_group_check;
alter table public.clients
  add constraint clients_member_group_check check (
    member_group is null or member_group in ('early_stage', 'thriver'));

-- ---------------------------------------------------------------------
-- 2. Provider directory
--    Self-care vendors members contact themselves. The cost is what
--    comes off their balance per session.
-- ---------------------------------------------------------------------
create table if not exists public.providers (
  id            uuid primary key default gen_random_uuid(),
  name          text not null,
  service_type  text not null default 'self_care' check (service_type in
                  ('ride', 'self_care', 'gift_card', 'child_care')),
  session_cost  numeric(12,2) check (session_cost is null or session_cost > 0),
  cost_varies   boolean not null default false,
  contact_name  text,
  contact_phone text,
  address       text,
  languages     text,
  in_home       boolean not null default false,
  notes         text,
  active        boolean not null default true,
  sort_order    int not null default 100,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index if not exists providers_type_idx on public.providers(service_type, active);

-- Names are unique so re-running this file cannot create a second copy
-- of a vendor. Any duplicates from an earlier run are collapsed first,
-- keeping the oldest row so staff edits and references survive.
delete from public.providers p
using public.providers q
where p.name = q.name and p.ctid > q.ctid;

alter table public.providers drop constraint if exists providers_name_key;
alter table public.providers add constraint providers_name_key unique (name);

-- Rosemary's current vendors. Matched on name, so re-running does not
-- duplicate them and staff edits made later are not overwritten.
insert into public.providers
  (name, service_type, session_cost, contact_name, contact_phone, address, languages, in_home, notes, sort_order)
values
  ('Oncology Massage Center', 'self_care', 100, null, '305-281-1147',
   '9555 N. Kendall Dr Suite 201, Miami, FL 33176', null, false,
   'Text to book.', 10),
  ('Root Hands Corp Massage', 'self_care', 100, 'Dahomey Silva', '786-763-9013',
   null, 'English and Spanish', true,
   'Massage in your home. En su casa. Text to book.', 20),
  ('Acupuncture Center for Wellness', 'self_care', 55, null, '786-716-8774',
   '7550 S. Red Road Suite #116, South Miami, FL 33143', 'English and Spanish', false,
   'Stress reducing auricular acupuncture. Acupuntura para bajar el estres. Text to book.', 30),
  ('JadeMaxx Henna Temporary Tattoo', 'self_care', 100, 'JadeMaxx', '636-293-3655',
   null, 'English only', false,
   'Cost is approximate. Text to book.', 40)
on conflict (name) do nothing;

-- ---------------------------------------------------------------------
-- 3. Fields each service needs
--    Self-care points at a provider. Gift cards need a store and how it
--    is delivered. Child care names a vendor Pink Pack pays directly.
-- ---------------------------------------------------------------------
alter table public.service_requests
  add column if not exists provider_id        uuid references public.providers(id) on delete set null,
  add column if not exists gift_card_store    text,
  add column if not exists gift_card_format   text,
  add column if not exists gift_card_delivery text,
  add column if not exists child_care_type    text,
  add column if not exists vendor_name        text,
  add column if not exists vendor_contact     text,
  add column if not exists service_period     text;

alter table public.service_requests
  drop constraint if exists service_requests_gift_card_store_check,
  drop constraint if exists service_requests_gift_card_format_check,
  drop constraint if exists service_requests_gift_card_delivery_check,
  drop constraint if exists service_requests_aldi_physical_check,
  drop constraint if exists service_requests_child_care_type_check;

alter table public.service_requests
  add constraint service_requests_gift_card_store_check check (
    gift_card_store is null or gift_card_store in ('walmart', 'publix', 'aldi')),
  add constraint service_requests_gift_card_format_check check (
    gift_card_format is null or gift_card_format in ('physical', 'electronic')),
  add constraint service_requests_gift_card_delivery_check check (
    gift_card_delivery is null or gift_card_delivery in ('pickup', 'mail')),
  -- Aldi cards only exist as physical cards.
  add constraint service_requests_aldi_physical_check check (
    gift_card_store <> 'aldi' or gift_card_format is distinct from 'electronic'),
  add constraint service_requests_child_care_type_check check (
    child_care_type is null or child_care_type in
      ('tuition', 'before_after_care', 'day_camp', 'day_care', 'transportation'));

-- ---------------------------------------------------------------------
-- 4. Housekeeping
-- ---------------------------------------------------------------------
drop trigger if exists touch_providers on public.providers;
create trigger touch_providers before update on public.providers
  for each row execute function public.touch_updated_at();

drop trigger if exists audit_providers on public.providers;
create trigger audit_providers after insert or update or delete on public.providers
  for each row execute function public.write_audit();

alter table public.providers enable row level security;
revoke all on public.providers from anon;
grant select, insert, update, delete on public.providers to authenticated;

drop policy if exists providers_staff_all on public.providers;
create policy providers_staff_all on public.providers for all to authenticated
  using (public.is_staff()) with check (public.is_staff());

do $$
begin
  begin
    alter publication supabase_realtime add table public.providers;
  exception when duplicate_object then null;
  end;
end $$;

-- ---------------------------------------------------------------------
-- 5. What the member's own page can read
--    Keyed on their private link. Treatment information is deliberately
--    not returned: Rosemary asked for none of it to reach this page.
--    get_member_portal itself is defined in section 7, once the
--    committed and available columns exist.
-- ---------------------------------------------------------------------

-- The service catalog as the member sees it.
create or replace function public.list_member_providers(p_token text)
returns table (
  id            uuid,
  name          text,
  service_type  text,
  session_cost  numeric,
  cost_varies   boolean,
  contact_name  text,
  contact_phone text,
  address       text,
  languages     text,
  in_home       boolean,
  notes         text
)
language sql stable security definer set search_path = public as $$
  select p.id, p.name, p.service_type, p.session_cost, p.cost_varies,
         p.contact_name, p.contact_phone, p.address, p.languages, p.in_home, p.notes
  from public.providers p
  where p.active
    and exists (select 1 from public.clients c
                where c.request_token = p_token and c.request_link_active)
  order by p.service_type, p.sort_order, p.name
$$;

-- ---------------------------------------------------------------------
-- 6. Submitting a request, with what each service needs
--    Replaces the version from 001.
-- ---------------------------------------------------------------------
drop function if exists public.submit_service_request(text, text, timestamptz, text, text, text, text, boolean, timestamptz, text, numeric);

create or replace function public.submit_service_request(
  p_token              text,
  p_service_type       text,
  p_needed_at          timestamptz,
  p_reason_category    text,
  p_pickup_address     text default null,
  p_dropoff_address    text default null,
  p_reason_details     text default null,
  p_return_trip        boolean default false,
  p_return_at          timestamptz default null,
  p_contact_phone      text default null,
  p_requested_amount   numeric default null,
  p_provider_id        uuid default null,
  p_gift_card_store    text default null,
  p_gift_card_format   text default null,
  p_gift_card_delivery text default null,
  p_child_care_type    text default null,
  p_vendor_name        text default null,
  p_vendor_contact     text default null,
  p_service_period     text default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_client    uuid;
  v_expires   date;
  v_open      int;
  v_id        uuid;
  v_ride      boolean := p_service_type = 'ride';
  v_remaining numeric;
  v_amount    numeric := p_requested_amount;
  v_cost      numeric;
  v_varies    boolean;
begin
  select id, services_expire_on into v_client, v_expires
  from public.clients
  where request_token = p_token and request_link_active;
  if v_client is null then
    raise exception 'This request link is not valid. Please contact 305 Pink Pack.';
  end if;
  perform set_config('app.actor', 'member request form', true);

  -- Supabase runs in UTC. Compared against the UTC date, a member in
  -- Miami loses the evening of their last day, so the comparison is
  -- made against the local date instead.
  if v_expires is not null
     and v_expires < (current_timestamp at time zone 'America/New_York')::date then
    raise exception 'Your direct services ended on %. Please contact 305 Pink Pack.',
      to_char(v_expires, 'Mon DD, YYYY');
  end if;

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
  if p_needed_at > now() + interval '365 days' then
    raise exception 'Please choose a date within the next year.';
  end if;

  -- Per-service rules.
  if v_ride then
    if coalesce(trim(p_pickup_address), '') = '' or coalesce(trim(p_dropoff_address), '') = '' then
      raise exception 'Please enter both a pickup and a destination address.';
    end if;
    if p_return_trip and (p_return_at is null or p_return_at <= p_needed_at) then
      raise exception 'Please choose a return time after the pickup time.';
    end if;

  elsif p_service_type = 'self_care' then
    if p_provider_id is null then
      raise exception 'Please choose which self-care service you want.';
    end if;
    select session_cost, cost_varies into v_cost, v_varies
    from public.providers where id = p_provider_id and active and service_type = 'self_care';
    if v_cost is null and not coalesce(v_varies, false) then
      raise exception 'That service is not available right now. Please contact 305 Pink Pack.';
    end if;
    -- The price comes from the directory, never from the member's browser.
    v_amount := v_cost;

  elsif p_service_type = 'gift_card' then
    if p_gift_card_store is null or p_gift_card_store not in ('walmart', 'publix', 'aldi') then
      raise exception 'Please choose a store.';
    end if;
    if p_gift_card_format is null or p_gift_card_format not in ('physical', 'electronic') then
      raise exception 'Please choose a physical or electronic card.';
    end if;
    if p_gift_card_store = 'aldi' and p_gift_card_format = 'electronic' then
      raise exception 'Aldi cards are available as physical cards only.';
    end if;
    if p_gift_card_format = 'physical'
       and (p_gift_card_delivery is null or p_gift_card_delivery not in ('pickup', 'mail')) then
      raise exception 'Please choose whether you will pick the card up or have it mailed.';
    end if;
    if coalesce(v_amount, 0) <= 0 then
      raise exception 'Please enter how much you need on the card.';
    end if;

  elsif p_service_type = 'child_care' then
    if p_child_care_type is null or p_child_care_type not in
       ('tuition', 'before_after_care', 'day_camp', 'day_care', 'transportation') then
      raise exception 'Please choose which kind of child care this is.';
    end if;
    if coalesce(trim(p_vendor_name), '') = '' then
      raise exception 'Please enter the name of the provider we would pay.';
    end if;
    if coalesce(trim(p_vendor_contact), '') = '' then
      raise exception 'Please enter a phone number or email for the provider.';
    end if;
    if coalesce(trim(p_service_period), '') = '' then
      raise exception 'Please describe the dates or times the care covers.';
    end if;
    if coalesce(v_amount, 0) <= 0 then
      raise exception 'Please enter the total cost.';
    end if;
  end if;

  if v_amount is not null and v_amount <= 0 then
    raise exception 'Please enter an amount greater than zero.';
  end if;

  -- Members cannot ask for more than is actually available to them,
  -- which is their balance minus whatever is already waiting on review.
  if coalesce(v_amount, 0) > 0 then
    select available into v_remaining from public.client_balances where client_id = v_client;
    if coalesce(v_remaining, 0) < v_amount then
      raise exception 'You have % available, and this request is for %. Requests already waiting for review are counted.',
        to_char(coalesce(v_remaining, 0), 'FM$999,999,990.00'),
        to_char(v_amount, 'FM$999,999,990.00');
    end if;
  end if;

  select count(*) into v_open from public.service_requests
  where client_id = v_client and status in ('submitted', 'in_review');
  if v_open >= 5 then
    raise exception 'You already have 5 requests waiting for review. Please contact 305 Pink Pack.';
  end if;

  insert into public.service_requests(
    client_id, service_type, needed_at,
    pickup_address, dropoff_address, return_trip, return_at,
    reason_category, reason_details, contact_phone, requested_amount,
    provider_id, gift_card_store, gift_card_format, gift_card_delivery,
    child_care_type, vendor_name, vendor_contact, service_period)
  values (
    v_client, p_service_type, p_needed_at,
    case when v_ride then left(trim(p_pickup_address), 300) end,
    case when v_ride then left(trim(p_dropoff_address), 300) end,
    v_ride and coalesce(p_return_trip, false),
    case when v_ride and p_return_trip then p_return_at end,
    p_reason_category,
    nullif(left(trim(coalesce(p_reason_details, '')), 300), ''),
    nullif(left(trim(coalesce(p_contact_phone, '')), 30), ''),
    v_amount,
    case when p_service_type = 'self_care'  then p_provider_id end,
    case when p_service_type = 'gift_card'  then p_gift_card_store end,
    case when p_service_type = 'gift_card'  then p_gift_card_format end,
    case when p_service_type = 'gift_card' and p_gift_card_format = 'physical'
         then p_gift_card_delivery end,
    case when p_service_type = 'child_care' then p_child_care_type end,
    case when p_service_type = 'child_care' then left(trim(p_vendor_name), 200) end,
    case when p_service_type = 'child_care' then left(trim(p_vendor_contact), 200) end,
    case when p_service_type = 'child_care' then left(trim(p_service_period), 300) end)
  returning id into v_id;

  return v_id;
end $$;

revoke all on function public.list_member_providers(text) from public;
revoke all on function public.submit_service_request(text, text, timestamptz, text, text, text, text, boolean, timestamptz, text, numeric, uuid, text, text, text, text, text, text, text) from public;
grant execute on function public.list_member_providers(text) to anon, authenticated;
grant execute on function public.submit_service_request(text, text, timestamptz, text, text, text, text, boolean, timestamptz, text, numeric, uuid, text, text, text, text, text, text, text) to anon, authenticated;

-- ---------------------------------------------------------------------
-- 7. Money that is promised but not yet paid
--    Without this a member can submit four requests that each fit
--    inside their balance but together go well past it. The booking
--    check would catch it later, after staff had already approved work
--    the funds cannot cover. Counting open requests as committed shows
--    the member a number they can actually spend.
--
--    An open request stops being committed once it is paid, at which
--    point the charge itself is counted instead.
-- ---------------------------------------------------------------------
-- Replaced rather than altered: the new columns sit before
-- last_granted_on, and "create or replace view" cannot reorder columns.
drop view if exists public.client_balances;
create view public.client_balances
with (security_invoker = true) as
select
  c.id as client_id,
  coalesce(a.allocated, 0)::numeric(12,2) as allocated,
  coalesce(s.spent, 0)::numeric(12,2)     as spent,
  (coalesce(a.allocated, 0) - coalesce(s.spent, 0))::numeric(12,2) as remaining,
  coalesce(p.committed, 0)::numeric(12,2) as committed,
  (coalesce(a.allocated, 0) - coalesce(s.spent, 0) - coalesce(p.committed, 0))::numeric(12,2)
    as available,
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
) s on s.client_id = c.id
left join (
  select r.client_id, sum(r.requested_amount) as committed
  from public.service_requests r
  where r.status in ('submitted', 'in_review', 'approved')
    and r.requested_amount is not null
    and not exists (select 1 from public.resource_transactions t
                    where t.service_request_id = r.id)
  group by r.client_id
) p on p.client_id = c.id;

revoke all on public.client_balances from anon;
grant select on public.client_balances to authenticated;

-- The member's page and the submit check both work off what is actually
-- available, not what is merely unspent. Dropped first because the
-- returned columns change, which "create or replace" will not do.
drop function if exists public.get_member_portal(text);
create function public.get_member_portal(p_token text)
returns table (
  first_name         text,
  member_since       date,
  member_group       text,
  services_expire_on date,
  expired            boolean,
  allocated          numeric,
  spent              numeric,
  committed          numeric,
  remaining          numeric,
  available          numeric
)
language sql stable security definer set search_path = public as $$
  select c.first_name,
         c.member_since,
         c.member_group,
         c.services_expire_on,
         (c.services_expire_on is not null
          and c.services_expire_on
              < (current_timestamp at time zone 'America/New_York')::date) as expired,
         b.allocated, b.spent, b.committed, b.remaining, b.available
  from public.clients c
  join public.client_balances b on b.client_id = c.id
  where c.request_token = p_token and c.request_link_active
$$;

revoke all on function public.get_member_portal(text) from public;
grant execute on function public.get_member_portal(text) to anon, authenticated;
