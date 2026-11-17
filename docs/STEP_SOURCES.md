# Step sources, de-duplication and edge cases

## Sources

| Source id | Platform | What it is |
|---|---|---|
| `phone:android` | Android | Hardware `TYPE_STEP_COUNTER` read by native code (`android/.../steps`). It counts while StrideMate is closed. |
| `phone:ios` | iOS | Core Motion `CMPedometer`. The motion coprocessor keeps counting and holds 7 days of history. |
| `health:connect` | Android | Health Connect **aggregated** step total per hour (`getTotalStepsInInterval`) |
| `health:apple` | iOS | HealthKit statistics (cumulative sum) per hour |
| `cloud:restore` | both | Read-only copy of your synced history, downloaded on a new device. It is never uploaded again. |

No source uses location. StrideMate never writes steps to Health Connect or Apple Health, so its own phone count is never read back in.

## Source-priority policy

Health Connect and HealthKit already de-duplicate *between apps*: Health Connect uses the user's app-priority list, and HealthKit uses its source ordering. StrideMate therefore reads their aggregate as one source. That leaves one possible overlap: the phone sensor and the health platform, which may contain the same walk.

Everything is stored per source and per UTC hour, then combined per hour:

| Policy | Rule for each hour |
|---|---|
| `auto` (default) | `max(phone, health)` |
| `prefer_phone` | phone if > 0, else health |
| `prefer_health` | health if > 0, else phone |

Sources are **never summed**. Per-hour comparison keeps the hours where only one device was in use, for example a watch on a run while the phone was on a desk, without double counting hours both devices saw. The same function runs:

- in Dart (`lib/domain/source_merge.dart`) for offline display, and
- in SQL (`recompute_effective`) for leaderboards and challenges.

The setting is synced, so both always agree.

## Edge cases

| Case | Handling |
|---|---|
| **Reboot** | The counter restarts at 0. A reboot is detected by `Settings.Global.BOOT_COUNT` changing, the counter going backwards, or the monotonic clock going backwards. Steps since boot are spread over [boot, now]. Before shutdown, `ACTION_SHUTDOWN` takes a final reading (best effort). Steps between the last sample and a sudden power loss can be lost; 15-minute background sampling keeps that window small. |
| **Sensor reset / glitch** | A jump larger than 250 steps per elapsed minute (+50) is capped. The server also clamps hours above 15,000 and flags the account. |
| **App closed for hours** | The delta is spread across the elapsed hours in proportion to time (up to 7 days back), so the total stays exact without spiking the current hour. |
| **Clock or time-zone change** | Durations use the monotonic clock, so changing the time cannot create or destroy steps. Buckets are UTC hours, so days are recomputed for the new zone; on the server, `profiles.time_zone` is updated on sign-in and app resume, and history is rebuilt. Group and challenge boards keep their own fixed zones. |
| **Duplicate events** | Each source's hour total is max-merged locally and on the server, so the same event received twice cannot add steps. |
| **Late uploads (wearables)** | Health data for the last 48 hours is re-read on every refresh. Uploads re-score boards; challenge results become final 48 hours after the end date. |
| **Retried sync** | Batches carry a UUID stored locally *before* sending. A retry after a lost response is recognised as a duplicate, and max-merge makes even a new batch id harmless. |
| **Permission revoked** | That source stops producing new data. Existing history is kept and still counts. The Today tab explains how to re-enable it. "Disconnect" in Step sources can also delete the imported history. |
| **Offline** | Everything is stored locally first. Uploads resume automatically when connectivity returns, with exponential back-off capped at 15 minutes. |

## When the OS delays updates

| Situation | Effect |
|---|---|
| **Android, normal** | WorkManager samples about every 15 minutes (the minimum). The optional *Live counting* foreground service keeps a notification and widget current. |
| **Android, Doze / battery saver / restricted standby bucket** | Sampling can be deferred for hours. The counter keeps counting, so totals catch up when the app or a job next runs, unless the phone reboots in between. |
| **Android, force-stop** | Android cancels all jobs and alarms until the user opens the app again. Boot/shutdown receivers also stop firing until then. |
| **Android, permission change** | If "Physical activity" is revoked, Android kills the process. On return the app shows the permission banner. |
| **iOS** | Core Motion records independently of the app, and opening StrideMate backfills up to 7 days. Widget refreshes are budgeted by iOS (roughly every 15–60 minutes). HealthKit background delivery is not used, so health data refreshes when the app opens. |
