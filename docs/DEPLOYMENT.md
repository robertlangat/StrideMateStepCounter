# Backend deployment (Supabase + PostgreSQL)

The whole backend is SQL: tables, Row Level Security, SECURITY DEFINER RPCs and pg_cron jobs. There are no Edge Functions and no server-side secrets in the app.

## 1. Create the project

1. Create a Supabase project. Note the **Project URL** and **anon public key** (Settings › API). The **service_role key is never used by the app**; don't put it anywhere in this repo.
2. Database › Extensions: enable **pg_cron**. The migration also tries `create extension if not exists pg_cron`.

## 2. Apply migrations

```bash
npm i -g supabase            # or: brew install supabase/tap/supabase
supabase login
supabase link --project-ref <your-project-ref>
supabase db push             # applies supabase/migrations/*.sql in order
```

The migrations create:

- **Tables**: profiles, step buckets, daily totals, groups, members, invites, messages, blocks, reports, notifications, challenges, standings, rankings, rate events, sync batches.
- **RLS policies and grants**: least privilege. Clients can read only their own rows or rows of groups they belong to, and leaderboard tables are RPC-only.
- **RPCs**: called by the app.
- **pg_cron jobs**:
  - `stridemate-minutely` runs `run_minutely_jobs()`: finalises due challenges and re-ranks dirty boards.
  - `stridemate-hourly` runs `run_hourly_jobs()` at :05: day rollover, global rankings, daily Mystery-safe challenge notices, and rate-event cleanup.
- **Realtime**: `messages` and `notifications` are added to the `supabase_realtime` publication.

Verify the jobs with `select jobname, schedule from cron.job;`.

## 3. Auth (email one-time code)

- Authentication › Providers › Email: enable it. Turn **off** "Confirm email" (the code itself verifies the address).
- Authentication › Email Templates › **Magic Link**: include the code, for example `Your StrideMate code is {{ .Token }}`. The app signs in with `verifyOTP(type: email)`.
- Authentication › SMTP: configure your own SMTP sender for production. The built-in sender is heavily rate-limited.
- Optional: Sign in with Apple / Google needs platform credentials and is **not implemented**.

## 4. Configure the app

Copy `config/dart_defines.example.json` to `config/dart_defines.json` (git-ignored) and fill in the URL and anon key, plus the support email, Terms URL and Privacy URL once you have them. Then build with:

```bash
flutter run --dart-define-from-file=config/dart_defines.json
```

## 5. Invite links (optional)

Invites work with codes alone. For tappable links, host a page at `INVITE_BASE_URL/<CODE>` that redirects to `stridemate://join/<CODE>`. Android App Links / iOS Universal Links would need `assetlinks.json` / `apple-app-site-association` on your domain; this is not configured.

## 6. Push notifications (not configured)

Notifications (cheers, taunts, daily challenge results) are written to the `notifications` table, which the app shows in-app. Delivering them as push messages needs:

- FCM (Android) and APNs (iOS) credentials, and
- a small Database Webhook or Edge Function that sends a push for each inserted row.

## Running the database tests

```bash
# Against any PostgreSQL 15+ server where you can create databases:
DATABASE_URL=postgresql://postgres:postgres@localhost:5432/postgres scripts/test_db.sh --load
```

The tests apply a small shim (`supabase/tests/00_supabase_shim.sql`) that provides `auth.users`, `auth.uid()` and the Supabase roles, then the real migrations.
