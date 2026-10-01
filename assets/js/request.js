import { supabase, isConfigured, fmtDateTime, toLocalInput, fromLocalInput, errMsg } from './shared.js';
import { ORG_PHONE } from './config.js';

const $ = (sel) => document.querySelector(sel);
const token = new URLSearchParams(location.search).get('t') || '';

for (const el of document.querySelectorAll('.org-phone')) el.textContent = ORG_PHONE;
for (const a of document.querySelectorAll('.org-phone-link')) a.href = `tel:${ORG_PHONE.replace(/[^\d+]/g, '')}`;

function showState(id) {
  for (const s of ['loading', 'invalid', 'form', 'done']) $(`#state-${s}`).hidden = s !== id;
}

async function init() {
  if (!isConfigured || !/^[a-f0-9]{32}$/.test(token)) return showState('invalid');

  const { data, error } = await supabase.rpc('check_request_link', { p_token: token });
  if (error || !data?.length) return showState('invalid');

  $('#greeting').textContent = `Hi ${data[0].first_name}, tell us about the ride you need.`;
  resetForm();
  showState('form');
}

function resetForm() {
  const form = $('#state-form');
  form.reset();
  $('#return-field').hidden = true;
  $('#form-error').hidden = true;
  const min = toLocalInput(new Date().toISOString());
  form.pickup_at.min = min;
  form.return_at.min = min;
}

$('#state-form').return_trip.addEventListener('change', (e) => {
  $('#return-field').hidden = !e.target.checked;
});

$('#state-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  const form = e.target;
  const err = $('#form-error');
  const btn = form.querySelector('button[type="submit"]');

  const pickup = form.pickup_at.value;
  const returnTrip = form.return_trip.checked;
  let msg = '';
  if (!pickup) msg = 'Please choose a pickup date and time.';
  else if (new Date(pickup) < new Date()) msg = 'Please choose a pickup time in the future.';
  else if (!form.pickup_address.value.trim()) msg = 'Please enter your pickup address.';
  else if (!form.dropoff_address.value.trim()) msg = 'Please enter where you are going.';
  else if (!form.reason_category.value) msg = 'Please choose why you need the ride.';
  else if (returnTrip && !form.return_at.value) msg = 'Please choose a time for the ride home.';
  else if (returnTrip && new Date(form.return_at.value) <= new Date(pickup)) msg = 'The ride home should be after the pickup time.';
  if (msg) { err.textContent = msg; err.hidden = false; return; }

  btn.disabled = true;
  btn.textContent = 'Sending…';
  const { error } = await supabase.rpc('submit_ride_request', {
    p_token: token,
    p_pickup_at: fromLocalInput(pickup),
    p_pickup_address: form.pickup_address.value,
    p_dropoff_address: form.dropoff_address.value,
    p_reason_category: form.reason_category.value,
    p_reason_details: form.reason_details.value || null,
    p_return_trip: returnTrip,
    p_return_at: returnTrip ? fromLocalInput(form.return_at.value) : null,
    p_contact_phone: form.contact_phone.value || null,
  });
  btn.disabled = false;
  btn.textContent = 'Send request';

  if (error) { err.textContent = errMsg(error); err.hidden = false; return; }

  $('#done-summary').textContent = `Pickup ${fmtDateTime(fromLocalInput(pickup))} from ${form.pickup_address.value.trim()}.`;
  showState('done');
  window.scrollTo(0, 0);
});

$('#btn-another').addEventListener('click', () => { resetForm(); showState('form'); });

init();
