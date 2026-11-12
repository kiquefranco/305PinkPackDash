# 305 Pink Pack Dashboard

Internal dashboard for 305 Pink Pack. Staff handle service requests for the people Pink Pack serves and track funding and vouchers. Four services are supported: rides, self-care services, grocery gift cards, and child care. Clients request through a private link that only Pink Pack sends.

Built by the Hyperion Council team, Fall 2026.

## What it does

| Area | What it does |
|---|---|
| **Requests** | New requests appear on the dashboard live. Each one is tagged with its service and moves through Submitted, In review, Approved or Denied, and Fulfilled. Filter by service with the chips above the table. |
| **Booking** | When a request is approved, staff record the provider, the confirmation number, and what it cost. The cost comes out of a funding pool or the voucher stock automatically. |
| **Clients** | Staff add a member, set their join date, group and whether their services expire, and send them a personal link. Only people with a link can submit. Links can be turned off or replaced at any time. |
| **Providers** | The vendors members can use. Self-care vendors show on the member's page with price and contact details; members book those themselves. |
| **Member funding** | Each member gets their own allocation ($2,000 by default, editable by an admin). Every funded service draws it down, and the clients table shows what is left. Booking is refused if a charge would take a member past their balance. |
| **Resources** | Balances for funding and vouchers, with a full history of every addition and use. |
| **Activity log** | Every change, who made it, and when. |
| **Staff access** | Admins decide which Google accounts can sign in. |

## What it costs

$0 per month. The stack:

- **GitHub Pages** hosts the website. It is free for public repositories.
- **Supabase** (free plan) provides the database, the Google sign-in, and the live updates.
- **Google Cloud** provides the Google sign-in credentials. They are free.

The free Supabase plan includes a 500 MB database and 50,000 monthly active users. This dashboard will use a small fraction of both. Supabase pauses free projects after 7 days without activity. The included GitHub Action pings the database every 3 days, so the project never pauses.

## Security model

- Staff sign in with Google. Signing in alone gives no access. The Google email must also be on the staff list in the database.
- The request form cannot read any data. It can only call two database functions: one checks that a link is valid, and the other submits a request for that link's client.
- Every table is protected by row level security in the database, not by the website code. The Supabase key in `config.js` is designed to be public and is safe in a public repository.
- **Never** put the Supabase `service_role` or secret key in this repository.
- No diagnosis or medical detail is stored. The only health field is "In treatment". The form asks clients not to include medical details.

## Files

```
index.html                     Staff dashboard
request.html                   The member's own page (opened from their private link)
assets/css/styles.css          Styles for both pages
assets/js/config.js            Supabase URL and key, org name and phone  <- edit this
assets/js/shared.js            Supabase connection and shared helpers
assets/js/dashboard.js         Dashboard logic
assets/js/request.js           Request form logic
supabase/schema.sql            Database tables, security rules, functions
supabase/migrations/           Changes to apply to a database that is already live
supabase/seed.sql              First staff accounts and starting resources  <- edit this
.github/workflows/keepalive.yml  Keeps the free Supabase project awake
```

There is no build step. The files in the repo are the website.

---

## Setup (about 45 minutes, one time)

Use an account that belongs to 305 Pink Pack for Supabase and Google Cloud where possible, so the organization keeps ownership after the semester.

### 1. Create the Supabase project

1. Go to [supabase.com](https://supabase.com) and create a free account.
2. Click **New project**. Name it `pink-pack-dashboard`, choose the **East US** region, and save the database password somewhere safe.
3. Wait for the project to finish setting up.

### 2. Create the database

1. Open `supabase/seed.sql` and replace `rosemary@replace-me.org` with the Google account Rosemary will sign in with. Change the admin email if needed.
2. In Supabase, open **SQL Editor**, click **New query**, paste the full contents of `supabase/schema.sql`, and click **Run**.
3. Open another new query, paste the contents of `supabase/seed.sql`, and click **Run**.

### 3. Connect the website to Supabase

1. In Supabase, go to **Project Settings > API Keys** (or **API** on older projects).
2. Copy the **Project URL** and the **publishable** key (starts with `sb_publishable_`). Older projects show an **anon public** key instead. Either works.
3. Paste both into `assets/js/config.js`.
4. Commit and push.

### 4. Turn on GitHub Pages

1. In the GitHub repo, go to **Settings > Pages**.
2. Under **Build and deployment**, choose **Deploy from a branch**, branch `main`, folder `/ (root)`, and save.
3. After a minute, the site is live at `https://<github-username>.github.io/<repo-name>/`. This is the **dashboard URL**.

GitHub Pages is free only for public repositories. A private repository with Pages needs GitHub Team. Verified nonprofits get that free through GitHub for Nonprofits.

### 5. Set up Google sign-in

**In Google Cloud:**

1. Go to [console.cloud.google.com](https://console.cloud.google.com) and create a project named `Pink Pack Dashboard`.
2. Open **APIs & Services > OAuth consent screen** (also called **Google Auth Platform**). Choose **External**. Enter the app name `305 Pink Pack Dashboard` and a support email. Only the default scopes (email, profile, openid) are needed.
3. Set the publishing status to **In production**. Apps that only use the default scopes do not need Google verification.
4. Open **Credentials > Create credentials > OAuth client ID** and choose **Web application**.
   - **Authorized JavaScript origins:** `https://<github-username>.github.io`
   - **Authorized redirect URIs:** `https://<project-ref>.supabase.co/auth/v1/callback` (Supabase shows this exact URL on its Google provider page)
5. Copy the **Client ID** and **Client secret**.

**In Supabase:**

1. Go to **Authentication > Sign In / Providers > Google**, turn it on, paste the Client ID and secret, and save.
2. Go to **Authentication > URL Configuration**.
   - **Site URL:** the dashboard URL from step 4
   - **Redirect URLs:** add the dashboard URL. Add `http://localhost:8000/` as well if you test locally.

### 6. Turn on the keep-alive job

1. In the GitHub repo, go to **Settings > Secrets and variables > Actions > New repository secret**.
2. Add `SUPABASE_URL` with the Project URL.
3. Add `SUPABASE_KEY` with the publishable (or anon) key.
4. Go to the **Actions** tab, open **Keep Supabase awake**, and click **Run workflow** once to confirm it passes.

### 7. Test the full flow

1. Open the dashboard URL and sign in with the admin Google account.
2. Go to **Clients**, add a test client, and copy their link.
3. Open the link in a private window and submit a request.
4. The request should appear on the dashboard within a second or two, without refreshing.
5. Move it through review, approve it, save a booking against a resource, and mark it fulfilled. Check that the resource balance and the activity log update.
6. Sign in with a Google account that is not on the staff list and confirm you see **No access yet**.

---

## Day-to-day use

**New client:** Clients > Add client > send the link from the dialog. **Email link** opens a pre-written email.

**New request:** It shows up under Requests with a pink marker, and the tab shows a count. Open it and click **Start review**.

**Decide:** Approve, or deny with a short note. Notes are visible only to staff.

**Book:** On an approved request, enter the provider and confirmation number. Choose which resource paid for it and how much, then save. The balance updates immediately.

**Complete:** After the service is delivered, click **Mark fulfilled**.

### The member's page

Each member's private link opens a page showing when they joined, whether their direct services have an end date, how much funding they have left, and everything they can spend it on. From there they can request a ride, a self-care service, a grocery gift card, or child care help.

They also see every request they have made: what is still waiting on Pink Pack, and what happened to the rest. An open request shows the amount as held rather than spent; a fulfilled one shows what was actually used and its confirmation code; a denied one says plainly that nothing came off their balance.

Staff decision notes are never shown to members. Those are written by staff for each other, so if Pink Pack wants to explain a denial to a member, that needs a separate field written for the member to read.

Two rules are enforced on the server, not just in the browser:

- A member cannot request more than they have available. Requests already waiting for review are held against the balance, so four small requests cannot quietly add up to more than their allocation.
- Self-care prices come from the provider directory, never from the member's browser.

Self-care works differently from the rest. The member contacts the vendor themselves to book, and the session cost comes off their balance. Nothing needs arranging on Pink Pack's end, so these requests are a record and a deduction rather than a job.

### Providers

Providers > **Add provider** to add a vendor. Name, service, cost per session, and a phone number to text are what members see. Tick **Cost varies** for anything without a fixed price, and untick **Shown to members** to hide a vendor without deleting the history attached to it.

The four self-care vendors Rosemary uses are created by migration `003`, with their prices and contact details. Edit them like any other provider; re-running the migration will not overwrite your changes.

### Member funding

Every member added to the dashboard automatically receives the default allocation, shown in the Balance column on the Clients tab. Click **Funds** on a member's row to see what they were given, what they have spent and on what, and to add money or correct a mistake.

A negative amount takes funds back, which is how you reverse a grant entered twice. Removing an allocation row does the same thing and leaves a record in the audit log either way.

Vouchers are counted in units rather than dollars, so charging a ride to the voucher stock does not reduce a member's dollar balance.

Admins set the default for new members under **Staff access > Member funding**. Changing it does not touch members who already exist.

**Add funds or vouchers:** Resources > **Add** on the resource card. Record the source in the description (for example, "Grant from Miami Foundation").

**Link shared with the wrong person:** Clients > Link > **Make a new link**. The old link stops working immediately.

**Give someone access:** Staff access > Add person (admins only). Use the exact Google account they sign in with.

When two people edit the same request at the same time, the last save wins. Every change is recorded in the activity log, so nothing is lost without a trace.

## Test locally

```
python3 -m http.server 8000
```

Then open `http://localhost:8000/`. Google sign-in works locally once `http://localhost:8000/` is in the Supabase redirect URLs.

## Changing the database later

Edit `supabase/schema.sql` and re-run it in the SQL Editor. It is safe to re-run: existing tables and data are kept, and functions, policies and triggers are replaced. Adding a column to an existing table needs an `alter table ... add column if not exists ...` statement.

Renaming or reshaping something that already holds data is different: `schema.sql` only creates tables that do not exist yet, so it will not touch them. Those changes go in a numbered file under `supabase/migrations/`, run once in the SQL Editor, and the same change is also written into `schema.sql` so a fresh install matches a migrated one.

### Migrations to date

| File | What it does | Run it if |
|---|---|---|
| `001_services.sql` | Turns ride requests into service requests covering rides, self-care, gift cards and child care | Your database was created before October 2026 and still has a `ride_requests` table |
| `002_client_balances.sql` | Gives each member their own funding balance and blocks bookings that would exceed it | Your database has no `client_allocations` table. Run `001` first. |
| `003_members_and_providers.sql` | Adds join date, group and expiration; the provider directory with Rosemary's vendors; and the fields each service needs | Your database has no `providers` table. Run `001` and `002` first. |
| `004_member_requests.sql` | Lets members see their own requests on their page | Your database has no `list_member_requests` function. Run `001` to `003` first. |

Migrations are safe to re-run, but run them in order and do not go back to an older one after a newer one. After running `001` or `003`, the member page must be on the matching version of the code, since the function it calls changed.

## Limits to know

- The dashboard is designed for a desktop browser. The request form works on phones.
- Requests show in Eastern time.
- A client can have at most 5 requests waiting for review at once. This blocks spam if a link leaks.
- Pickup times must be in the future and within the next 6 months.
