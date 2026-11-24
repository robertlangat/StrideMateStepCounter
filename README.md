# StrideMate – Step Counter

Walking is better together. StrideMate is a free Flutter app for Android and iOS. It counts steps privately on the phone and adds private groups, chat, leaderboards and step challenges (including Mystery Mode) on a Supabase/PostgreSQL backend. There are no subscriptions or paywalls, and no account is needed to start counting.

> **Status:** backend, Android step-counter core and Dart unit tests pass, and CI builds the debug APK (see [docs/TEST_RESULTS.md](docs/TEST_RESULTS.md)). On-device verification and the iOS Xcode project are still to do: [docs/HANDOVER.md](docs/HANDOVER.md).

## Features

- **Today**:
  - step count and goal ring,
  - distance and *estimated* calories,
  - last-updated and last-sync time,
  - clear banners when a sensor, permission or data source is unavailable,
  - streak and Rest Day chips.
- **History**:
  - day (hourly), week, month and year views,
  - accessible charts (spoken summary, goal shown by colour *and* ✓, table view),
  - records and achievements,
  - monthly and yearly **Recaps** shareable as an image with an optional photo.
- **Step sources**:
  - Android hardware step counter with background sampling, boot/shutdown handling and an optional live-count notification;
  - iOS Core Motion;
  - Health Connect / Apple Health for wearables;
  - an hourly source-priority policy that prevents double counting.
- **Groups** (private, up to 15,000 members):
  - expiring or revocable invite codes and links,
  - owner/admin/member roles,
  - paginated members and leaderboards (today, yesterday, week, month) with your own rank always shown,
  - chat with quick cheers and mutable taunts,
  - block, report and admin moderation,
  - per-group step visibility.
- **Challenges**:
  - dated or ongoing, with a fixed time zone,
  - **Mystery Mode** enforced in the API, realtime, notifications and CSV,
  - CSV export for admins,
  - defined late-upload and finality rules.
- **Rankings**: opt-in country and global boards for real people. Country is chosen manually, never by GPS.
- **Privacy**: offline-first, server-side authorization (RLS + RPCs), rate limits, implausible-activity checks, data export and account deletion.
- **Widgets**: Android home-screen widget (native) and iOS WidgetKit widget, both with a stale indicator.
- Light and dark themes in the icon's midnight navy, mint and ivory, plus large-text support.

Rules for ties, streaks, Mystery Mode, finality and visibility are in [docs/PRODUCT_RULES.md](docs/PRODUCT_RULES.md).

## Repository layout

```
lib/
  domain/        pure Dart rules: source merge, streaks, achievements, bots, recaps (unit-tested)
  data/          local SQLite store, step sources, sync engine, Supabase API
  features/      Today, Groups, Challenges, History, Profile, Recap, Rankings screens
  widgets/       step ring, accessible bar chart, ranking list
android/app/src/main/
  java/.../steps/StepCounterLogic.java   reboot/reset/rollover logic (JUnit-tested)
  kotlin/.../steps/                      sensor reader, store, service, WorkManager, boot/shutdown
  kotlin/.../widget/                     home-screen widget
ios/             AppDelegate (Core Motion), Info.plist, entitlements, WidgetKit widget, Podfile
supabase/
  migrations/    schema, RLS, RPCs, rankings, Mystery Mode, CSV, jobs
  tests/         SQL test suite + 15,000-member load test
scripts/         test_db.sh, test_step_logic.sh, bootstrap_ios.sh
docs/            rules, sources, wearables, deployment, privacy, test results, handover, store copy
```

## Local setup

Requirements: Flutter 3.32 (stable), JDK 17, Android SDK (API 35), and for iOS, a Mac with Xcode 16 and CocoaPods.

```bash
git clone https://github.com/robertlangat/StrideMateStepCounter.git
cd StrideMateStepCounter
flutter pub get
cp config/dart_defines.example.json config/dart_defines.json   # fill in values (git-ignored)
flutter run --dart-define-from-file=config/dart_defines.json
```

Without `SUPABASE_URL` / `SUPABASE_ANON_KEY` the app runs in **offline mode**. Step tracking, history, goals, bots and recaps all work, and the Groups and Challenges tabs are hidden (the app shows Today, History and Profile). They appear automatically in a build with the backend configured.

### Environment variables (`--dart-define`)

| Name | Required | Purpose |
|---|---|---|
| `SUPABASE_URL` | for social/sync | Supabase project URL |
| `SUPABASE_ANON_KEY` | for social/sync | Supabase anon (public) key. Never use the service-role key. |
| `SUPPORT_EMAIL` | placeholder | Defaults to `support@stridemate.example` |
| `TERMS_URL` | placeholder | Defaults to `https://stridemate.example/terms` |
| `PRIVACY_URL` | placeholder | Defaults to `https://stridemate.example/privacy` |
| `INVITE_BASE_URL` | optional | Web prefix for invite links (`…/CODE` should redirect to `stridemate://join/CODE`) |
| `ADS_ENABLED` | optional | `false` turns ads off (default `true`) |
| `ADMOB_BANNER_ANDROID` / `ADMOB_BANNER_IOS` | release only | Your AdMob banner unit IDs. When unset, Google's **test** units are used. |

### Ads (AdMob)

- The app shows an anchored adaptive banner above the bottom navigation bar.
- It also shows an interstitial on natural breaks: opening Recaps or Achievements, never in the first 2 minutes of a session, and at most once every 4 minutes.

| Build | Ads |
|---|---|
| Play Store release (`flutter build appbundle --release`) | **Real StrideMate units**: app `ca-app-pub-8306955081407788~5196832723`, banner `…/1308277343`, interstitial `…/1257587713` |
| Debug builds and the sideloaded test APK (`--dart-define=USE_TEST_ADS=true`) | Google's test units (safe to tap) |
| iOS | Google's test units until real iOS units are created |

Never tap real ads on your own devices; use the test APK for testing. Ad requests contain no step or health data.

Backend setup (migrations, pg_cron, auth email code template): [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md).

## Health permissions

| Platform | Permission | Used for | Requested when |
|---|---|---|---|
| Android | `ACTIVITY_RECOGNITION` | Hardware step counter | "Allow motion access" |
| Android | `health.READ_STEPS`, `health.READ_HEALTH_DATA_HISTORY` | Health Connect steps (wearables) | "Connect" in Step sources |
| Android | `FOREGROUND_SERVICE_HEALTH`, `POST_NOTIFICATIONS` | Optional live-count notification | Enabling Live counting |
| Android | `RECEIVE_BOOT_COMPLETED` | Re-baseline the counter after reboot | — |
| iOS | `NSMotionUsageDescription` | Core Motion pedometer | "Allow motion access" |
| iOS | `NSHealthShareUsageDescription` (+ required Update text) | Read steps from Apple Health | "Connect" in Step sources |

Location is never requested. The Health Connect rationale screen is wired through the `ACTION_SHOW_PERMISSIONS_RATIONALE` / `VIEW_PERMISSION_USAGE` intent filters. Before publishing, complete Google Play's Health Connect declaration and point it to your Privacy Policy URL.

## Wearable compatibility

These are read via Health Connect / Apple Health. Paths were checked in November 2026; each still needs a device test.

| Brand | Android (Health Connect) | iOS (Apple Health) |
|---|---|---|
| Fitbit / Pixel Watch (Google Health app) | ✓ | ✓ (app 5.05+) |
| Garmin | ✓ (Android 14+) | ✓ |
| Samsung Galaxy Watch | ✓ | — (Android-only) |
| Oura | ✓ | ✓ |
| WHOOP | ✓ (some step-sync reports) | ✓ |
| Withings | ✓* | ✓* |
| Xiaomi Mi Band (Mi Fitness) | ✓ | ✓ |
| Amazfit (Zepp) | ✓ | ✓ |

\*New Withings accounts since 13 Oct 2026 need Withings+ to export. Exact menu paths, companion apps and the device checklist are in [docs/WEARABLES.md](docs/WEARABLES.md). No direct vendor-API integrations were added (no credentials).

## Build

### Android debug APK

```bash
flutter build apk --debug --dart-define-from-file=config/dart_defines.json
# -> build/app/outputs/flutter-apk/app-debug.apk
```

CI builds this on every push; download it from Actions › CI › *stridemate-debug-apk*.

### Android signed release AAB

1. Create an upload key once. Keep it out of the repo:
   ```bash
   keytool -genkey -v -keystore ~/stridemate-upload.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload
   ```
2. Create `android/key.properties` (git-ignored):
   ```properties
   storeFile=/absolute/path/to/stridemate-upload.jks
   storePassword=...
   keyAlias=upload
   keyPassword=...
   ```
3. Build:
   ```bash
   flutter build appbundle --release --dart-define-from-file=config/dart_defines.json
   # -> build/app/outputs/bundle/release/app-release.aab
   ```

Alternatively, run the manual **Release AAB** workflow with the repository secrets listed in `.github/workflows/release-aab.yml`. Without a key, release builds fall back to debug signing (installable for testing, rejected by Play).

### iOS

On a Mac:

```bash
scripts/bootstrap_ios.sh        # generates Runner.xcodeproj, icons, pods; prints Xcode steps
open ios/Runner.xcworkspace     # set Team, add HealthKit + App Groups, add the widget target
flutter run --dart-define-from-file=config/dart_defines.json
```

HealthKit and Core Motion require a physical iPhone.

## Tests

```bash
scripts/test_db.sh --load       # SQL suite + 15,000-member load test (needs psql + PostgreSQL 15+)
scripts/test_step_logic.sh      # Android step-counter logic (JDK only)
TZ=Africa/Nairobi flutter test  # Dart unit tests
```

Results from the build environment: [docs/TEST_RESULTS.md](docs/TEST_RESULTS.md).

## More docs

- [Product rules](docs/PRODUCT_RULES.md)
- [Step sources & edge cases](docs/STEP_SOURCES.md)
- [Wearables](docs/WEARABLES.md)
- [Deployment](docs/DEPLOYMENT.md)
- [Privacy & security](docs/PRIVACY_SECURITY.md)
- [Store copy](docs/STORE_LISTING.md)
- [Handover](docs/HANDOVER.md)
