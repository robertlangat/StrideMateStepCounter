# Wearable compatibility

StrideMate reads wearables **through the phone's health platform**: Health Connect on Android, Apple Health on iOS. There are no direct vendor integrations. Each brand's own app syncs into the platform, and StrideMate reads the platform's de-duplicated step total. A direct cloud API integration would need a partner agreement and credentials from each vendor (Fitbit/Google, Garmin Health API, Oura API, WHOOP API, Withings API). None were available, so none were added.

**Status legend**

- **Documented path**: the vendor's companion app publicly documents writing steps to the platform. The paths below were checked against vendor support pages and recent reporting in **November 2026**.
- **Needs device test**: not yet confirmed with real hardware for StrideMate. Do this before claiming support in store listings.

| Brand | Android → Health Connect | iOS → Apple Health | Companion app required | Notes |
|---|---|---|---|---|
| **Fitbit / Pixel Watch** | Documented. Google Health app (the Fitbit app was renamed in May 2026) › Connections › Partner apps › Health Connect | Documented since Google Health app **5.05** (Aug 2026): Profile › Partner apps › Apple Health. Earlier versions only *read* from Apple Health. | Google Health app | Health Connect writes can lag hours behind the device sync. |
| **Garmin** | Documented. Garmin Connect › Settings › Health Connect; **Android 14+ only**; one-way (Garmin → Health Connect) | Documented. Garmin Connect › Settings › Connected Apps › Apple Health | Garmin Connect | Users report occasional missing step writes in Health Connect after midnight syncs. StrideMate re-reads the last 48 h to pick up corrections. |
| **Samsung Galaxy Watch / Samsung Health** | Documented. Samsung Health › Settings › Health Connect › allow Steps | Not available (Samsung Health is Android-only) | Samsung Health | If Samsung Health also counts phone steps, Health Connect's priority list decides which source wins. |
| **Oura** | Documented. Oura app › Settings › Data sharing › Health Connect | Documented. Oura app › Settings › Data sharing › Apple Health | Oura app | Oura notes that some data-sharing features need a Gen3 ring or later with an active membership. |
| **WHOOP** | Documented. WHOOP app › More › Integrations › Health Connect | Documented. WHOOP app › More › Integrations › Apple Health | WHOOP app | Community reports of steps not reaching Health Connect on some phones: **needs device test**. |
| **Withings** | Documented. Withings app › Apps › Health Connect | Documented. Withings app › Profile › Settings › Export to Apple Health | Withings app | ⚠️ Since **13 Oct 2026**, *new* Withings accounts need a paid **Withings+** subscription to export data to Health Connect or Apple Health. Older accounts are unaffected. |
| **Xiaomi Mi Band / Smart Band** | Documented. Mi Fitness › Profile › Third-party data › Health Connect | Documented. Mi Fitness › Apple Health | Mi Fitness (not Zepp Life, for current bands) | Older bands paired with Zepp Life use a different path. |
| **Amazfit (Zepp)** | Documented. Zepp › Profile › Add accounts › Health Connect | Documented. Zepp › Profile › Add accounts › Apple Health | Zepp | Pre-2023 models on legacy Zepp versions may lack the Health Connect option. |

Every row is **Needs device test** for StrideMate itself. Nothing here was run on real hardware.

## How StrideMate avoids double counting with wearables

Health Connect and Apple Health already merge overlapping apps using the user's priority order, and StrideMate reads their aggregate. Overlap between that aggregate and the phone's own sensor is handled hour by hour (see `STEP_SOURCES.md`). The Step sources screen lists which apps contributed steps in the last 7 days, to help users diagnose this.

## Device test checklist (per brand)

1. Pair the wearable with its companion app and enable Health Connect / Apple Health sharing for **Steps**.
2. In StrideMate › Profile › Step sources, connect Health Connect / Apple Health.
3. Walk about 500 steps with the phone in a pocket. Confirm the Today total rises by about 500, not 1,000.
4. Walk about 500 steps with the phone left behind. Confirm the wearable steps appear once the companion app syncs.
5. Sync the wearable the next morning. Confirm yesterday's total updates (late upload) and that group "Yesterday" boards change.
6. Revoke the permission in Health Connect. Confirm the banner appears and history is kept.
