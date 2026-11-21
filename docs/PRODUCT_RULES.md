# StrideMate product rules

These rules are implemented once on the server (SQL in `supabase/migrations`) and, where the app also needs them offline, mirrored in pure Dart (`lib/domain`). Both implementations have tests.

## Steps and days

- Steps are stored as **per-source cumulative totals per UTC hour**. A local day is the sum of the hours that start inside it, in the relevant time zone:
  - your own zone for History and Today,
  - the **group's** zone for group leaderboards,
  - the **challenge's** fixed zone for challenge scoring,
  - each person's own zone for country/global boards.
- In half-hour zones such as India (+05:30), an hour bucket is attributed to the day in which it *starts*. At most 30 minutes of steps can land on the neighbouring day.
- **Distance** is steps × stride length (configurable, default 75 cm). **Calories** are labelled as estimates: 0.78 kcal per kg per km walked.

## Overlapping sources (no double counting)

See [STEP_SOURCES.md](STEP_SOURCES.md). In short, sources are compared hour by hour and never added together.

## Goals, Rest Days, streaks

| Rule | Detail |
|---|---|
| Goal history | Changing your goal applies from today forward. Past days keep their goal. |
| Met day | steps ≥ that day's goal |
| Rest Days | Today or a future day only, at most 2 per Monday–Sunday week (enforced on the server). They protect a streak but don't extend it. |
| Today | Never breaks a streak while in progress. It counts once you meet the goal. |
| Missed | Any other day below goal, including days with no data, ends the streak. |
| Achievements | Derived deterministically from synced daily totals, so every device computes the same result and date. |

## Groups

- Groups are private and joined only by invite. Invites are 10-character codes (no ambiguous characters) with an expiry of 1 hour to 30 days and an optional use limit, and owners/admins can revoke them. Join attempts are rate-limited to 10 per 10 minutes, which also blocks code guessing.
- Roles:
  - **Owner** (exactly one): everything, plus promote/demote admins and transfer ownership.
  - **Admin**: invites, settings, moderation of members.
  - **Member**.
  - An admin cannot act on another admin.
- If the owner leaves or deletes their account, ownership passes to the longest-standing admin, otherwise the longest-standing member. The last member leaving deletes the group.
- Groups hold up to 15,000 members. Member lists and leaderboards are paginated (keyset, 50 per page).

## Leaderboards and ties

- Group boards: **today**, **yesterday** (provisional for late uploads), **this week** (Monday start) and **this month**, all in the group's zone.
- **Competition ranking**: equal totals share a rank, and the next rank skips (1, 2, 2, 4). Tied rows are listed in a stable order (by user id). Pagination is keyset on (rank, user id).
- Your own row is always returned, even if you are rank 14,000.
- Rankings are **server-maintained**. `refresh_dirty_boards()` runs every minute through pg_cron and re-ranks only boards whose members uploaded. Every board is re-marked hourly so day rollovers apply even with no uploads. Reads never sort the whole group.

## Visibility (enforced on the server)

- **Keep my steps private** (profile): nobody else sees your totals anywhere.
- **Share my step totals here** (per group): when off, you are left out of that group's boards, challenge standings and CSV exports. Other groups are unaffected.
- Step tables are not readable by other users (RLS). Leaderboards and standings are served only through RPCs that apply these rules. Blocked users are hidden from your boards and chat.

## Challenges

- Created by owners/admins, with a start date and either an end date or no end (ongoing). Each challenge has a **fixed time zone**, shown to every participant. Everyone is scored on that zone's midnight.
- **Late uploads**: any upload re-scores the boards it affects. A dated challenge is **provisional** after its end date and **final** at *(end date + 1 day, 00:00 in its zone) + 48 h*. At that point standings and daily cells are snapshotted (`challenge_final_daily`). Later uploads still update personal history but never final results.

## Mystery Mode

While a challenge with Mystery Mode is active:

- Other participants see only **completed days** (before 00:00 today in the challenge zone). Today's totals, and any rank that would reveal them, stay hidden until the next day.
- You always see your own live total. Your rank is your position on the revealed board.
- To prevent cross-feature leaks, a Mystery participant's current day is hidden **everywhere**: group boards, other challenges, global boards, CSV exports and notifications. The cut-off is the earliest "start of today" across their active Mystery challenges.
- Realtime publishes only chat and your own notifications. Standings and daily totals are never published.
- Daily result notifications are generated from the revealed standings, after the day closes.

## CSV export

Owners/admins only, rate-limited to 30 per hour. Columns are `rank, participant, one column per day, total`.

- Participants who don't share steps with the group appear with `hidden` cells.
- Mystery Mode omits the current day until the challenge is final.
- A non-Mystery export labels the live day `(in progress)`.
- Names are CSV-escaped and neutralised against spreadsheet formula injection.
- Totals and ranks are re-scored at export time so they match the cells. Final challenges export the frozen snapshot.

## Country and global rankings

These are opt-in. You pick your country from a list; GPS is never used. Accounts flagged for implausible activity (more than 15,000 steps in an hour, or more than 150,000 in a day) are excluded until reviewed. Walking bots exist only on the device and never reach the server.

## Walking bots

| Bot | Behaviour |
|---|---|
| Chill Bot | 6,000 steps, evenly paced 07:00–21:00 |
| Active Bot | 12,000 steps, evenly paced 06:00–21:00 |
| Yesterday Bot | Your effective total from yesterday 00:00 to the same clock time yesterday, pro-rated within the current hour. It shows "not enough history" if tracking began after yesterday's midnight or nothing was recorded yesterday. |

## Rate limits (per user)

| Action | Limit |
|---|---|
| Step uploads | 240/hour |
| Messages | 20/minute and 300/hour |
| Invites | 30/hour |
| Joins | 10 per 10 minutes |
| Reports | 20/hour |
| Group creation | 10/day |
| Challenge creation | 20/day |
| CSV exports | 30/hour |
| Personal data exports | 10/day |
