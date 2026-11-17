# Handover

## Build environment limits (read first)

This code was written in an environment that could reach GitHub but **could not download the Flutter SDK, the Android SDK, pub packages, Gradle plugins or CocoaPods**. The Flutter app was therefore first compiled by **GitHub CI**. On 17 Nov 2026 the CI run for this branch passed every job ([run](https://github.com/robertlangat/StrideMateStepCounter/actions/runs/44050157089)):

- database suite and 15,000-member load test on PostgreSQL 16,
- Android step-counter JUnit tests,
- `flutter pub get`, `flutter analyze` (no errors), Dart unit tests,
- **`flutter build apk --debug`**: the installable APK is the `stridemate-debug-apk` artifact on that run page. It was built without Supabase secrets, so it runs in offline mode; add the `SUPABASE_URL` / `SUPABASE_ANON_KEY` repository secrets to get a backend-enabled APK.

What has **not** been exercised anywhere yet is behaviour on real phones (below).

## Status by milestone

| Milestone | Status |
|---|---|
| 1. Solo step tracking + history (phone sensor, Health Connect/HealthKit, offline store, de-dup, Today, History, goals, streaks) | Implemented. Android counter core **verified** (JDK tests); app compiles and the APK builds in CI. On-device checks pending. |
| 2. Accounts + sync (email code sign-in, idempotent upload, restore on new device) | Implemented. Server **verified**; client sync core has unit tests (CI). |
| 3. Groups + challenges (invites, roles, chat, cheers/taunts, moderation, leaderboards, Mystery Mode, CSV) | Implemented. Server **verified**, including a 15,000-member load test. |
| 4. Widgets, recaps, rankings, bots, iOS | Implemented. Android widget and notification are native. iOS sources and widget are written, but the Xcode project must be generated on a Mac (`scripts/bootstrap_ios.sh`). |

## Verified here

- All 5 SQL migrations apply cleanly on PostgreSQL 16.
- 14 backend test groups pass: sync idempotency, de-duplication, rollover and time zones, validation, rate limits, rest days, invites, roles, chat moderation, leaderboards and ties, privacy/RLS, global rankings, export and deletion, Mystery Mode across every surface, CSV, late uploads and finality.
- Load test with 15,000 synthetic members: interactive reads about 2 ms, upload about 2 ms, full re-rank 1.3–2 s, CSV of 15,000 × 29 days in 2.4 s.
- Android `StepCounterLogic`: 10 JUnit tests pass (reboots, counter resets, clock jumps, midnight split, long gaps, glitches).
- Launcher icons generated from the supplied StrideMate artwork (all densities plus adaptive and monochrome).
- Wearable sync paths checked against public sources, November 2026 (docs/WEARABLES.md).

## Next steps

1. Download `stridemate-debug-apk` from the CI run and install it on an Android phone (enable "install unknown apps").
2. Create the Supabase project (docs/DEPLOYMENT.md), add the two secrets, and re-run CI for a backend-enabled APK.

## Needs a physical device

| Area | What to check |
|---|---|
| Android hardware step counter | Counts with the app closed. A reboot keeps steps since the last sample. 15-minute sampling. Live-counting notification. Force-stop and battery-saver delays. |
| Health Connect | Permission flow and rationale screen, 30-day backfill, revoke and reconnect, contributing-apps list, each wearable in WEARABLES.md |
| iOS Core Motion + HealthKit | Motion prompt, 7-day backfill, HealthKit read authorization (iOS never reports read-denied; the UI handles this), Settings revocation |
| Home-screen widgets | Android widget updates from app and background sampler; stale indicator after 2 h. iOS WidgetKit extension after adding the target. |
| Deep links | `stridemate://join/CODE` on both platforms |
| Accessibility | TalkBack/VoiceOver on Today ring, charts (summary + Table view), leaderboards; 200% font scale; dark theme contrast |
| Recap share | Image rendering with and without a photo, share sheet |

## External settings and credentials you need to supply

| Item | Where it goes | Needed for |
|---|---|---|
| Supabase project URL + anon key | `config/dart_defines.json` (local) / CI secrets `SUPABASE_URL`, `SUPABASE_ANON_KEY` | Accounts, sync, groups, challenges, rankings |
| pg_cron enabled + migrations pushed | Supabase dashboard / `supabase db push` | Server-maintained rankings, finality, notices |
| Email OTP template containing `{{ .Token }}` + custom SMTP | Supabase Auth settings | Sign-in codes in production |
| Support email, Terms URL, Privacy Policy URL | `SUPPORT_EMAIL`, `TERMS_URL`, `PRIVACY_URL` defines (placeholders `*.example` until provided) | Profile › About, sign-in screen, store listing |
| Android upload keystore + passwords | `android/key.properties` (git-ignored) or CI secrets `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD` | Signed release AAB |
| Google Play Console: Health Connect declaration (READ_STEPS, READ_HEALTH_DATA_HISTORY), foreground-service "health" declaration, Data safety form | Play Console | Play review |
| Apple Developer team, bundle id `com.stridemate.app`, HealthKit + App Groups (`group.com.stridemate.app`) capabilities | Xcode / developer portal | iOS build, HealthKit, widget |
| Optional: FCM + APNs keys and a webhook to send pushes for `notifications` rows | Firebase / Apple / Supabase | Push delivery of cheers and results (in-app inbox works without it) |
| Optional: domain for invite links (`INVITE_BASE_URL`) and App Links / Universal Links files | Your web host | Tappable https invite links |
| Optional: vendor API credentials (Fitbit/Google, Garmin Health, Oura, WHOOP, Withings) | — | Direct integrations; not implemented, as health platforms already cover them |

## Known limitations

- Half-hour and 45-minute time zones attribute each hour bucket to the day in which it starts. Up to 30–45 minutes can fall on the adjacent day.
- iOS does not reveal whether HealthKit *read* access was granted. If the user declines, StrideMate shows 0 from Apple Health and keeps using Core Motion.
- Health Connect normally exposes only 30 days before the permission grant. `READ_HEALTH_DATA_HISTORY` is declared but the extra prompt is not requested yet.
- Push notifications are in-app only until FCM/APNs are configured.
- Global "today" boards use each person's own local date, so the first and last hours of a date overlap across time zones by design.
