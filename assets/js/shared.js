import { createClient } from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm';
import { SUPABASE_URL, SUPABASE_KEY, TIMEZONE } from './config.js';

export const isConfigured =
  !SUPABASE_URL.includes('YOUR-PROJECT-REF') && !SUPABASE_KEY.includes('YOUR-PUBLISHABLE-KEY');

export const supabase = isConfigured ? createClient(SUPABASE_URL, SUPABASE_KEY) : null;

export const REASONS = {
  treatment: 'Treatment appointment',
  doctor_visit: 'Doctor visit or follow-up',
  labs_scans: 'Lab work or scans',
  pharmacy: 'Pharmacy pickup',
  support_service: 'Support service or program',
  other: 'Other',
};

export const STATUSES = {
  submitted: 'Submitted',
  in_review: 'In review',
  approved: 'Approved',
  denied: 'Denied',
  fulfilled: 'Fulfilled',
};

// Escapes text before it goes into HTML. Everything a client or staff
// member typed must pass through this.
export function esc(value) {
  return String(value ?? '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
}

const dtFmt = new Intl.DateTimeFormat('en-US', {
  timeZone: TIMEZONE, weekday: 'short', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit',
});
const dFmt = new Intl.DateTimeFormat('en-US', { timeZone: TIMEZONE, month: 'short', day: 'numeric', year: 'numeric' });
const tFmt = new Intl.DateTimeFormat('en-US', { timeZone: TIMEZONE, hour: 'numeric', minute: '2-digit' });

export const fmtDateTime = (v) => (v ? dtFmt.format(new Date(v)) : '');
export const fmtDate = (v) => (v ? dFmt.format(new Date(v.length === 10 ? v + 'T12:00:00' : v)) : '');
export const fmtTime = (v) => (v ? tFmt.format(new Date(v)) : '');

export function timeAgo(v) {
  const s = Math.round((Date.now() - new Date(v).getTime()) / 1000);
  if (s < 60) return 'just now';
  if (s < 3600) return `${Math.floor(s / 60)} min ago`;
  if (s < 86400) return `${Math.floor(s / 3600)} hr ago`;
  if (s < 86400 * 7) return `${Math.floor(s / 86400)} d ago`;
  return fmtDate(v);
}

// Converts a stored timestamp to the value a datetime-local input expects.
export function toLocalInput(v) {
  if (!v) return '';
  const d = new Date(v);
  const pad = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

export const fromLocalInput = (v) => (v ? new Date(v).toISOString() : null);

export function fmtAmount(kind, n) {
  const num = Number(n || 0);
  if (kind === 'funding') {
    return num.toLocaleString('en-US', { style: 'currency', currency: 'USD' });
  }
  const abs = Math.abs(num);
  return `${num < 0 ? '-' : ''}${abs.toLocaleString('en-US')} voucher${abs === 1 ? '' : 's'}`;
}

// Supabase / Postgres errors carry a readable message from our functions.
export function errMsg(error) {
  if (!error) return 'Something went wrong.';
  return error.message || String(error);
}
