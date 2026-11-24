# Privacy and security design

## Data minimisation

- **No account needed** to count steps, see history, set goals and Rest Days, earn achievements, race the bots or make recaps. All of that data stays in on-device SQLite.
- **Signing in** uploads only what account features need:
  - per-source hourly step buckets,
  - goal history and Rest Days (for consistent streaks),
  - earned achievement keys,
  - profile settings.
- Body weight is used only for the calorie estimate and **never leaves the device**.
- **No location** is requested or stored. Country is chosen from a list.
- Android backup and device transfer are excluded (`data_extraction_rules.xml`), so health data is not copied to Google Drive backups.

## Advertising

- StrideMate shows AdMob banner ads (test ads by default).
- Ad requests never include step counts, health-platform data, goals or group information. This is required by Google Play's Health Connect policy, and it is also a StrideMate rule.
- The Google Mobile Ads SDK collects the advertising ID and device information. Declare this in Play's **Data safety** form and mark the listing **Contains ads**.
- Before showing personalised ads in the EEA/UK/Switzerland, add a consent flow (Google's User Messaging Platform) and publish the GDPR message in AdMob › Privacy & messaging. Not implemented yet.
- On iOS, App Tracking Transparency is not requested, so iOS ads are not personalised.

## Server-side enforcement

- **Every table has Row Level Security.**
  - Direct reads are limited to the caller's own rows, plus group/chat rows of groups the caller belongs to.
  - Leaderboards, standings, `group_rankings`, `challenge_standings` and `global_rankings` have **no client policies** and can only be read through RPCs.
  - Those RPCs apply membership, privacy, block and Mystery Mode rules.
- **Writes go through `SECURITY DEFINER` RPCs** that check `auth.uid()`, role and rate limits. Their `search_path` is pinned.
  - Profiles allow updates only to whitelisted columns, through column grants. Moderation flags cannot be changed by users.
  - EXECUTE on all functions is revoked from `public`/`anon` and granted only for the RPCs the app uses.
- **Secrets**: the app ships only the Supabase URL and the anon key, which are public by design. There is no service-role key in the client or the repo. Release signing secrets are read from git-ignored `android/key.properties` or CI secrets.
- **Abuse controls**:
  - per-user rate limits for uploads, messages, invites, joins, reports, exports and creation;
  - implausible-activity checks (hour > 15,000 steps is clamped and flagged; day > 150,000 is flagged);
  - flagged users are excluded from global boards;
  - invite codes have 50 bits of entropy plus join throttling;
  - CSV formula-injection neutralisation.

## User controls

| Control | Where |
|---|---|
| Keep my steps private (all groups, challenges, rankings) | Profile › Privacy |
| Share my steps with *this* group | Group › Settings |
| Join / leave country & global rankings, pick country | Profile › Privacy |
| Mute taunts (per group); block / report users and messages | Group chat, Members |
| Disconnect Health Connect / Apple Health (keep or delete imported history) | Profile › Step sources |
| Export my data (device + account JSON) | Profile › Your data |
| Delete account (all server data; groups handed over) | Profile › Your data |
| Erase data on this device | Profile › Your data |
| Leave group | Group › Settings |

## Permissions requested, and when

| Permission | Asked when |
|---|---|
| Physical activity (Android) / Motion & Fitness (iOS) | "Allow motion access" in onboarding, or the Today banner |
| Health Connect / HealthKit read Steps | "Connect" in Step sources |
| Notifications (Android 13+) | Enabling Live counting |
| Photos | Picking a recap background (system picker) |
