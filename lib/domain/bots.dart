/// Walking bots: clearly labelled virtual competitors for personal challenges.
/// They run only on the device and are never uploaded or shown in human rankings.
library;

import 'day_key.dart';

enum BotKind { chill, active, yesterday }

class BotInfo {
  const BotInfo(this.kind, this.name, this.description, this.emoji);
  final BotKind kind;
  final String name;
  final String description;
  final String emoji;
}

const bots = <BotInfo>[
  BotInfo(BotKind.chill, 'Chill Bot', 'Strolls to 6,000 steps between 7:00 and 21:00.', '🐢'),
  BotInfo(BotKind.active, 'Active Bot', 'Power-walks to 12,000 steps between 6:00 and 21:00.', '⚡'),
  BotInfo(BotKind.yesterday, 'Yesterday Bot', 'Your own total at this time yesterday.', '🕰️'),
];

/// Linear pace bot: [target] steps spread evenly between [startHour] and [endHour].
int paceBotSteps(DateTime nowLocal, {required int target, required int startHour, required int endHour}) {
  final dayStart = startOfDay(nowLocal);
  final start = DateTime(dayStart.year, dayStart.month, dayStart.day, startHour);
  final end = DateTime(dayStart.year, dayStart.month, dayStart.day, endHour);
  if (!nowLocal.isAfter(start)) return 0;
  if (!nowLocal.isBefore(end)) return target;
  final f = nowLocal.difference(start).inSeconds / end.difference(start).inSeconds;
  return (target * f).round();
}

int chillBotSteps(DateTime nowLocal) => paceBotSteps(nowLocal, target: 6000, startHour: 7, endHour: 21);
int activeBotSteps(DateTime nowLocal) => paceBotSteps(nowLocal, target: 12000, startHour: 6, endHour: 21);

/// Yesterday Bot: the user's effective steps from yesterday's local midnight up
/// to the same local clock time yesterday. Returns null when there is not enough
/// history (no data recorded during yesterday, or tracking began after
/// yesterday's start), so the UI can say so instead of showing a fake zero.
int? yesterdayBotSteps({
  required DateTime nowLocal,
  required Map<int, int> effectiveHourly,
  required DateTime trackingSince,
}) {
  final todayStart = startOfDay(nowLocal);
  final yStart = addDays(todayStart, -1);
  if (trackingSince.isAfter(yStart)) return null;
  final sameTimeYesterday = DateTime(yStart.year, yStart.month, yStart.day, nowLocal.hour, nowLocal.minute, nowLocal.second);
  final yStartMs = yStart.toUtc().millisecondsSinceEpoch;
  final yEndMs = todayStart.toUtc().millisecondsSinceEpoch;
  final cutMs = sameTimeYesterday.toUtc().millisecondsSinceEpoch;
  var any = false;
  var sum = 0.0;
  effectiveHourly.forEach((h, steps) {
    if (h + hourMs <= yStartMs || h >= yEndMs) return;
    any = true;
    if (h + hourMs <= cutMs) {
      sum += steps;
    } else if (h < cutMs) {
      sum += steps * (cutMs - h) / hourMs; // partial current hour, pro-rated
    }
  });
  if (!any) return null;
  return sum.round();
}
