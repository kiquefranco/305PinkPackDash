-- =====================================================================
-- Migration 004: members can see their own requests
-- Run once in Supabase: SQL Editor > New query > paste > Run.
-- Safe to re-run. Run 001, 002 and 003 first.
--
-- Members could see their balance but not what they had asked for, so
-- there was no way to tell whether a request had been seen, approved or
-- turned down without calling the office.
-- =====================================================================

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
