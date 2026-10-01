-- =====================================================================
-- 305 Pink Pack Dashboard: first-time setup data
-- Run once, after schema.sql. Replace the emails with the real Google
-- accounts that should have access.
-- =====================================================================

insert into public.staff (email, full_name, role) values
  ('francokique@gmail.com',       'Kique Franco',     'admin'),
  ('rosemary@replace-me.org',      'Rosemary Carrera', 'staff')
on conflict (email) do update set full_name = excluded.full_name, role = excluded.role;

-- Starting resources. Record opening balances from the dashboard
-- (Resources > Record a change) so they show up in the audit trail.
insert into public.resources (name, kind, notes) values
  ('Ride funding',  'funding', 'Dollars available to pay for rides'),
  ('Ride vouchers', 'voucher', 'Prepaid ride vouchers on hand')
on conflict (name) do nothing;
