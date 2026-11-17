# Test results

Run on 17 Nov 2026 in the build environment (PostgreSQL 16.15, OpenJDK 21, Linux x86-64), and again in GitHub CI on the same day, where the database suite, load test, step-logic tests, Dart unit tests and debug APK build all passed. Commands are in the README. CI (`.github/workflows/ci.yml`) re-runs all suites on every push.

## What was executed here, and what wasn't

| Suite | Language | Executed here? | Result |
|---|---|---|---|
| Backend: migrations, RLS, RPCs, Mystery Mode, CSV, finality, privacy | SQL (`supabase/tests/*.sql`) | ✅ yes | **14/14 test groups pass** |
| Large-group load test (15,000 synthetic members) | SQL | ✅ yes | **pass, timings below** |
| Android step-counter core (reboots, resets, rollover, clock changes) | Java/JUnit (`android/app/src/test`) | ✅ yes, with the JDK | **10/10 pass** |
| Dart unit tests: de-duplication, rollover, streaks, rest days, bots, recaps, sync retries | Dart (`test/`) | ❌ no Flutter SDK offline; ✅ **passed in GitHub CI** (`TZ=Africa/Nairobi flutter test`) | pass |
| `flutter analyze` + Android debug APK build | — | ❌ no SDK offline; ✅ **passed in GitHub CI** (Flutter 3.32, no analyzer errors, APK built) | APK artifact `stridemate-debug-apk` on [CI run](https://github.com/robertlangat/StrideMateStepCounter/actions/runs/44050157089) |
| On-device behaviour (sensors, Health Connect, HealthKit, widgets, background) | — | ❌ needs physical devices | see HANDOVER.md |

## Backend suite: `scripts/test_db.sh --load`

```
Migrations applied: 5
== supabase/tests/10_sync_and_steps.sql
  PASS sync idempotency
  PASS source de-duplication
  PASS midnight rollover / time zones
  PASS validation / implausible activity
  PASS upload rate limit
  PASS rest days
== supabase/tests/20_groups_privacy.sql
  PASS invites
  PASS roles / ownership
  PASS chat / moderation
  PASS leaderboards / ties / visibility
  PASS global rankings
  PASS export / account deletion
== supabase/tests/30_challenges_mystery_csv.sql
  PASS mystery mode (API, boards, global, CSV, notifications, realtime)
  PASS late uploads / finality
ALL DATABASE TESTS PASSED
```

### What each requested area covers

| Requested area | Where | Assertions (abridged) |
|---|---|---|
| **Sync retries** | 10 › sync idempotency | Same batch id replayed: returned as `duplicate` and the total is unchanged. Same data under a new id: unchanged. A stale lower value is ignored. A growing hour advances. In-batch duplicates collapse. |
| **Source de-duplication** | 10 › source de-duplication | Phone 1,000 + watch 1,200 in the same hour = 1,200, never 2,200. Hours where only one source has steps still count. `prefer_phone` / `prefer_health` fallbacks work. |
| **Midnight rollover** | 10 › midnight rollover | 21:00 UTC lands on the next day in Nairobi but the same day in a UTC group. Half-hour zone (Kolkata) handled. A user changing time zone has history rebuilt. |
| **Offline counting** (server side) | 10 › sync idempotency | Late batches max-merge. Client-side offline queueing is in `test/sync/sync_core_test.dart` (CI). |
| **Permission changes** (server side) | 20 › leaderboards | Per-group "share steps" off: absent from that group, present in another. Private profile: absent everywhere. Non-sharing member still sees own total and is unranked. |
| **Privacy controls** | 20 › leaderboards, export / deletion | Other users' buckets, daily totals and profiles are unreadable (RLS). Rankings and standings tables are not directly readable. Anon has no access. A user cannot clear their own moderation flag or rename another user. Export contains only own data. Account deletion removes the auth user, steps, dailies and messages, hands groups to an admin, and removes empty groups. |
| **Mystery Mode** | 30 › mystery mode | Others see completed days only, and no hidden value appears anywhere in the payload. Own live and today totals are visible. Rank is computed on revealed data. No leak through group day/week boards, another non-Mystery challenge, global boards, notifications or realtime (only `messages` and `notifications` are published). |
| **CSV export** | 30 › mystery mode | Admin-only. Header omits today in Mystery Mode. Totals and ranks match the app. Quote escaping and `=formula` neutralisation. Non-Mystery CSV labels the live day `(in progress)`. Mystery cut-off is respected in another challenge's export. |
| **Late uploads / finality** | 30 › late uploads | Finalised at end + 1 day + 48 h. After that, uploads change personal history but not standings or CSV. Within grace, a late upload re-scores. |
| **Chat moderation** | 20 › chat | Block hides messages via RLS (and therefore realtime) and RPC. Taunt mute/disable. Only preset cheers/taunts. Non-members refused. Reports listed to admins only. Delete, mute and message rate limit. |
| **Invites and roles** | 20 › invites, roles | Expiry, revocation, max uses, case-insensitive codes. Admin vs owner powers. Ownership transfer on leave. |
| **Rate limits and implausible activity** | 10 › validation, rate limit | 241st upload/hour refused. Misaligned, future or unknown buckets rejected. 40,000 steps/hour clamped and account flagged; flagged users excluded from global boards. |

## Large-group load test (15,000 synthetic members)

`supabase/tests/load/large_group_load_test.sql` builds:

- one group with 15,000 members,
- 31 days of daily totals (465,000 rows) and 37 hours of hourly data (555,000 rows),
- then a 15,000-participant Mystery Mode challenge.

Each step runs in its own transaction after `VACUUM ANALYZE`, as the pg_cron jobs do in production.

```
LOAD setup: 15000 members, 465025 daily rows, 555026 hourly rows in 115.1 s
LOAD refresh_group_rankings (4 boards: today, yesterday, week, month x 15k members): 1272 ms
LOAD get_group_leaderboard first page (50 rows + own rank): 2.48 ms avg
LOAD get_group_leaderboard deep keyset page (rank > 7000, month): 2.21 ms avg
LOAD get_group_members page: 0.37 ms avg
LOAD upload_step_buckets by a member of the 15k group: 1.96 ms avg
LOAD refresh_challenge_standings (15k participants, 30 days, Mystery Mode): 591 ms
LOAD refresh_group_rankings with all 15k members in Mystery Mode (hourly cut-offs): 1965 ms
LOAD get_challenge_leaderboard (Mystery, own rank): 1.88 ms avg
LOAD export_challenge_csv: 15000 rows x 29 day columns, 2694 KB in 2438 ms (includes re-scoring)
LOAD refresh_dirty_boards (all boards incl. 15k group + 15k challenge): 14 boards in 3825 ms
PASS large-group load test (15,000 members)
```

The query plan for a leaderboard page is an **Index Only Scan** on `group_rankings_page` with the keyset condition, so it doesn't sort the group. Budgets enforced by the test: interactive reads under 50 ms, uploads under 250 ms.

**Interpretation**

- Every request a user makes stays at about 2 ms regardless of group size.
- The background re-rank of a 15,000-member group takes about 1.3 s, or about 2 s in the worst case where every member is in a Mystery challenge. It runs at most once a minute per changed group.
- These numbers come from a single laptop-class PostgreSQL. Supabase instance sizes differ, so re-run the test on your tier before launch.

## Android step-counter logic: `scripts/test_step_logic.sh`

```
  PASS countsDeltasIntoCurrentHour
  PASS rebootDetectedByCounterReset
  PASS duplicateReadingCountsNothing
  PASS firstReadingIsBaselineOnly
  PASS spreadsLongGapAcrossHoursAndKeepsExactTotal
  PASS midnightRolloverSplitsAtHourBoundary
  PASS rebootDetectedByBootCountEvenIfCounterHigher
  PASS wallClockJumpBackDoesNotLoseOrInventSteps
  PASS implausibleJumpIsClamped
  PASS veryLongGapSpreadIsBoundedToSevenDays
10 passed, 0 failed
```

## Dart unit tests (run in GitHub CI: passed)

| File | Covers |
|---|---|
| `test/domain/source_merge_test.dart` | Overlap = max, non-overlap = sum, preferences, duplicates, rollover, DST-safe day arithmetic |
| `test/domain/goals_test.dart` | Rest days, in-progress today, missed days, goal history, achievements, records, Chill/Active/Yesterday bots, distance/calorie estimates, monthly recap |
| `test/sync/sync_core_test.dart` | Offline queue then upload, lost-response retry with the same batch id (no inflation), growing hour re-sent as cumulative, separate sources, permission revoked, back-off cap |

CI runs them with `TZ=Africa/Nairobi` so local-day boundaries differ from UTC.
