// The member's own page. Reached only through the private link
// 305 Pink Pack sends them. It shows what they have, what they can use
// it on, and lets them ask for any of the four services.
//
// Nothing about treatment or diagnosis is read or shown here.

import {
  supabase, isConfigured, fmtDateTime, fmtDate, fmtAmount,
  toLocalInput, fromLocalInput, errMsg, esc,
  SERVICE_TYPES, SERVICE_SHORT, REASONS, REASONS_BY_SERVICE, NEEDED_AT_LABEL, usesAddresses,
  GIFT_CARD_STORES, GIFT_CARD_FORMATS, GIFT_CARD_DELIVERY, CHILD_CARE_TYPES,
  storeAllowsElectronic,
} from './shared.js';
import { ORG_PHONE } from './config.js';

const $ = (sel) => document.querySelector(sel);
const $$ = (sel) => [...document.querySelectorAll(sel)];
const token = new URLSearchParams(location.search).get('t') || '';

for (const el of $$('.org-phone')) el.textContent = ORG_PHONE;
for (const a of $$('.org-phone-link')) a.href = `tel:${ORG_PHONE.replace(/[^\d+]/g, '')}`;

let member = null;
let providers = [];
let requests = [];

const SECTIONS = ['loading', 'invalid', 'summary', 'requests', 'catalog', 'form', 'done'];
function show(...ids) {
  for (const s of SECTIONS) {
    const el = $(`#state-${s}`);
    if (el) el.hidden = !ids.includes(s);
  }
}

// ---------------------------------------------------------------------
// Load
// ---------------------------------------------------------------------

async function init() {
  if (!isConfigured || !/^[a-f0-9]{32}$/.test(token)) return show('invalid');

  const [portal, catalog, mine] = await Promise.all([
    supabase.rpc('get_member_portal', { p_token: token }),
    supabase.rpc('list_member_providers', { p_token: token }),
    supabase.rpc('list_member_requests', { p_token: token }),
  ]);
  if (portal.error || !portal.data?.length) return show('invalid');

  member = portal.data[0];
  providers = catalog.data || [];
  requests = mine.data || [];

  renderSummary();
  renderRequests();
  renderCatalog();
  resetForm();
  // An expired member still sees what they had and the catalog, but
  // not a form the server would only reject.
  show('summary', ...(requests.length ? ['requests'] : []),
       'catalog', ...(member.expired ? [] : ['form']));
}

// ---------------------------------------------------------------------
// Summary
// ---------------------------------------------------------------------

function renderSummary() {
  $('#page-title').textContent = `Hi ${member.first_name}`;
  $('#greeting').textContent = `Hi ${member.first_name}`;

  const available = Number(member.available);
  const allocated = Number(member.allocated);
  const committed = Number(member.committed);
  const pct = allocated > 0 ? Math.max(0, Math.min(100, (available / allocated) * 100)) : 0;

  $('#balance-amount').textContent = fmtAmount('funding', available);
  $('#balance-meter').style.width = `${pct.toFixed(1)}%`;
  $('#balance-meter').parentElement.classList.toggle('low', allocated > 0 && pct <= 15);

  const bits = [`of ${fmtAmount('funding', allocated)} total`];
  if (committed > 0) bits.push(`${fmtAmount('funding', committed)} is held for requests we are reviewing`);
  $('#balance-sub').textContent = `${bits.join(' · ')}.`;

  $('#fact-since').textContent = member.member_since ? fmtDate(member.member_since) : 'Not recorded';
  $('#fact-expiry').textContent = member.services_expire_on
    ? `Until ${fmtDate(member.services_expire_on)}`
    : 'Does not expire';

  if (member.expired) {
    const n = $('#expired-notice');
    n.textContent = `Your direct services ended on ${fmtDate(member.services_expire_on)}. `
      + `Please call us at ${ORG_PHONE} to talk about your options.`;
    n.hidden = false;
  }
}

// ---------------------------------------------------------------------
// Their own requests
// ---------------------------------------------------------------------

const OPEN_STATUSES = ['submitted', 'in_review', 'approved'];

// Said from the member's side: what is happening and what they do next.
const STATUS_TEXT = {
  submitted: ['Waiting for review', 'We have your request and will be in touch.'],
  in_review: ['Being reviewed', 'Someone at Pink Pack is working on this now.'],
  approved: ['Approved', 'We are arranging it. We will contact you to confirm.'],
  fulfilled: ['Done', ''],
  denied: ['Not approved', 'Please call us if you would like to talk about this.'],
};

// The one-line description of what was asked for.
function requestDetail(r) {
  switch (r.service_type) {
    case 'ride':
      return [r.pickup_address, r.dropoff_address].filter(Boolean).join(' to ')
        + (r.return_trip ? ', with a ride home' : '');
    case 'self_care':
      return r.provider_name || '';
    case 'gift_card':
      return [GIFT_CARD_STORES[r.gift_card_store],
        (GIFT_CARD_FORMATS[r.gift_card_format] || '').toLowerCase(),
        GIFT_CARD_DELIVERY[r.gift_card_delivery]].filter(Boolean).join(', ');
    case 'child_care':
      return [CHILD_CARE_TYPES[r.child_care_type], r.vendor_name, r.service_period]
        .filter(Boolean).join(' · ');
    default:
      return '';
  }
}

// What this request costs them. Once paid, the real charge; before that,
// what they asked for, clearly marked as not yet taken.
function requestAmount(r) {
  if (r.charged_amount != null) {
    return `<span class="req-amount">${esc(fmtAmount('funding', r.charged_amount))}</span>
            <span class="req-amount-note">used</span>`;
  }
  if (r.requested_amount != null) {
    const taken = r.status === 'denied' ? 'not taken from your balance' : 'held for now';
    return `<span class="req-amount">${esc(fmtAmount('funding', r.requested_amount))}</span>
            <span class="req-amount-note">${esc(taken)}</span>`;
  }
  return '';
}

function requestCard(r) {
  const [label, next] = STATUS_TEXT[r.status] || [r.status, ''];
  const detail = requestDetail(r);
  return `
    <li class="req ${esc(r.status)}">
      <div class="req-head">
        <div>
          <span class="pill service ${esc(r.service_type)}">${esc(SERVICE_SHORT[r.service_type] || r.service_type)}</span>
          <span class="pill ${esc(r.status)}">${esc(label)}</span>
        </div>
        ${requestAmount(r)}
      </div>
      <div class="req-when">${esc(fmtDateTime(r.needed_at))}</div>
      ${detail ? `<div class="req-detail">${esc(detail)}</div>` : ''}
      ${r.confirmation_code ? `<div class="req-confirm">Confirmation ${esc(r.confirmation_code)}</div>` : ''}
      ${next ? `<div class="req-next">${esc(next)}</div>` : ''}
    </li>`;
}

function renderRequests() {
  const open = requests.filter((r) => OPEN_STATUSES.includes(r.status));
  const past = requests.filter((r) => !OPEN_STATUSES.includes(r.status));

  $('#requests-open').innerHTML = open.length
    ? `<h3>Waiting on us</h3><ul class="req-list">${open.map(requestCard).join('')}</ul>`
    : '<p class="muted small">You have no requests waiting right now.</p>';

  $('#requests-past').innerHTML = past.length
    ? `<h3 style="margin-top:18px">Earlier requests</h3><ul class="req-list">${past.map(requestCard).join('')}</ul>`
    : '';
}

// ---------------------------------------------------------------------
// Catalog
// ---------------------------------------------------------------------

function renderCatalog() {
  const selfCare = providers.filter((p) => p.service_type === 'self_care');
  const blocks = [];

  blocks.push(`
    <section class="catalog-group">
      <h3>Rides</h3>
      <p class="muted small">To treatment, appointments, labs, the pharmacy or a support program. We arrange the ride for you.</p>
    </section>`);

  blocks.push(`
    <section class="catalog-group">
      <h3>Grocery gift cards</h3>
      <p class="muted small">Walmart and Publix cards, physical or electronic. Aldi cards are physical only. Cards usually come in $300 amounts. Physical cards can be picked up at our office or mailed to you.</p>
    </section>`);

  if (selfCare.length) {
    blocks.push(`
      <section class="catalog-group">
        <h3>Self-care services</h3>
        <p class="muted small">You contact the provider yourself to book. The amount below comes off your balance for each session.</p>
        <ul class="vendor-list">
          ${selfCare.map((p) => `
            <li>
              <div class="vendor-head">
                <strong>${esc(p.name)}</strong>
                <span class="vendor-cost">${p.cost_varies ? 'Cost varies' : esc(fmtAmount('funding', p.session_cost))}</span>
              </div>
              ${p.in_home ? '<div class="small muted">In your home</div>' : ''}
              ${p.address ? `<div class="small muted">${esc(p.address)}</div>` : ''}
              ${p.languages ? `<div class="small muted">${esc(p.languages)}</div>` : ''}
              ${p.notes ? `<div class="small muted">${esc(p.notes)}</div>` : ''}
              ${p.contact_phone ? `<div class="small"><a href="sms:${esc(p.contact_phone.replace(/[^\d+]/g, ''))}">Text ${esc(p.contact_phone)}</a>${p.contact_name ? ` · ${esc(p.contact_name)}` : ''}</div>` : ''}
            </li>`).join('')}
        </ul>
      </section>`);
  }

  blocks.push(`
    <section class="catalog-group">
      <h3>Child care help</h3>
      <p class="muted small">School tuition, before or after school care, day camp, day care, or school transportation. You choose the provider and we pay them directly.</p>
    </section>`);

  $('#catalog').innerHTML = blocks.join('');
}

// ---------------------------------------------------------------------
// Form
// ---------------------------------------------------------------------

const form = () => $('#state-form');

function resetForm() {
  const f = form();
  f.reset();
  $('#form-error').hidden = true;
  showServiceFields('');
  const min = toLocalInput(new Date().toISOString());
  f.needed_at.min = min;
  f.return_at.min = min;

  // Only self-care services that are actually offered appear here.
  f.provider_id.innerHTML = '<option value="">Choose one</option>'
    + providers.filter((p) => p.service_type === 'self_care')
      .map((p) => `<option value="${esc(p.id)}">${esc(p.name)}`
        + `${p.cost_varies ? '' : ` — ${fmtAmount('funding', p.session_cost)}`}</option>`)
      .join('');
}

function showServiceFields(type) {
  for (const el of $$('#state-form [data-for]')) {
    const want = el.dataset.for;
    el.hidden = want === 'any' ? !type : want !== type;
  }
  if (!type) return;

  $('#when-field').firstChild.textContent = NEEDED_AT_LABEL[type] || 'When do you need this?';

  const reasons = REASONS_BY_SERVICE[type] || Object.keys(REASONS);
  form().reason_category.innerHTML = '<option value="">Choose one</option>'
    + reasons.map((k) => `<option value="${esc(k)}">${esc(REASONS[k])}</option>`).join('');

  syncCostNote();
}

// What this request will take off the balance, as far as we can tell
// before it is submitted. Self-care is priced by the directory.
function plannedAmount() {
  const f = form();
  const type = f.service_type.value;
  if (type === 'self_care') {
    const p = providers.find((x) => x.id === f.provider_id.value);
    return p && !p.cost_varies ? Number(p.session_cost) : null;
  }
  if (type === 'gift_card') return Number(f.gift_card_amount.value) || null;
  if (type === 'child_care') return Number(f.child_care_amount.value) || null;
  return null;
}

function syncCostNote() {
  const note = $('#cost-note');
  const amount = plannedAmount();
  if (!amount) { note.hidden = true; return; }
  const available = Number(member.available);
  const after = available - amount;
  note.hidden = false;
  note.classList.toggle('error', after < 0);
  note.textContent = after < 0
    ? `This is ${fmtAmount('funding', amount)}, but you have ${fmtAmount('funding', available)} available.`
    : `This will use ${fmtAmount('funding', amount)} and leave you ${fmtAmount('funding', after)}.`;
}

// ---------------------------------------------------------------------
// Form wiring
// ---------------------------------------------------------------------

form().service_type.addEventListener('change', (e) => showServiceFields(e.target.value));
form().return_trip.addEventListener('change', (e) => { $('#return-field').hidden = !e.target.checked; });

form().provider_id.addEventListener('change', (e) => {
  const p = providers.find((x) => x.id === e.target.value);
  const note = $('#self-care-note');
  if (!p) { note.hidden = true; syncCostNote(); return; }
  const parts = ['You book this yourself.'];
  if (p.contact_phone) parts.push(`Text ${p.contact_phone}${p.contact_name ? ` (${p.contact_name})` : ''}.`);
  if (p.address) parts.push(p.address);
  note.textContent = parts.join(' ');
  note.hidden = false;
  syncCostNote();
});

// Aldi has no electronic card, so that option is removed rather than
// offered and then rejected on submit.
form().gift_card_store.addEventListener('change', (e) => {
  const f = form();
  const electronicOk = storeAllowsElectronic(e.target.value);
  const opt = [...f.gift_card_format.options].find((o) => o.value === 'electronic');
  opt.hidden = !electronicOk;
  opt.disabled = !electronicOk;
  $('#aldi-hint').hidden = electronicOk;
  if (!electronicOk && f.gift_card_format.value === 'electronic') f.gift_card_format.value = 'physical';
  syncDelivery();
});

function syncDelivery() {
  $('#delivery-field').hidden = form().gift_card_format.value !== 'physical';
}
form().gift_card_format.addEventListener('change', syncDelivery);

for (const name of ['gift_card_amount', 'child_care_amount']) {
  form()[name].addEventListener('input', syncCostNote);
}

// ---------------------------------------------------------------------
// Submit
// ---------------------------------------------------------------------

function validate() {
  const f = form();
  const type = f.service_type.value;
  if (!type) return 'Please choose what you need.';

  const when = f.needed_at.value;
  if (!when) return `Please choose a date${type === 'ride' ? ' and time' : ''}.`;
  if (new Date(when) < new Date()) return 'Please choose a date in the future.';
  if (!f.reason_category.value) return 'Please choose why you need it.';

  if (type === 'ride') {
    if (!f.pickup_address.value.trim()) return 'Please enter your pickup address.';
    if (!f.dropoff_address.value.trim()) return 'Please enter where you are going.';
    if (f.return_trip.checked && !f.return_at.value) return 'Please choose a time for the ride home.';
    if (f.return_trip.checked && new Date(f.return_at.value) <= new Date(when)) {
      return 'The ride home should be after the pickup time.';
    }
  }
  if (type === 'self_care' && !f.provider_id.value) return 'Please choose a service.';
  if (type === 'gift_card') {
    if (!f.gift_card_store.value) return 'Please choose a store.';
    if (!f.gift_card_format.value) return 'Please choose a physical or electronic card.';
    if (f.gift_card_format.value === 'physical' && !f.gift_card_delivery.value) {
      return 'Please choose whether you will pick it up or have it mailed.';
    }
    if (!(Number(f.gift_card_amount.value) > 0)) return 'Please enter how much you need on the card.';
  }
  if (type === 'child_care') {
    if (!f.child_care_type.value) return 'Please choose what kind of help you need.';
    if (!f.vendor_name.value.trim()) return 'Please tell us who we should pay.';
    if (!f.vendor_contact.value.trim()) return 'Please give us a phone number or email for them.';
    if (!f.service_period.value.trim()) return 'Please tell us what dates this covers.';
    if (!(Number(f.child_care_amount.value) > 0)) return 'Please enter the total cost.';
  }

  const amount = plannedAmount();
  if (amount && amount > Number(member.available)) {
    return `You have ${fmtAmount('funding', Number(member.available))} available, and this is `
      + `${fmtAmount('funding', amount)}.`;
  }
  return '';
}

form().addEventListener('submit', async (e) => {
  e.preventDefault();
  const f = e.target;
  const err = $('#form-error');
  const btn = f.querySelector('button[type="submit"]');

  const msg = validate();
  if (msg) { err.textContent = msg; err.hidden = false; window.scrollTo(0, document.body.scrollHeight); return; }
  err.hidden = true;

  const type = f.service_type.value;
  const isRide = usesAddresses(type);

  btn.disabled = true;
  btn.textContent = 'Sending…';
  const { error } = await supabase.rpc('submit_service_request', {
    p_token: token,
    p_service_type: type,
    p_needed_at: fromLocalInput(f.needed_at.value),
    p_reason_category: f.reason_category.value,
    p_pickup_address: isRide ? f.pickup_address.value : null,
    p_dropoff_address: isRide ? f.dropoff_address.value : null,
    p_reason_details: f.reason_details.value || null,
    p_return_trip: isRide && f.return_trip.checked,
    p_return_at: isRide && f.return_trip.checked ? fromLocalInput(f.return_at.value) : null,
    p_contact_phone: f.contact_phone.value || null,
    // Self-care is priced from the directory on the server, so no amount
    // is sent for it. The other two are amounts the member tells us.
    p_requested_amount: type === 'gift_card' ? Number(f.gift_card_amount.value)
      : type === 'child_care' ? Number(f.child_care_amount.value) : null,
    p_provider_id: type === 'self_care' ? f.provider_id.value : null,
    p_gift_card_store: type === 'gift_card' ? f.gift_card_store.value : null,
    p_gift_card_format: type === 'gift_card' ? f.gift_card_format.value : null,
    p_gift_card_delivery: type === 'gift_card' && f.gift_card_format.value === 'physical'
      ? f.gift_card_delivery.value : null,
    p_child_care_type: type === 'child_care' ? f.child_care_type.value : null,
    p_vendor_name: type === 'child_care' ? f.vendor_name.value : null,
    p_vendor_contact: type === 'child_care' ? f.vendor_contact.value : null,
    p_service_period: type === 'child_care' ? f.service_period.value : null,
  });
  btn.disabled = false;
  btn.textContent = 'Send request';

  if (error) { err.textContent = errMsg(error); err.hidden = false; return; }

  $('#done-summary').textContent =
    `${SERVICE_TYPES[type]} for ${fmtDateTime(fromLocalInput(f.needed_at.value))}.`;
  $('#done-next').textContent = type === 'self_care'
    ? 'Contact the provider directly to book your appointment. We will take the cost off your balance.'
    : `We will contact you to confirm. If your plans change, call us at ${ORG_PHONE}.`;

  show('summary', 'done');
  window.scrollTo(0, 0);

  // The balance moved and there is a new request to show, so neither
  // should still be showing what they were before this submission.
  const [portal, mine] = await Promise.all([
    supabase.rpc('get_member_portal', { p_token: token }),
    supabase.rpc('list_member_requests', { p_token: token }),
  ]);
  if (portal.data?.length) { member = portal.data[0]; renderSummary(); }
  if (mine.data) { requests = mine.data; renderRequests(); }
});

$('#btn-another').addEventListener('click', () => {
  resetForm();
  show('summary', ...(requests.length ? ['requests'] : []),
       'catalog', ...(member.expired ? [] : ['form']));
  window.scrollTo(0, 0);
});

init();
