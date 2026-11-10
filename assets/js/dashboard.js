import {
  supabase, isConfigured, REASONS, STATUSES, SERVICE_TYPES, SERVICE_SHORT,
  NEEDED_AT_LABEL, usesAddresses, MEMBER_GROUPS, GIFT_CARD_STORES, GIFT_CARD_FORMATS,
  GIFT_CARD_DELIVERY, CHILD_CARE_TYPES,
  esc, fmtDateTime, fmtDate, fmtTime, timeAgo,
  toLocalInput, fromLocalInput, fmtAmount, errMsg,
} from './shared.js';
import { ORG_NAME, ORG_PHONE } from './config.js';

const $ = (sel, el = document) => el.querySelector(sel);
const $$ = (sel, el = document) => [...el.querySelectorAll(sel)];

const state = {
  user: null,
  me: null,
  isAdmin: false,
  clients: [],
  requests: [],
  resources: [],
  transactions: [],
  balances: [],
  allocations: [],
  providers: [],
  settings: {},
  audit: [],
  staff: [],
  filter: 'open',
  serviceFilter: 'all',
  search: '',
  clientSearch: '',
  tab: 'requests',
  openRequestId: null,
  drawerDirty: false,
};

const OPEN = ['submitted', 'in_review', 'approved'];

// Typed into the booking field. Suggestions only; staff can enter anything.
// Task 4 replaces these with the real provider directory.
const PROVIDER_SUGGESTIONS = {
  ride: ['Uber Health', 'Uber', 'Lyft', 'Taxi', 'Volunteer driver'],
  self_care: ['Oncology massage', 'Acupuncture', 'Counseling', 'Salon or wig service'],
  gift_card: ['Publix', 'Winn-Dixie', 'Walmart', 'Instacart'],
  child_care: ['Licensed sitter', 'Day care center', 'Family member'],
};
// The directory is the real list. The hardcoded names below are only a
// fallback for service types nobody has added vendors for yet.
const providerOptions = (serviceType) => {
  const fromDirectory = state.providers
    .filter((p) => p.active && p.service_type === serviceType)
    .map((p) => p.name);
  return fromDirectory.length ? fromDirectory : (PROVIDER_SUGGESTIONS[serviceType] || []);
};

const PROVIDER_HINT = {
  ride: 'e.g. Uber Health',
  self_care: 'Who is providing it',
  gift_card: 'Which store',
  child_care: 'Who is providing care',
};
const clientById = (id) => state.clients.find((c) => c.id === id);
const resourceById = (id) => state.resources.find((r) => r.id === id);
const clientName = (c) => (c ? `${c.first_name} ${c.last_name || ''}`.trim() : 'Unknown client');
const serviceLabel = (r) => SERVICE_TYPES[r.service_type] || r.service_type;
const balanceFor = (clientId) => state.balances.find((b) => b.client_id === clientId)
  || { allocated: 0, spent: 0, committed: 0, remaining: 0, available: 0 };
const providerById = (id) => state.providers.find((p) => p.id === id);
const expiryLabel = (c) => (c.services_expire_on
  ? `Until ${fmtDate(c.services_expire_on)}` : 'Does not expire');
// A date-only string parses as UTC midnight, which is the previous
// evening in Miami. Both sides are pinned to midday so the comparison
// is about calendar days, not clock hours.
const atMidday = (d) => new Date(`${d}T12:00:00`);
const today = () => atMidday(new Date().toLocaleDateString('en-CA'));
const isExpired = (c) => !!c.services_expire_on && atMidday(c.services_expire_on) < today();
const whenLabel = (r) => NEEDED_AT_LABEL[r.service_type] || 'Needed';

// ---------------------------------------------------------------------
// Screens and sign-in
// ---------------------------------------------------------------------

function show(id) {
  for (const el of $$('[id^="screen-"]')) el.hidden = el.id !== id;
}

function boot() {
  if (!isConfigured) return show('screen-setup');

  const hash = new URLSearchParams(location.hash.slice(1));
  const oauthError = hash.get('error_description') || new URLSearchParams(location.search).get('error_description');
  if (oauthError) {
    $('#login-error').textContent = oauthError;
    $('#login-error').hidden = false;
  }

  supabase.auth.onAuthStateChange((event, session) => {
    if (session && !state.user) {
      setTimeout(() => enter(session), 0);
    } else if (!session) {
      if (state.user) location.reload();
      else show('screen-login');
    }
  });

  $('#btn-google').addEventListener('click', async () => {
    const { error } = await supabase.auth.signInWithOAuth({
      provider: 'google',
      options: { redirectTo: location.origin + location.pathname, queryParams: { prompt: 'select_account' } },
    });
    if (error) {
      $('#login-error').textContent = errMsg(error);
      $('#login-error').hidden = false;
    }
  });

  document.addEventListener('click', async (e) => {
    if (e.target.closest('[data-action="sign-out"]')) {
      await supabase.auth.signOut();
      location.reload();
    }
  });
}

async function enter(session) {
  state.user = session.user;
  const email = (session.user.email || '').toLowerCase();
  const { data: me, error } = await supabase.from('staff').select('*').eq('email', email).maybeSingle();
  if (error || !me) {
    $('#denied-email').textContent = email;
    return show('screen-denied');
  }
  state.me = me;
  state.isAdmin = me.role === 'admin';
  $('#user-email').textContent = email;
  $('#tab-staff').hidden = !state.isAdmin;
  if (location.hash) history.replaceState(null, '', location.pathname + location.search);
  show('screen-app');
  wireApp();
  await loadAll();
  subscribe();
}

// ---------------------------------------------------------------------
// Data
// ---------------------------------------------------------------------

async function loadAll() {
  const [clients, requests, resources, transactions, balances, allocations, settings, providers, audit, staff] =
    await Promise.all([
      supabase.from('clients').select('*').order('first_name'),
      supabase.from('service_requests').select('*').order('needed_at', { ascending: true }).limit(2000),
      supabase.from('resource_balances').select('*').order('name'),
      supabase.from('resource_transactions').select('*')
        .order('occurred_on', { ascending: false }).order('created_at', { ascending: false }).limit(500),
      supabase.from('client_balances').select('*'),
      supabase.from('client_allocations').select('*').order('granted_on', { ascending: false }),
      supabase.from('app_settings').select('*'),
      supabase.from('providers').select('*').order('service_type').order('sort_order'),
      supabase.from('audit_log').select('*').order('changed_at', { ascending: false }).limit(300),
      supabase.from('staff').select('*').order('created_at'),
    ]);
  const failed = [clients, requests, resources, transactions, balances, allocations, settings,
    providers, audit, staff].find((r) => r.error);
  if (failed) toast(`Could not load data: ${errMsg(failed.error)}`, 'error');

  state.clients = clients.data || [];
  state.requests = requests.data || [];
  state.resources = resources.data || [];
  state.transactions = transactions.data || [];
  state.balances = balances.data || [];
  state.allocations = allocations.data || [];
  state.settings = Object.fromEntries((settings.data || []).map((r) => [r.key, r.value]));
  state.providers = providers.data || [];
  state.audit = audit.data || [];
  state.staff = staff.data || [];
  renderAll();
}

let reloadTimer;
function scheduleReload() {
  clearTimeout(reloadTimer);
  reloadTimer = setTimeout(loadAll, 250);
}

// Live updates: any change anywhere reloads the data for everyone signed in.
function subscribe() {
  supabase
    .channel('dashboard')
    .on('postgres_changes', { event: '*', schema: 'public' }, (payload) => {
      if (payload.table === 'service_requests' && payload.eventType === 'INSERT') {
        const id = payload.new.id;
        setTimeout(() => {
          const req = state.requests.find((r) => r.id === id);
          const c = req && clientById(req.client_id);
          const label = req ? (SERVICE_SHORT[req.service_type] || 'service').toLowerCase() : 'service';
          toast(`New ${label} request from ${c ? clientName(c) : 'a client'}. Click to open.`, 'new', () => openRequest(id));
        }, 600);
      }
      scheduleReload();
    })
    .subscribe();

  // Backup in case the live connection drops: refresh on focus and every minute.
  window.addEventListener('focus', scheduleReload);
  setInterval(scheduleReload, 60000);
}

// ---------------------------------------------------------------------
// UI plumbing
// ---------------------------------------------------------------------

function wireApp() {
  $$('.tab').forEach((t) => t.addEventListener('click', () => setTab(t.dataset.tab)));

  $('#request-search').addEventListener('input', (e) => { state.search = e.target.value.toLowerCase(); renderRequests(); });
  $('#client-search').addEventListener('input', (e) => { state.clientSearch = e.target.value.toLowerCase(); renderClients(); });

  document.addEventListener('click', (e) => {
    const closeBtn = e.target.closest('[data-close]');
    if (closeBtn) closeBtn.closest('dialog').close();
    const act = e.target.closest('[data-action]')?.dataset.action;
    if (act === 'new-client') openClientForm();
    if (act === 'new-provider') openProviderForm();
    if (act === 'new-resource') openResourceForm();
    if (act === 'new-transaction') openTransactionForm();
    if (act === 'new-staff') openStaffForm();
  });

  for (const dlg of $$('dialog')) {
    dlg.addEventListener('click', (e) => { if (e.target === dlg) dlg.close(); });
  }
  $('#dlg-request').addEventListener('close', () => { state.openRequestId = null; state.drawerDirty = false; });
  $('#dlg-request').addEventListener('input', () => { state.drawerDirty = true; });

  $('#form-client').addEventListener('submit', saveClient);
  $('#form-provider').addEventListener('submit', saveProvider);
  $('#form-resource').addEventListener('submit', saveResource);
  $('#form-transaction').addEventListener('submit', saveTransaction);
  $('#form-staff').addEventListener('submit', saveStaff);
  $('#form-transaction [name="resource_id"]').addEventListener('change', syncTxLabel);

  const initial = location.hash.replace('#', '');
  setTab(['requests', 'clients', 'resources', 'activity', 'staff'].includes(initial) ? initial : 'requests');
}

function setTab(tab) {
  if (tab === 'staff' && !state.isAdmin) tab = 'requests';
  state.tab = tab;
  $$('.tab').forEach((t) => t.setAttribute('aria-selected', String(t.dataset.tab === tab)));
  $$('[data-panel]').forEach((p) => { p.hidden = p.dataset.panel !== tab; });
  history.replaceState(null, '', `#${tab}`);
}

function toast(message, type = '', onClick) {
  const el = document.createElement('div');
  el.className = `toast ${type}`;
  el.textContent = message;
  if (onClick) { el.style.cursor = 'pointer'; el.addEventListener('click', () => { onClick(); el.remove(); }); }
  $('#toasts').append(el);
  setTimeout(() => el.remove(), type === 'new' ? 12000 : 5000);
}

function formError(form, message) {
  const el = $('.form-error', form);
  el.textContent = message || '';
  el.hidden = !message;
}

async function withBusy(btn, fn) {
  btn.disabled = true;
  try { return await fn(); } finally { btn.disabled = false; }
}

function confirmDialog(message, confirmLabel = 'Confirm', danger = false) {
  return new Promise((resolve) => {
    const dlg = document.createElement('dialog');
    dlg.innerHTML = `
      <div class="dialog-body">
        <p>${esc(message)}</p>
        <div class="form-actions">
          <button class="btn" value="no">Cancel</button>
          <button class="btn ${danger ? 'danger solid' : 'primary'}" value="yes">${esc(confirmLabel)}</button>
        </div>
      </div>`;
    document.body.append(dlg);
    dlg.addEventListener('click', (e) => {
      const v = e.target.closest('button')?.value;
      if (v || e.target === dlg) { dlg.close(); dlg.remove(); resolve(v === 'yes'); }
    });
    dlg.showModal();
  });
}

function renderAll() {
  renderKpis();
  renderRequests();
  renderClients();
  renderProviders();
  renderResources();
  renderActivity();
  renderStaff();
  const n = state.requests.filter((r) => r.status === 'submitted').length;
  const badge = $('#tab-count-new');
  badge.textContent = n;
  badge.hidden = n === 0;
  document.title = n ? `(${n}) Pink Pack Dashboard` : 'Pink Pack Dashboard';
  if (state.openRequestId) {
    if (state.drawerDirty) {
      const note = $('#req-stale');
      if (note) note.hidden = false;
    } else {
      renderRequestDrawer(state.openRequestId);
    }
  }
}

// ---------------------------------------------------------------------
// Ride requests
// ---------------------------------------------------------------------

function renderKpis() {
  const count = (s) => state.requests.filter((r) => r.status === s).length;
  const now = new Date();
  const fulfilledThisMonth = state.requests.filter((r) => {
    if (r.status !== 'fulfilled' || !r.fulfilled_at) return false;
    const d = new Date(r.fulfilled_at);
    return d.getMonth() === now.getMonth() && d.getFullYear() === now.getFullYear();
  }).length;
  const sum = (kind) => state.resources.filter((r) => r.kind === kind && r.active).reduce((a, r) => a + Number(r.balance), 0);

  const tiles = [
    ['New requests', count('submitted'), 'Waiting for review', count('submitted') > 0],
    ['In review', count('in_review'), 'Decision pending'],
    ['Approved', count('approved'), 'Booked or to book'],
    ['Fulfilled this month', fulfilledThisMonth, now.toLocaleString('en-US', { month: 'long' })],
    ['Vouchers on hand', sum('voucher').toLocaleString('en-US'), 'Across active voucher pools'],
    ['Funding available', fmtAmount('funding', sum('funding')), 'Across active funding pools'],
  ];
  $('#kpis').innerHTML = tiles.map(([label, value, sub, alert]) => `
    <div class="card kpi ${alert ? 'alert' : ''}">
      <div class="label">${esc(label)}</div>
      <div class="value">${esc(value)}</div>
      <div class="sub">${esc(sub)}</div>
    </div>`).join('');
}

function renderRequests() {
  const filters = [
    ['open', 'Open', (r) => OPEN.includes(r.status)],
    ['submitted', 'Submitted', (r) => r.status === 'submitted'],
    ['in_review', 'In review', (r) => r.status === 'in_review'],
    ['approved', 'Approved', (r) => r.status === 'approved'],
    ['fulfilled', 'Fulfilled', (r) => r.status === 'fulfilled'],
    ['denied', 'Denied', (r) => r.status === 'denied'],
    ['all', 'All', () => true],
  ];
  const inService = (r) => state.serviceFilter === 'all' || r.service_type === state.serviceFilter;
  $('#status-filters').innerHTML = filters.map(([key, label, fn]) =>
    `<button class="chip" data-filter="${key}" aria-pressed="${state.filter === key}">${esc(label)}<span class="n">${state.requests.filter((r) => inService(r) && fn(r)).length}</span></button>`,
  ).join('');
  $$('#status-filters .chip').forEach((b) => b.addEventListener('click', () => { state.filter = b.dataset.filter; renderRequests(); }));

  const serviceFilters = [['all', 'All services'],
    ...Object.entries(SERVICE_TYPES).map(([k, v]) => [k, v])];
  $('#service-filters').innerHTML = serviceFilters.map(([key, label]) => {
    const n = key === 'all' ? state.requests.length : state.requests.filter((r) => r.service_type === key).length;
    return `<button class="chip" data-service="${esc(key)}" aria-pressed="${state.serviceFilter === key}">${esc(label)}<span class="n">${n}</span></button>`;
  }).join('');
  $$('#service-filters .chip').forEach((b) => b.addEventListener('click', () => { state.serviceFilter = b.dataset.service; renderRequests(); }));

  const pick = filters.find((f) => f[0] === state.filter)[2];
  let rows = state.requests.filter(pick)
    .filter((r) => state.serviceFilter === 'all' || r.service_type === state.serviceFilter)
    .filter((r) => {
      if (!state.search) return true;
      const c = clientById(r.client_id);
      return [clientName(c), serviceLabel(r), r.pickup_address, r.dropoff_address, c?.phone, c?.email]
        .join(' ').toLowerCase().includes(state.search);
    });
  const descending = ['fulfilled', 'denied', 'all'].includes(state.filter);
  rows = rows.sort((a, b) => (new Date(a.needed_at) - new Date(b.needed_at)) * (descending ? -1 : 1));

  if (!rows.length) {
    $('#requests-body').innerHTML = `<tr><td colspan="7" class="empty">${state.requests.length ? 'No requests match this view.' : 'No requests yet. Add a client and send them their link to get started.'}</td></tr>`;
    return;
  }

  $('#requests-body').innerHTML = rows.map((r) => {
    const c = clientById(r.client_id);
    const past = new Date(r.needed_at) < new Date() && OPEN.includes(r.status);
    const detail = usesAddresses(r.service_type)
      ? `<div class="route"><span>${esc(r.pickup_address || '')}</span><span>${esc(r.dropoff_address || '')}</span></div>`
      : `<div class="sub">${esc(r.provider_name || r.reason_details || '')}</div>${r.requested_amount ? `<div>${esc(fmtAmount('funding', r.requested_amount))} requested</div>` : ''}`;
    return `
      <tr class="clickable ${r.status === 'submitted' ? 'is-new' : ''}" data-id="${esc(r.id)}">
        <td class="nowrap"><span class="pill service ${esc(r.service_type)}">${esc(SERVICE_SHORT[r.service_type] || r.service_type)}</span></td>
        <td class="nowrap"><strong>${esc(fmtDateTime(r.needed_at))}</strong>
          ${r.return_trip ? `<div class="sub">Return ${esc(fmtTime(r.return_at))}</div>` : ''}
          ${past ? `<div class="sub" style="color:var(--red)">${usesAddresses(r.service_type) ? 'Pickup time has passed' : 'Date has passed'}</div>` : ''}</td>
        <td>${esc(clientName(c))}<div class="sub">${esc(r.contact_phone || c?.phone || '')}</div></td>
        <td>${detail}</td>
        <td>${esc(REASONS[r.reason_category] || r.reason_category)}</td>
        <td><span class="pill ${esc(r.status)}">${esc(STATUSES[r.status])}</span></td>
        <td class="nowrap muted">${esc(timeAgo(r.created_at))}</td>
      </tr>`;
  }).join('');
  $$('#requests-body tr[data-id]').forEach((tr) => tr.addEventListener('click', () => openRequest(tr.dataset.id)));
}

function openRequest(id) {
  state.openRequestId = id;
  state.drawerDirty = false;
  renderRequestDrawer(id);
  const dlg = $('#dlg-request');
  if (!dlg.open) dlg.showModal();
}

function renderRequestDrawer(id) {
  const r = state.requests.find((x) => x.id === id);
  if (!r) { $('#req-body').innerHTML = '<p class="muted">This request no longer exists.</p>'; return; }
  const c = clientById(r.client_id);
  const charge = state.transactions.find((t) => t.service_request_id === r.id);
  const isRide = usesAddresses(r.service_type);
  const bal = balanceFor(r.client_id);
  const prov = providerById(r.provider_id);
  const activeResources = state.resources.filter((x) => x.active || x.id === charge?.resource_id);

  $('#req-title').textContent = `${serviceLabel(r)} for ${clientName(c)}`;
  const editWasOpen = $('#req-body details')?.open;

  const reached = {
    submitted: 1, in_review: 2, approved: 3, denied: 3, fulfilled: 4,
  }[r.status];
  const steps = [
    ['Submitted', reached >= 1],
    ['In review', reached >= 2],
    [r.status === 'denied' ? 'Denied' : 'Approved', reached >= 3],
    ['Fulfilled', reached >= 4],
  ];

  let actions = '';
  if (r.status === 'submitted') {
    actions = `
      <div class="panel tinted">
        <h3>Next step</h3>
        <p class="small muted">Mark this request as in review so it is clear someone is working on it.</p>
        <div><button class="btn primary" data-do="in_review">Start review</button></div>
      </div>`;
  } else if (r.status === 'in_review') {
    actions = `
      <div class="panel tinted">
        <h3>Decision</h3>
        <label class="field">Note <span class="hint">Required when denying. Visible to staff only.</span>
          <textarea id="decision-note" maxlength="500">${esc(r.decision_note || '')}</textarea></label>
        <p class="form-error" id="decision-error" hidden></p>
        <div class="toolbar">
          <button class="btn success" data-do="approved">Approve</button>
          <button class="btn danger" data-do="denied">Deny</button>
          <button class="btn ghost" data-do="submitted">Move back to submitted</button>
        </div>
      </div>`;
  } else if (r.status === 'denied') {
    actions = `
      <div class="panel tinted">
        <h3>Denied</h3>
        <p>${esc(r.decision_note || 'No note recorded.')}</p>
        <div><button class="btn" data-do="in_review">Reopen for review</button></div>
      </div>`;
  }

  let booking = '';
  if (r.status === 'approved' || r.status === 'fulfilled') {
    const selectedRes = charge ? charge.resource_id : '';
    booking = `
      <div class="panel">
        <h3>Booking</h3>
        ${r.decision_note ? `<p class="small muted">Approval note: ${esc(r.decision_note)}</p>` : ''}
        <div class="form-grid two">
          <label class="field">${isRide ? 'Ride provider' : 'Provider'}
            <input id="bk-provider" list="providers" value="${esc(r.provider_name || prov?.name || '')}" placeholder="${esc(PROVIDER_HINT[r.service_type] || '')}" /></label>
          <label class="field">${isRide ? 'Confirmation #' : 'Confirmation or code'}
            <input id="bk-confirmation" value="${esc(r.confirmation_code || '')}" /></label>
        </div>
        <datalist id="providers">${providerOptions(r.service_type).map((x) => `<option>${esc(x)}</option>`).join('')}</datalist>
        <p class="notice info" style="margin-top:4px">
          ${esc(clientName(c))} has <strong>${esc(fmtAmount('funding', bal.remaining))}</strong> left
          of ${esc(fmtAmount('funding', bal.allocated))}.
        </p>
        <div class="form-grid two">
          <label class="field">Paid with
            <select id="bk-resource">
              <option value="">Nothing charged</option>
              ${activeResources.map((x) => `<option value="${esc(x.id)}" ${x.id === selectedRes ? 'selected' : ''}>${esc(x.name)} (${esc(fmtAmount(x.kind, x.balance))} left)</option>`).join('')}
            </select></label>
          <label class="field"><span id="bk-amount-label">Amount used</span>
            <input id="bk-amount" type="number" min="0" step="0.01" value="${charge ? esc(Math.abs(charge.amount)) : ''}" /></label>
        </div>
        <p class="notice" id="bk-warning" hidden></p>
        <p class="form-error" id="bk-error" hidden></p>
        <div class="toolbar">
          <button class="btn primary" id="bk-save">${r.booked_at ? 'Update booking' : 'Save booking'}</button>
          ${r.booked_at ? `<span class="small muted">Booked ${esc(fmtDateTime(r.booked_at))}</span>` : ''}
        </div>
      </div>
      <div class="panel tinted">
        ${r.status === 'approved'
          ? `<h3>${isRide ? 'Ride completed?' : 'Service delivered?'}</h3>
             <div class="toolbar"><button class="btn success" data-do="fulfilled">Mark fulfilled</button>
             <button class="btn ghost" data-do="in_review">Move back to review</button></div>`
          : `<h3>Fulfilled ${esc(fmtDateTime(r.fulfilled_at))}</h3>
             <div><button class="btn ghost" data-do="approved">Move back to approved</button></div>`}
      </div>`;
  }

  $('#req-body').innerHTML = `
    <p class="notice info" id="req-stale" hidden>Someone else just changed this request. Close and reopen it to see the latest version before saving.</p>
    <div class="steps">${steps.map(([label, done]) => `<span class="${done ? (label === 'Denied' ? 'bad' : 'done') : ''}">${esc(label)}</span>`).join('')}</div>
    <dl class="detail-list">
      <dt>Service</dt><dd><span class="pill service ${esc(r.service_type)}">${esc(serviceLabel(r))}</span></dd>
      <dt>Client</dt><dd>${esc(clientName(c))}${c?.in_treatment ? ' <span class="pill neutral">In treatment</span>' : ''}</dd>
      <dt>Phone</dt><dd>${esc(r.contact_phone || c?.phone || 'Not provided')}${r.contact_phone && c?.phone && r.contact_phone !== c.phone ? `<div class="small muted">On file: ${esc(c.phone)}</div>` : ''}</dd>
      <dt>Email</dt><dd>${c?.email ? `<a href="mailto:${esc(c.email)}">${esc(c.email)}</a>` : 'Not provided'}</dd>
      <dt>${esc(whenLabel(r))}</dt><dd><strong>${esc(fmtDateTime(r.needed_at))}</strong></dd>
      ${isRide ? `
        <dt>Return trip</dt><dd>${r.return_trip ? esc(fmtDateTime(r.return_at)) : 'No'}</dd>
        <dt>From</dt><dd>${esc(r.pickup_address || '')}</dd>
        <dt>To</dt><dd>${esc(r.dropoff_address || '')}</dd>` : ''}
      ${r.service_type === 'self_care' && prov ? `
        <dt>Service</dt><dd>${esc(prov.name)}
          ${prov.in_home ? '<div class="small muted">In the member\'s home</div>' : ''}
          ${prov.address ? `<div class="small muted">${esc(prov.address)}</div>` : ''}
          <div class="small muted">Text ${esc(prov.contact_phone || '')}${prov.contact_name ? ` (${esc(prov.contact_name)})` : ''}</div>
          <div class="small muted">The member books this themselves.</div></dd>` : ''}
      ${r.service_type === 'gift_card' ? `
        <dt>Card</dt><dd>${esc(GIFT_CARD_STORES[r.gift_card_store] || '')},
          ${esc((GIFT_CARD_FORMATS[r.gift_card_format] || '').toLowerCase())}
          ${r.gift_card_delivery ? `<div class="small muted">${esc(GIFT_CARD_DELIVERY[r.gift_card_delivery])}</div>` : ''}</dd>` : ''}
      ${r.service_type === 'child_care' ? `
        <dt>Care type</dt><dd>${esc(CHILD_CARE_TYPES[r.child_care_type] || '')}</dd>
        <dt>Pay to</dt><dd>${esc(r.vendor_name || '')}<div class="small muted">${esc(r.vendor_contact || '')}</div></dd>
        <dt>Covers</dt><dd>${esc(r.service_period || '')}</dd>` : ''}
      ${r.requested_amount ? `<dt>Amount requested</dt><dd>${esc(fmtAmount('funding', r.requested_amount))}</dd>` : ''}
      <dt>Reason</dt><dd>${esc(REASONS[r.reason_category] || r.reason_category)}${r.reason_details ? `<div class="small muted">${esc(r.reason_details)}</div>` : ''}</dd>
      <dt>Received</dt><dd>${esc(fmtDateTime(r.created_at))}</dd>
    </dl>
    ${actions}
    ${booking}
    <details class="panel">
      <summary><strong>Edit request details</strong></summary>
      <div class="form-grid" style="margin-top:12px">
        <label class="field">${esc(whenLabel(r))}<input id="ed-when" type="datetime-local" value="${esc(toLocalInput(r.needed_at))}" /></label>
        ${isRide ? `
          <label class="check"><input id="ed-return-trip" type="checkbox" ${r.return_trip ? 'checked' : ''} /> Return trip</label>
          <label class="field">Return time<input id="ed-return" type="datetime-local" value="${esc(toLocalInput(r.return_at))}" /></label>
          <label class="field">From<input id="ed-from" value="${esc(r.pickup_address || '')}" maxlength="300" /></label>
          <label class="field">To<input id="ed-to" value="${esc(r.dropoff_address || '')}" maxlength="300" /></label>`
        : `<label class="field">Amount requested <span class="hint">Leave blank if not a dollar amount</span>
             <input id="ed-amount" type="number" min="0.01" step="0.01" value="${r.requested_amount ? esc(r.requested_amount) : ''}" /></label>`}
        <label class="field">Notes<textarea id="ed-details" maxlength="300">${esc(r.reason_details || '')}</textarea></label>
        <label class="field">Contact phone<input id="ed-phone" value="${esc(r.contact_phone || '')}" maxlength="30" /></label>
        <p class="form-error" id="ed-error" hidden></p>
        <div><button class="btn" id="ed-save">Save changes</button></div>
      </div>
    </details>`;

  const body = $('#req-body');
  if (editWasOpen) $('details', body).open = true;
  $$('[data-do]', body).forEach((b) => b.addEventListener('click', () => withBusy(b, () => changeStatus(r, b.dataset.do))));
  $('#ed-save', body).addEventListener('click', (e) => withBusy(e.target, () => saveRequestEdits(r)));
  if (booking) {
    const syncBooking = () => {
      const res = resourceById($('#bk-resource').value);
      $('#bk-amount-label').textContent = res ? (res.kind === 'funding' ? 'Amount spent ($)' : 'Vouchers used') : 'Amount used';
      $('#bk-amount').step = res?.kind === 'voucher' ? '1' : '0.01';
      const amt = Number($('#bk-amount').value || 0);
      const already = charge && res && charge.resource_id === res.id ? Math.abs(charge.amount) : 0;

      // The member's own balance is a hard limit; the pool is a warning.
      const priorOnThis = charge && resourceById(charge.resource_id)?.kind === 'funding'
        ? Math.abs(charge.amount) : 0;
      const memberLeft = Number(bal.remaining) + priorOnThis;
      const overMember = res?.kind === 'funding' && amt > memberLeft;
      const overPool = res && amt > Number(res.balance) + already;

      const w = $('#bk-warning');
      w.hidden = !(overMember || overPool);
      w.classList.toggle('error', overMember);
      if (overMember) {
        w.textContent = `${clientName(c)} only has ${fmtAmount('funding', memberLeft)} left. `
          + 'Saving will be refused. Add funds on their Funds screen first, or lower the amount.';
      } else if (overPool) {
        w.textContent = `${res.name} only has ${fmtAmount(res.kind, Number(res.balance) + already)} available. `
          + 'You can still save, but the pool balance will go negative.';
      }
    };
    $('#bk-resource').addEventListener('change', syncBooking);
    $('#bk-amount').addEventListener('input', syncBooking);
    syncBooking();
    $('#bk-save').addEventListener('click', (e) => withBusy(e.target, () => saveBooking(r)));
  }
}

async function changeStatus(r, status) {
  const patch = { status };
  if (r.status === 'in_review' && (status === 'approved' || status === 'denied')) {
    const note = $('#decision-note')?.value.trim() || '';
    if (status === 'denied' && !note) {
      $('#decision-error').textContent = 'Add a short note explaining the denial.';
      $('#decision-error').hidden = false;
      return;
    }
    patch.decision_note = note || null;
  }
  if (status === 'fulfilled') patch.fulfilled_at = new Date().toISOString();
  if (r.status === 'fulfilled' && status !== 'fulfilled') patch.fulfilled_at = null;

  if (status === 'fulfilled' && !r.booked_at) {
    const ok = await confirmDialog('No booking has been saved for this ride. Mark it fulfilled anyway?', 'Mark fulfilled');
    if (!ok) return;
  }

  const { error } = await supabase.from('service_requests').update(patch).eq('id', r.id);
  if (error) return toast(errMsg(error), 'error');
  state.drawerDirty = false;
  toast(`Request marked ${STATUSES[status].toLowerCase()}.`);
  await loadAll();
}

async function saveBooking(r) {
  const resourceId = $('#bk-resource').value || null;
  const amount = Number($('#bk-amount').value || 0);
  const err = $('#bk-error');
  if (resourceId && !(amount > 0)) {
    err.textContent = 'Enter how much was used, or choose "Nothing charged".';
    err.hidden = false;
    return;
  }
  const res = resourceById(resourceId);
  if (res?.kind === 'voucher' && !Number.isInteger(amount)) {
    err.textContent = 'Vouchers are counted in whole numbers.';
    err.hidden = false;
    return;
  }
  const { error } = await supabase.rpc('fulfill_request', {
    p_request_id: r.id,
    p_provider: $('#bk-provider').value,
    p_confirmation: $('#bk-confirmation').value,
    p_resource_id: resourceId,
    p_amount_used: resourceId ? amount : null,
  });
  if (error) { err.textContent = errMsg(error); err.hidden = false; return; }
  state.drawerDirty = false;
  toast('Booking saved.');
  await loadAll();
}

async function saveRequestEdits(r) {
  const err = $('#ed-error');
  const isRide = usesAddresses(r.service_type);
  const when = fromLocalInput($('#ed-when').value);
  const patch = {
    needed_at: when,
    reason_details: $('#ed-details').value.trim() || null,
    contact_phone: $('#ed-phone').value.trim() || null,
  };
  let msg = '';
  if (!when) msg = `${whenLabel(r)} is required.`;

  if (isRide) {
    const returnTrip = $('#ed-return-trip').checked;
    const ret = returnTrip ? fromLocalInput($('#ed-return').value) : null;
    const from = $('#ed-from').value.trim();
    const to = $('#ed-to').value.trim();
    if (!msg && (!from || !to)) msg = 'Both addresses are required.';
    else if (!msg && returnTrip && (!ret || new Date(ret) <= new Date(when))) msg = 'Return time must be after pickup.';
    Object.assign(patch, { return_trip: returnTrip, return_at: ret, pickup_address: from, dropoff_address: to });
  } else {
    const raw = $('#ed-amount').value.trim();
    const amount = raw === '' ? null : Number(raw);
    if (!msg && amount !== null && !(amount > 0)) msg = 'Enter an amount greater than zero, or leave it blank.';
    patch.requested_amount = amount;
  }
  if (msg) { err.textContent = msg; err.hidden = false; return; }

  const { error } = await supabase.from('service_requests').update(patch).eq('id', r.id);
  if (error) { err.textContent = errMsg(error); err.hidden = false; return; }
  state.drawerDirty = false;
  toast('Request updated.');
  await loadAll();
}

// ---------------------------------------------------------------------
// Clients
// ---------------------------------------------------------------------

function requestLink(c) {
  const base = new URL('request.html', location.origin + location.pathname);
  base.searchParams.set('t', c.request_token);
  return base.toString();
}

function renderClients() {
  const rows = state.clients.filter((c) => !state.clientSearch
    || [clientName(c), c.email, c.phone, MEMBER_GROUPS[c.member_group] || '']
        .join(' ').toLowerCase().includes(state.clientSearch));

  if (!rows.length) {
    $('#clients-body').innerHTML = `<tr><td colspan="7" class="empty">${state.clients.length ? 'No clients match.' : 'No clients yet. Click "Add client" to create the first one.'}</td></tr>`;
    return;
  }
  $('#clients-body').innerHTML = rows.map((c) => {
    const reqs = state.requests.filter((r) => r.client_id === c.id);
    const done = reqs.filter((r) => r.status === 'fulfilled').length;
    const b = balanceFor(c.id);
    const pct = b.allocated > 0 ? Math.max(0, Math.min(100, (b.available / b.allocated) * 100)) : 0;
    const low = b.allocated > 0 && pct <= 15;
    const expired = isExpired(c);
    return `
      <tr data-id="${esc(c.id)}">
        <td><strong>${esc(clientName(c))}</strong><div class="sub">Added ${esc(fmtDate(c.created_at))}</div></td>
        <td>${esc(c.email || '')}<div class="sub">${esc(c.phone || '')}</div></td>
        <td>
          ${c.member_group ? `<span class="pill neutral">${esc(MEMBER_GROUPS[c.member_group])}</span>` : ''}
          ${c.in_treatment ? '<span class="pill neutral">In treatment</span>' : ''}
          <div class="sub">Member since ${esc(fmtDate(c.member_since))}</div>
          <div class="sub"${expired ? ' style="color:var(--red)"' : ''}>${expired ? `Ended ${esc(fmtDate(c.services_expire_on))}` : esc(expiryLabel(c))}</div>
        </td>
        <td class="num">
          <strong${low ? ' style="color:var(--red)"' : ''}>${esc(fmtAmount('funding', b.available))}</strong>
          <div class="sub">of ${esc(fmtAmount('funding', b.allocated))}${Number(b.committed) > 0 ? `, ${esc(fmtAmount('funding', b.committed))} pending` : ''}</div>
          <div class="meter${low ? ' low' : ''}"><span style="width:${pct.toFixed(1)}%"></span></div>
        </td>
        <td class="num">${reqs.length}<div class="sub">${done} fulfilled</div></td>
        <td>${c.request_link_active ? '<span class="pill fulfilled">Active</span>' : '<span class="pill denied">Off</span>'}</td>
        <td class="nowrap" style="text-align:right">
          <button class="btn sm" data-client-funds>Funds</button>
          <button class="btn sm ghost" data-client-link>Link</button>
          <button class="btn sm ghost" data-client-edit>Edit</button>
        </td>
      </tr>`;
  }).join('');
  $$('#clients-body tr[data-id]').forEach((tr) => {
    const c = clientById(tr.dataset.id);
    $('[data-client-funds]', tr)?.addEventListener('click', () => openFundsDialog(c.id));
    $('[data-client-link]', tr)?.addEventListener('click', () => openLinkDialog(c.id));
    $('[data-client-edit]', tr)?.addEventListener('click', () => openClientForm(c));
  });
}

let editingClientId = null;
function openClientForm(c = null) {
  const form = $('#form-client');
  form.reset();
  formError(form, '');
  editingClientId = c?.id || null;
  $('#client-form-title').textContent = c ? 'Edit client' : 'Add client';
  if (c) {
    form.first_name.value = c.first_name;
    form.last_name.value = c.last_name || '';
    form.email.value = c.email || '';
    form.phone.value = c.phone || '';
    form.member_since.value = c.member_since || '';
    form.member_group.value = c.member_group || '';
    form.services_expire_on.value = c.services_expire_on || '';
    form.no_expiry.checked = !c.services_expire_on;
    form.in_treatment.checked = c.in_treatment;
  } else {
    form.member_since.value = new Date().toISOString().slice(0, 10);
    form.no_expiry.checked = true;
  }

  // "Does not expire" and a cutoff date are the same decision, so only
  // one of them is on screen at a time.
  const syncExpiry = () => { $('#expiry-field').hidden = form.no_expiry.checked; };
  form.no_expiry.onchange = syncExpiry;
  syncExpiry();

  $('#dlg-client').showModal();
}

async function saveClient(e) {
  e.preventDefault();
  const form = e.target;
  const btn = $('button[type="submit"]', form);
  await withBusy(btn, async () => {
    const row = {
      first_name: form.first_name.value.trim(),
      last_name: form.last_name.value.trim(),
      email: form.email.value.trim().toLowerCase() || null,
      phone: form.phone.value.trim() || null,
      member_since: form.member_since.value || null,
      member_group: form.member_group.value || null,
      services_expire_on: form.no_expiry.checked ? null : (form.services_expire_on.value || null),
      in_treatment: form.in_treatment.checked,
    };
    if (!row.first_name) return formError(form, 'First name is required.');
    if (!row.member_since) return formError(form, 'Member since date is required.');
    if (!form.no_expiry.checked && !row.services_expire_on) {
      return formError(form, 'Enter a date, or tick "Direct services do not expire".');
    }
    const q = editingClientId
      ? supabase.from('clients').update(row).eq('id', editingClientId).select().single()
      : supabase.from('clients').insert(row).select().single();
    const { data, error } = await q;
    if (error) return formError(form, errMsg(error));
    $('#dlg-client').close();
    await loadAll();
    if (!editingClientId) openLinkDialog(data.id, true);
    else toast('Client updated.');
  });
}

// ---------------------------------------------------------------------
// Member funding: what they were given, what they spent, what is left
// ---------------------------------------------------------------------

function openFundsDialog(clientId) {
  const c = clientById(clientId);
  if (!c) return;
  const b = balanceFor(clientId);
  const grants = state.allocations.filter((a) => a.client_id === clientId);
  const charges = state.transactions.filter((t) => {
    if (!t.service_request_id || t.amount >= 0) return false;
    const req = state.requests.find((r) => r.id === t.service_request_id);
    const res = state.resources.find((x) => x.id === t.resource_id);
    return req?.client_id === clientId && res?.kind === 'funding';
  });
  const pct = b.allocated > 0 ? Math.max(0, Math.min(100, (b.remaining / b.allocated) * 100)) : 0;

  $('#funds-title').textContent = `${clientName(c)}: funding`;
  $('#funds-body').innerHTML = `
    <div class="kpis">
      <div class="card kpi"><div class="label">Allocated</div><div class="value">${esc(fmtAmount('funding', b.allocated))}</div></div>
      <div class="card kpi"><div class="label">Spent</div><div class="value">${esc(fmtAmount('funding', b.spent))}</div></div>
      <div class="card kpi"><div class="label">Remaining</div><div class="value"${pct <= 15 ? ' style="color:var(--red)"' : ''}>${esc(fmtAmount('funding', b.remaining))}</div></div>
    </div>
    <div class="meter lg${pct <= 15 ? ' low' : ''}"><span style="width:${pct.toFixed(1)}%"></span></div>

    <details class="panel" style="margin-top:16px">
      <summary><strong>Add funds or make a correction</strong></summary>
      <div class="form-grid two" style="margin-top:12px">
        <label class="field">Amount <span class="hint">Use a negative number to take funds back</span>
          <input id="fund-amount" type="number" step="0.01" placeholder="500" /></label>
        <label class="field">Note<input id="fund-note" maxlength="200" placeholder="Additional grant" /></label>
      </div>
      <p class="form-error" id="fund-error" hidden></p>
      <div class="toolbar"><button class="btn primary" id="fund-save">Save</button></div>
    </details>

    <h3 style="margin-top:20px">Allocations</h3>
    <div class="card table-wrap">
      <table><thead><tr><th>Date</th><th>Amount</th><th>Note</th><th>By</th><th></th></tr></thead>
      <tbody>${grants.length ? grants.map((a) => `
        <tr>
          <td class="nowrap">${esc(fmtDate(a.granted_on))}</td>
          <td class="num"${a.amount < 0 ? ' style="color:var(--red)"' : ''}>${esc(fmtAmount('funding', a.amount))}</td>
          <td>${esc(a.note || '')}</td>
          <td class="small muted">${esc(a.created_by || '')}</td>
          <td style="text-align:right"><button class="btn sm ghost" data-del-alloc="${esc(a.id)}">Remove</button></td>
        </tr>`).join('') : '<tr><td colspan="5" class="empty">No allocations yet.</td></tr>'}
      </tbody></table>
    </div>

    <h3 style="margin-top:20px">What it was spent on</h3>
    <div class="card table-wrap">
      <table><thead><tr><th>Date</th><th>Amount</th><th>Service</th><th></th></tr></thead>
      <tbody>${charges.length ? charges.map((t) => `
        <tr>
          <td class="nowrap">${esc(fmtDate(t.occurred_on))}</td>
          <td class="num">${esc(fmtAmount('funding', Math.abs(t.amount)))}</td>
          <td>${esc(t.description)}</td>
          <td style="text-align:right"><button class="btn sm ghost" data-open-request="${esc(t.service_request_id)}">View</button></td>
        </tr>`).join('') : '<tr><td colspan="4" class="empty">Nothing spent yet.</td></tr>'}
      </tbody></table>
    </div>`;

  $('#fund-save').addEventListener('click', (e) => withBusy(e.target, async () => {
    const err = $('#fund-error');
    const amount = Number($('#fund-amount').value);
    if (!amount) { err.textContent = 'Enter an amount.'; err.hidden = false; return; }
    const { error } = await supabase.from('client_allocations').insert({
      client_id: clientId, amount, note: $('#fund-note').value.trim() || null,
    });
    if (error) { err.textContent = errMsg(error); err.hidden = false; return; }
    await loadAll();
    openFundsDialog(clientId);
    toast('Allocation saved.');
  }));

  $$('#funds-body [data-del-alloc]').forEach((btn) => btn.addEventListener('click', (e) =>
    withBusy(e.target, async () => {
      const yes = await confirmDialog(
        `Remove this allocation? ${clientName(c)}'s balance will change.`, 'Remove', true);
      if (!yes) return;
      const { error } = await supabase.from('client_allocations').delete().eq('id', btn.dataset.delAlloc);
      if (error) return toast(errMsg(error), 'error');
      await loadAll();
      openFundsDialog(clientId);
      toast('Allocation removed.');
    })));

  $$('#funds-body [data-open-request]').forEach((btn) => btn.addEventListener('click', () => {
    $('#dlg-funds').close();
    openRequest(btn.dataset.openRequest);
  }));

  // This runs again after each save to refresh the numbers, so the
  // dialog may already be open; showModal() throws if it is.
  const dlg = $('#dlg-funds');
  if (!dlg.open) dlg.showModal();
}

// ---------------------------------------------------------------------
// Providers: the vendors members choose from
// ---------------------------------------------------------------------

function renderProviders() {
  const rows = state.providers;
  if (!rows.length) {
    $('#providers-body').innerHTML =
      '<tr><td colspan="7" class="empty">No providers yet. Click "Add provider" to create the first one.</td></tr>';
    return;
  }
  $('#providers-body').innerHTML = rows.map((p) => {
    const cost = p.cost_varies ? 'Varies'
      : (p.session_cost ? fmtAmount('funding', p.session_cost) : 'Not set');
    const where = p.in_home ? "In the member's home" : (p.address || '');
    return `
      <tr data-id="${esc(p.id)}">
        <td><strong>${esc(p.name)}</strong>${p.languages ? `<div class="sub">${esc(p.languages)}</div>` : ''}</td>
        <td><span class="pill service ${esc(p.service_type)}">${esc(SERVICE_SHORT[p.service_type] || p.service_type)}</span></td>
        <td class="num">${esc(cost)}</td>
        <td>${esc(p.contact_phone || '')}${p.contact_name ? `<div class="sub">${esc(p.contact_name)}</div>` : ''}</td>
        <td class="small">${esc(where)}</td>
        <td>${p.active ? '<span class="pill fulfilled">Yes</span>' : '<span class="pill denied">Hidden</span>'}</td>
        <td style="text-align:right"><button class="btn sm ghost" data-provider-edit>Edit</button></td>
      </tr>`;
  }).join('');
  $$('#providers-body tr[data-id]').forEach((tr) => {
    $('[data-provider-edit]', tr)?.addEventListener('click',
      () => openProviderForm(providerById(tr.dataset.id)));
  });
}

let editingProviderId = null;
function openProviderForm(p = null) {
  const form = $('#form-provider');
  form.reset();
  formError(form, '');
  editingProviderId = p?.id || null;
  $('#provider-form-title').textContent = p ? 'Edit provider' : 'Add provider';
  if (p) {
    form.name.value = p.name;
    form.service_type.value = p.service_type;
    form.session_cost.value = p.session_cost ?? '';
    form.cost_varies.checked = p.cost_varies;
    form.contact_name.value = p.contact_name || '';
    form.contact_phone.value = p.contact_phone || '';
    form.address.value = p.address || '';
    form.languages.value = p.languages || '';
    form.in_home.checked = p.in_home;
    form.notes.value = p.notes || '';
    form.sort_order.value = p.sort_order;
    form.active.checked = p.active;
  }
  $('#dlg-provider').showModal();
}

async function saveProvider(e) {
  e.preventDefault();
  const form = e.target;
  await withBusy($('button[type="submit"]', form), async () => {
    const costVaries = form.cost_varies.checked;
    const row = {
      name: form.name.value.trim(),
      service_type: form.service_type.value,
      session_cost: costVaries ? null : (Number(form.session_cost.value) || null),
      cost_varies: costVaries,
      contact_name: form.contact_name.value.trim() || null,
      contact_phone: form.contact_phone.value.trim() || null,
      address: form.address.value.trim() || null,
      languages: form.languages.value.trim() || null,
      in_home: form.in_home.checked,
      notes: form.notes.value.trim() || null,
      sort_order: Number(form.sort_order.value) || 100,
      active: form.active.checked,
    };
    if (!row.name) return formError(form, 'Name is required.');
    if (!costVaries && !row.session_cost) {
      return formError(form, 'Enter a cost, or tick "Cost varies".');
    }
    const q = editingProviderId
      ? supabase.from('providers').update(row).eq('id', editingProviderId)
      : supabase.from('providers').insert(row);
    const { error } = await q;
    if (error) return formError(form, errMsg(error));
    $('#dlg-provider').close();
    await loadAll();
    toast(editingProviderId ? 'Provider updated.' : 'Provider added.');
  });
}

function openLinkDialog(clientId, justCreated = false) {
  const c = clientById(clientId);
  if (!c) return;
  const url = requestLink(c);
  const subject = `Your ${ORG_NAME} ride request link`;
  const bodyText = `Hi ${c.first_name},\n\nHere is your personal link to request a ride from ${ORG_NAME}:\n${url}\n\nUse it any time you need a ride to treatment or another appointment. Please keep this link to yourself. We will contact you to confirm each ride.\n\nQuestions? Call us at ${ORG_PHONE}.\n\n${ORG_NAME}`;
  const mailto = `mailto:${encodeURIComponent(c.email || '')}?subject=${encodeURIComponent(subject)}&body=${encodeURIComponent(bodyText)}`;

  $('#link-body').innerHTML = `
    ${justCreated ? `<p class="notice info">${esc(clientName(c))} was added. Send them this link so they can request rides.</p>` : ''}
    <p><strong>${esc(clientName(c))}</strong> ${c.request_link_active ? '<span class="pill fulfilled">Active</span>' : '<span class="pill denied">Off</span>'}</p>
    ${c.request_link_active ? `
      <div class="link-box"><input readonly value="${esc(url)}" id="link-url" /><button class="btn" id="link-copy">Copy</button></div>
      <div class="toolbar">
        <a class="btn primary" href="${esc(mailto)}">${c.email ? 'Email link' : 'Open email with link'}</a>
      </div>` : '<p class="muted">This link is turned off. The client cannot submit requests until you turn it back on.</p>'}
    <div class="panel tinted">
      <h3>Link controls</h3>
      <p class="small muted">Turn the link off to stop new requests. Make a new link if the old one was shared with the wrong person. The old link stops working immediately.</p>
      <div class="toolbar">
        <button class="btn" id="link-toggle">${c.request_link_active ? 'Turn link off' : 'Turn link on'}</button>
        <button class="btn danger" id="link-rotate">Make a new link</button>
      </div>
    </div>`;

  $('#link-copy')?.addEventListener('click', async () => {
    try { await navigator.clipboard.writeText(url); toast('Link copied.'); } catch { $('#link-url').select(); }
  });
  $('#link-toggle').addEventListener('click', (e) => withBusy(e.target, async () => {
    const { error } = await supabase.from('clients').update({ request_link_active: !c.request_link_active }).eq('id', c.id);
    if (error) return toast(errMsg(error), 'error');
    await loadAll();
    openLinkDialog(c.id);
  }));
  $('#link-rotate').addEventListener('click', (e) => withBusy(e.target, async () => {
    const ok = await confirmDialog(`Make a new link for ${clientName(c)}? The current link will stop working.`, 'Make new link', true);
    if (!ok) return;
    const token = crypto.randomUUID().replaceAll('-', '');
    const { error } = await supabase.from('clients').update({ request_token: token, request_link_active: true }).eq('id', c.id);
    if (error) return toast(errMsg(error), 'error');
    await loadAll();
    openLinkDialog(c.id);
    toast('New link created. Send it to the client.');
  }));

  const dlg = $('#dlg-link');
  if (!dlg.open) dlg.showModal();
}

// ---------------------------------------------------------------------
// Resources
// ---------------------------------------------------------------------

function renderResources() {
  const list = [...state.resources].sort((a, b) => Number(b.active) - Number(a.active) || a.name.localeCompare(b.name));
  $('#resource-cards').innerHTML = list.length ? list.map((r) => `
    <div class="card resource" data-id="${esc(r.id)}" style="${r.active ? '' : 'opacity:.6'}">
      <div class="top">
        <div><h3>${esc(r.name)}</h3><div class="small muted">${r.kind === 'funding' ? 'Funding' : 'Vouchers'}${r.active ? '' : ' · Archived'}</div></div>
        <button class="btn sm ghost" data-res-toggle>${r.active ? 'Archive' : 'Restore'}</button>
      </div>
      <div class="balance ${Number(r.balance) <= 0 ? 'low' : ''}">${esc(fmtAmount(r.kind, r.balance))}</div>
      <div class="small muted">Used to date: ${esc(fmtAmount(r.kind, Math.abs(r.total_used)))}</div>
      ${r.notes ? `<div class="small">${esc(r.notes)}</div>` : ''}
      <div class="toolbar">
        <button class="btn sm" data-res-add>Add</button>
        <button class="btn sm" data-res-use>Use</button>
      </div>
    </div>`).join('') : '<div class="card empty">No resources yet. Add a funding pool or voucher stock.</div>';

  $$('#resource-cards [data-id]').forEach((card) => {
    const r = resourceById(card.dataset.id);
    $('[data-res-add]', card).addEventListener('click', () => openTransactionForm(r.id, 'add'));
    $('[data-res-use]', card).addEventListener('click', () => openTransactionForm(r.id, 'use'));
    $('[data-res-toggle]', card).addEventListener('click', (e) => withBusy(e.target, async () => {
      const { error } = await supabase.from('resources').update({ active: !r.active }).eq('id', r.id);
      if (error) return toast(errMsg(error), 'error');
      await loadAll();
    }));
  });

  $('#ledger-body').innerHTML = state.transactions.length ? state.transactions.map((t) => {
    const r = resourceById(t.resource_id);
    return `
      <tr>
        <td class="nowrap">${esc(fmtDate(t.occurred_on))}</td>
        <td>${esc(r?.name || '')}</td>
        <td class="nowrap num ${t.amount < 0 ? 'amount-neg' : 'amount-pos'}">${t.amount > 0 ? '+' : ''}${esc(fmtAmount(r?.kind, t.amount))}</td>
        <td>${esc(t.description)}${t.service_request_id ? ` <button class="btn sm ghost" data-open-request="${esc(t.service_request_id)}">View request</button>` : ''}</td>
        <td class="small muted">${esc(t.created_by || '')}</td>
      </tr>`;
  }).join('') : '<tr><td colspan="5" class="empty">No history yet.</td></tr>';
  $$('#ledger-body [data-open-request]').forEach((b) => b.addEventListener('click', () => openRequest(b.dataset.openRequest)));
}

function openResourceForm() {
  const form = $('#form-resource');
  form.reset();
  formError(form, '');
  $('#dlg-resource').showModal();
}

async function saveResource(e) {
  e.preventDefault();
  const form = e.target;
  await withBusy($('button[type="submit"]', form), async () => {
    const { error } = await supabase.from('resources').insert({
      name: form.elements.name.value.trim(), kind: form.elements.kind.value, notes: form.elements.notes.value.trim() || null,
    });
    if (error) return formError(form, error.code === '23505' ? 'A resource with that name already exists.' : errMsg(error));
    $('#dlg-resource').close();
    toast('Resource added. Record its starting balance with "Add".');
    await loadAll();
  });
}

function syncTxLabel() {
  const form = $('#form-transaction');
  const r = resourceById(form.resource_id.value);
  $('#tx-amount-label').textContent = r?.kind === 'voucher' ? 'Number of vouchers' : 'Amount ($)';
  form.amount.step = r?.kind === 'voucher' ? '1' : '0.01';
  form.amount.min = r?.kind === 'voucher' ? '1' : '0.01';
}

function openTransactionForm(resourceId = null, direction = 'add') {
  const form = $('#form-transaction');
  form.reset();
  formError(form, '');
  const active = state.resources.filter((r) => r.active);
  if (!active.length) return toast('Add a resource first.', 'error');
  form.resource_id.innerHTML = active.map((r) => `<option value="${esc(r.id)}">${esc(r.name)}</option>`).join('');
  if (resourceId) form.resource_id.value = resourceId;
  form.direction.value = direction;
  const today = new Date();
  form.occurred_on.value = `${today.getFullYear()}-${String(today.getMonth() + 1).padStart(2, '0')}-${String(today.getDate()).padStart(2, '0')}`;
  syncTxLabel();
  $('#dlg-transaction').showModal();
}

async function saveTransaction(e) {
  e.preventDefault();
  const form = e.target;
  await withBusy($('button[type="submit"]', form), async () => {
    const r = resourceById(form.resource_id.value);
    const amount = Number(form.amount.value);
    if (!(amount > 0)) return formError(form, 'Enter an amount greater than zero.');
    if (r?.kind === 'voucher' && !Number.isInteger(amount)) return formError(form, 'Vouchers are counted in whole numbers.');
    const { error } = await supabase.from('resource_transactions').insert({
      resource_id: form.resource_id.value,
      amount: form.direction.value === 'use' ? -amount : amount,
      description: form.description.value.trim(),
      occurred_on: form.occurred_on.value,
    });
    if (error) return formError(form, errMsg(error));
    $('#dlg-transaction').close();
    toast('Saved.');
    await loadAll();
  });
}

// ---------------------------------------------------------------------
// Activity log
// ---------------------------------------------------------------------

const TABLE_LABELS = {
  staff: 'staff access', clients: 'client', resources: 'resource',
  service_requests: 'service request',
  providers: 'provider',
  client_allocations: 'allocation',
  app_settings: 'setting', resource_transactions: 'resource history',
};
const FIELD_LABELS = {
  status: 'status', needed_at: 'needed', return_at: 'return time', return_trip: 'return trip',
  pickup_address: 'from', dropoff_address: 'to', decision_note: 'note', provider_name: 'provider',
  confirmation_code: 'confirmation #', booked_at: 'booked', fulfilled_at: 'fulfilled', contact_phone: 'phone',
  first_name: 'first name', last_name: 'last name', email: 'email', phone: 'phone', in_treatment: 'in treatment',
  request_link_active: 'request link on', role: 'role', full_name: 'name', name: 'name', active: 'active',
  notes: 'notes', amount: 'amount', description: 'description', reason_category: 'reason', reason_details: 'reason details',
};
const HIDDEN_FIELDS = new Set(['updated_at', 'created_at', 'id', 'request_token', 'client_id', 'created_by', 'resource_id', 'service_request_id']);

function fmtValue(key, v) {
  if (v === null || v === undefined || v === '') return '(blank)';
  if (typeof v === 'boolean') return v ? 'yes' : 'no';
  if (key === 'status') return STATUSES[v] || v;
  if (key === 'reason_category') return REASONS[v] || v;
  if (key === 'service_type') return SERVICE_TYPES[v] || v;
  if (key === 'member_group') return MEMBER_GROUPS[v] || v;
  if (key === 'gift_card_store') return GIFT_CARD_STORES[v] || v;
  if (key === 'gift_card_format') return GIFT_CARD_FORMATS[v] || v;
  if (key === 'gift_card_delivery') return GIFT_CARD_DELIVERY[v] || v;
  if (key === 'child_care_type') return CHILD_CARE_TYPES[v] || v;
  if (/_at$/.test(key)) return fmtDateTime(v);
  return String(v).length > 60 ? `${String(v).slice(0, 60)}…` : String(v);
}

function subjectOf(row) {
  const d = row.new_data || row.old_data || {};
  switch (row.table_name) {
    case 'clients': return `${d.first_name || ''} ${d.last_name || ''}`.trim();
    case 'service_requests': {
      const c = clientById(d.client_id);
      const label = SERVICE_SHORT[d.service_type] || 'request';
      return `${label.toLowerCase()} for ${c ? clientName(c) : 'client'}, ${fmtDateTime(d.needed_at)}`;
    }
    case 'resources': return d.name;
    case 'resource_transactions': {
      const r = resourceById(d.resource_id);
      return `${r?.name || 'resource'} ${Number(d.amount) > 0 ? '+' : ''}${fmtAmount(r?.kind, d.amount)} (${d.description})`;
    }
    case 'staff': return d.email;
    case 'providers': return d.name;
    case 'app_settings': return d.key === 'default_allocation' ? 'default allocation' : d.key;
    case 'client_allocations': {
      const c = clientById(d.client_id);
      return `${fmtAmount('funding', d.amount)} for ${c ? clientName(c) : 'a member'}`;
    }
    default: return '';
  }
}

function renderActivity() {
  if (!state.audit.length) {
    $('#activity-list').innerHTML = '<li class="empty" style="display:block">No activity yet.</li>';
    return;
  }
  $('#activity-list').innerHTML = state.audit.map((row) => {
    const verb = { insert: 'added', update: 'updated', delete: 'removed' }[row.action];
    let changes = '';
    if (row.action === 'update' && row.old_data && row.new_data) {
      const keys = Object.keys(row.new_data).filter((k) =>
        JSON.stringify(row.new_data[k]) !== JSON.stringify(row.old_data[k]));
      const parts = [];
      if (keys.includes('request_token')) parts.push('made a new request link');
      for (const k of keys.filter((x) => !HIDDEN_FIELDS.has(x)).slice(0, 5)) {
        parts.push(`${FIELD_LABELS[k] || k}: ${fmtValue(k, row.old_data[k])} → ${fmtValue(k, row.new_data[k])}`);
      }
      changes = parts.join(' · ');
    }
    return `
      <li>
        <div class="when">${esc(fmtDateTime(row.changed_at))}</div>
        <div>
          <span class="who">${esc(row.changed_by)}</span> ${esc(verb)} ${esc(TABLE_LABELS[row.table_name] || row.table_name)}
          <strong>${esc(subjectOf(row))}</strong>
          ${changes ? `<div class="changes">${esc(changes)}</div>` : ''}
        </div>
      </li>`;
  }).join('');
}

// ---------------------------------------------------------------------
// Staff access (admins only)
// ---------------------------------------------------------------------

// Admin-only. Changing the default affects new members only; existing
// balances are left alone, which is why that is said on screen.
function renderSettings() {
  const current = state.settings.default_allocation ?? '';
  $('#setting-default-allocation').value = current;
  const btn = $('#setting-save');
  if (btn.dataset.wired) return;
  btn.dataset.wired = '1';
  btn.addEventListener('click', (e) => withBusy(e.target, async () => {
    const err = $('#setting-error');
    const raw = $('#setting-default-allocation').value.trim();
    const amount = Number(raw);
    if (raw === '' || !Number.isFinite(amount) || amount < 0) {
      err.textContent = 'Enter an amount of zero or more.';
      err.hidden = false;
      return;
    }
    err.hidden = true;
    const { error } = await supabase.from('app_settings')
      .update({ value: String(amount) }).eq('key', 'default_allocation');
    if (error) { err.textContent = errMsg(error); err.hidden = false; return; }
    await loadAll();
    toast('Default allocation saved. New members will get this amount.');
  }));
}

function renderStaff() {
  if (!state.isAdmin) return;
  renderSettings();
  const me = state.me.email;
  $('#staff-body').innerHTML = state.staff.map((s) => `
    <tr data-email="${esc(s.email)}">
      <td>${esc(s.full_name || '')}${s.email === me ? ' <span class="pill neutral">You</span>' : ''}</td>
      <td>${esc(s.email)}</td>
      <td>
        <select data-role ${s.email === me ? 'disabled' : ''} style="width:auto">
          <option value="staff" ${s.role === 'staff' ? 'selected' : ''}>Staff</option>
          <option value="admin" ${s.role === 'admin' ? 'selected' : ''}>Admin</option>
        </select>
      </td>
      <td class="muted small">${esc(fmtDate(s.created_at))}</td>
      <td style="text-align:right">${s.email === me ? '' : '<button class="btn sm danger" data-remove>Remove</button>'}</td>
    </tr>`).join('');

  $$('#staff-body tr').forEach((tr) => {
    const email = tr.dataset.email;
    $('[data-role]', tr).addEventListener('change', async (e) => {
      const { error } = await supabase.from('staff').update({ role: e.target.value }).eq('email', email);
      if (error) toast(errMsg(error), 'error'); else toast('Role updated.');
      await loadAll();
    });
    $('[data-remove]', tr)?.addEventListener('click', async (e) => {
      const ok = await confirmDialog(`Remove ${email}? They will lose access immediately.`, 'Remove', true);
      if (!ok) return;
      await withBusy(e.target, async () => {
        const { error } = await supabase.from('staff').delete().eq('email', email);
        if (error) return toast(errMsg(error), 'error');
        toast('Access removed.');
        await loadAll();
      });
    });
  });
}

function openStaffForm() {
  const form = $('#form-staff');
  form.reset();
  formError(form, '');
  $('#dlg-staff').showModal();
}

async function saveStaff(e) {
  e.preventDefault();
  const form = e.target;
  await withBusy($('button[type="submit"]', form), async () => {
    const { error } = await supabase.from('staff').insert({
      email: form.email.value.trim().toLowerCase(), full_name: form.full_name.value.trim() || null, role: form.role.value,
    });
    if (error) return formError(form, error.code === '23505' ? 'That email already has access.' : errMsg(error));
    $('#dlg-staff').close();
    toast('Access granted. They can now sign in with Google.');
    await loadAll();
  });
}

boot();
