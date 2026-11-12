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
  member_since        date not null default current_date,
  member_group        text check (member_group is null or member_group in ('early_stage', 'thriver')),
  services_expire_on  date,
  request_token       text not null unique default replace(gen_random_uuid()::text, '-', ''),
  request_link_active boolean not null default true,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

-- Settings an admin can change without editing code.
create table if not exists public.app_settings (
  key         text primary key,
  value       text not null,
  description text,
  updated_at  timestamptz not null default now()
);

-- Money set aside for one member. One row per grant, so a top-up or a
-- renewal is another row and the history stays readable.
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

-- Vendors members can use. Self-care vendors are contacted by the
-- member directly; the cost is what comes off their balance per session.
create table if not exists public.providers (
  id            uuid primary key default gen_random_uuid(),
  name          text not null unique,
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

-- Service requests submitted through a client's private link, or entered
-- by staff for a client who called in. Rides are one service among several.
create table if not exists public.service_requests (
  id                uuid primary key default gen_random_uuid(),
  client_id         uuid not null references public.clients(id) on delete restrict,
  service_type      text not null default 'ride' check (service_type in
                      ('ride', 'self_care', 'gift_card', 'child_care')),
  needed_at         timestamptz not null,
  pickup_address    text,
  dropoff_address   text,
  return_trip       boolean not null default false,
  return_at         timestamptz,
  reason_category   text not null check (reason_category in
                      ('treatment', 'doctor_visit', 'labs_scans', 'pharmacy', 'support_service',
                       'groceries', 'household', 'wellness', 'child_care', 'other')),
  reason_details    text check (length(reason_details) <= 300),
  requested_amount  numeric(12,2) check (requested_amount is null or requested_amount > 0),
  contact_phone     text,
  provider_id        uuid references public.providers(id) on delete set null,
  gift_card_store    text check (gift_card_store is null or gift_card_store in
                       ('walmart', 'publix', 'aldi')),
  gift_card_format   text check (gift_card_format is null or gift_card_format in
                       ('physical', 'electronic')),
  gift_card_delivery text check (gift_card_delivery is null or gift_card_delivery in
                       ('pickup', 'mail')),
  child_care_type    text check (child_care_type is null or child_care_type in
                       ('tuition', 'before_after_care', 'day_camp', 'day_care', 'transportation')),
  vendor_name        text,
  vendor_contact     text,
  service_period     text,
  status            text not null default 'submitted' check (status in
                      ('submitted', 'in_review', 'approved', 'denied', 'fulfilled')),
  decision_note     text,
  provider_name     text,
  confirmation_code text,
  booked_at         timestamptz,
  fulfilled_at      timestamptz,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint service_requests_ride_addresses_check check (
    service_type <> 'ride'
    or (coalesce(trim(pickup_address), '') <> '' and coalesce(trim(dropoff_address), '') <> '')),
  -- Aldi cards only exist as physical cards.
  constraint service_requests_aldi_physical_check check (
    gift_card_store <> 'aldi' or gift_card_format is distinct from 'electronic')
);
create index if not exists service_requests_status_idx on public.service_requests(status);
create index if not exists service_requests_client_idx on public.service_requests(client_id);
create index if not exists service_requests_type_idx   on public.service_requests(service_type);

-- Every movement of money or vouchers. Positive adds, negative uses.
-- Balance = sum(amount) per resource.
create table if not exists public.resource_transactions (
  id               uuid primary key default gen_random_uuid(),
  resource_id      uuid not null references public.resources(id) on delete restrict,
  amount           numeric(12,2) not null check (amount <> 0),
  description      text not null,
  service_request_id uuid unique references public.service_requests(id) on delete set null,
  occurred_on      date not null default current_date,
  created_by       text,
  created_at       timestamptz not null default now()
);
create index if not exists resource_tx_resource_idx on public.resource_transactions(resource_id);

-- Rosemary's current vendors.
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

insert into public.app_settings(key, value, description)
values ('default_allocation', '2000',
        'Dollars granted to each new member automatically. Changing this affects new members only.')
on conflict (key) do nothing;

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

-- Gives each new member the default allocation automatically.
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

drop trigger if exists touch_providers on public.providers;
create trigger touch_providers before update on public.providers
  for each row execute function public.touch_updated_at();

drop trigger if exists touch_resources on public.resources;
create trigger touch_resources before update on public.resources
  for each row execute function public.touch_updated_at();

drop trigger if exists touch_service_requests on public.service_requests;
create trigger touch_service_requests before update on public.service_requests
  for each row execute function public.touch_updated_at();

drop trigger if exists normalize_staff_email on public.staff;
create trigger normalize_staff_email before insert or update on public.staff
  for each row execute function public.normalize_staff_email();

drop trigger if exists touch_app_settings on public.app_settings;
create trigger touch_app_settings before update on public.app_settings
  for each row execute function public.touch_updated_at();

drop trigger if exists grant_default_allocation on public.clients;
create trigger grant_default_allocation after insert on public.clients
  for each row execute function public.grant_default_allocation();

drop trigger if exists stamp_client_allocations on public.client_allocations;
create trigger stamp_client_allocations before insert on public.client_allocations
  for each row execute function public.stamp_created_by();

drop trigger if exists stamp_resource_tx on public.resource_transactions;
create trigger stamp_resource_tx before insert on public.resource_transactions
  for each row execute function public.stamp_created_by();

do $$
declare t text;
begin
  foreach t in array array['staff', 'clients', 'resources', 'service_requests',
                           'resource_transactions', 'client_allocations', 'app_settings',
                           'providers'] loop
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

-- What each member has been given, has spent, has promised, and can
-- still use. Spent counts dollars only: a voucher is a unit of stock,
-- not money, so a voucher charge never reduces a member's balance.
-- Committed is money promised to open requests but not yet paid, so
-- "available" is the number a member can actually spend.
create or replace view public.client_balances
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

-- ---------------------------------------------------------------------
-- 5. Row level security
-- Anonymous visitors can read and write nothing directly.
-- Staff on the allowlist can work with everything.
-- Only admins can manage the staff list.
-- ---------------------------------------------------------------------

alter table public.staff                 enable row level security;
alter table public.clients               enable row level security;
alter table public.resources             enable row level security;
alter table public.service_requests         enable row level security;
alter table public.resource_transactions enable row level security;
alter table public.client_allocations    enable row level security;
alter table public.providers             enable row level security;
alter table public.app_settings          enable row level security;
alter table public.audit_log             enable row level security;

revoke all on public.staff, public.clients, public.resources, public.service_requests,
              public.resource_transactions, public.client_allocations, public.app_settings,
              public.providers, public.audit_log, public.resource_balances, public.client_balances
  from anon;

grant select, insert, update, delete on public.staff, public.clients, public.resources,
      public.service_requests, public.resource_transactions, public.client_allocations,
      public.providers
  to authenticated;
grant select on public.audit_log, public.resource_balances, public.client_balances,
      public.app_settings to authenticated;
grant update on public.app_settings to authenticated;

drop policy if exists staff_read on public.staff;
create policy staff_read on public.staff for select to authenticated using (public.is_staff());
drop policy if exists staff_admin_write on public.staff;
create policy staff_admin_write on public.staff for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

do $$
declare t text;
begin
  foreach t in array array['clients', 'resources', 'service_requests',
                           'resource_transactions', 'client_allocations', 'providers'] loop
    execute format('drop policy if exists %1$s_staff_all on public.%1$I', t);
    execute format('create policy %1$s_staff_all on public.%1$I for all to authenticated
                    using (public.is_staff()) with check (public.is_staff())', t);
  end loop;
end $$;

-- Any staff member can read settings; only an admin can change them.
drop policy if exists app_settings_staff_read on public.app_settings;
create policy app_settings_staff_read on public.app_settings for select to authenticated
  using (public.is_staff());
drop policy if exists app_settings_admin_write on public.app_settings;
create policy app_settings_admin_write on public.app_settings for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

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

create or replace function public.get_member_portal(p_token text)
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

-- What a member can see about their own requests.
--
-- decision_note is deliberately not returned. Staff write it for each
-- other while deciding, and it is not written with the member reading
-- it. If Pink Pack later wants to explain a denial to the member, that
-- belongs in a separate field written for that purpose.
create or replace function public.list_member_requests(p_token text)
returns table (
  id                 uuid,
  service_type       text,
  status             text,
  needed_at          timestamptz,
  created_at         timestamptz,
  reason_category    text,
  requested_amount   numeric,
  charged_amount     numeric,
  provider_name      text,
  pickup_address     text,
  dropoff_address    text,
  return_trip        boolean,
  return_at          timestamptz,
  gift_card_store    text,
  gift_card_format   text,
  gift_card_delivery text,
  child_care_type    text,
  vendor_name        text,
  service_period     text,
  confirmation_code  text,
  booked_at          timestamptz,
  fulfilled_at       timestamptz
)
language sql stable security definer set search_path = public as $$
  select r.id, r.service_type, r.status, r.needed_at, r.created_at,
         r.reason_category, r.requested_amount,
         -- What actually came off their balance, once it has been paid.
         (select abs(t.amount) from public.resource_transactions t
          join public.resources res on res.id = t.resource_id
          where t.service_request_id = r.id and res.kind = 'funding'
          limit 1) as charged_amount,
         coalesce(r.provider_name, p.name) as provider_name,
         r.pickup_address, r.dropoff_address, r.return_trip, r.return_at,
         r.gift_card_store, r.gift_card_format, r.gift_card_delivery,
         r.child_care_type, r.vendor_name, r.service_period,
         r.confirmation_code, r.booked_at, r.fulfilled_at
  from public.service_requests r
  join public.clients c on c.id = r.client_id
  left join public.providers p on p.id = r.provider_id
  where c.request_token = p_token and c.request_link_active
  order by
    -- Anything still open comes first: that is what they came to check.
    case when r.status in ('submitted', 'in_review', 'approved') then 0 else 1 end,
    r.needed_at desc
$$;

revoke all on function public.list_member_requests(text) from public;
grant execute on function public.list_member_requests(text) to anon, authenticated;

-- ---------------------------------------------------------------------
-- 7. Staff-only functions
-- ---------------------------------------------------------------------

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

-- Used by the GitHub Action that stops the free project from pausing.
create or replace function public.keepalive()
returns timestamptz language sql stable as $$ select now() $$;

revoke all on function public.check_request_link(text) from public;
revoke all on function public.submit_service_request(text, text, timestamptz, text, text, text, text, boolean, timestamptz, text, numeric, uuid, text, text, text, text, text, text, text) from public;
revoke all on function public.fulfill_request(uuid, text, text, uuid, numeric) from public;
grant execute on function public.check_request_link(text) to anon, authenticated;
grant execute on function public.submit_service_request(text, text, timestamptz, text, text, text, text, boolean, timestamptz, text, numeric, uuid, text, text, text, text, text, text, text) to anon, authenticated;
grant execute on function public.fulfill_request(uuid, text, text, uuid, numeric) to authenticated;
grant execute on function public.keepalive() to anon, authenticated;
grant execute on function public.is_staff(), public.is_admin(), public.current_email() to authenticated;

-- ---------------------------------------------------------------------
-- 8. Live updates
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['clients', 'resources', 'service_requests', 'resource_transactions',
                           'staff', 'client_allocations', 'app_settings', 'providers'] loop
    begin
      execute format('alter publication supabase_realtime add table public.%I', t);
    exception when duplicate_object then null;
    end;
  end loop;
end $$;
