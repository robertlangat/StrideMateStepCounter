/// Monthly and yearly StrideMate Recaps.
library;

import 'day_key.dart';
import 'goals.dart';
import 'step_math.dart';

class Recap {
  const Recap({
    required this.title,
    required this.from,
    required this.to,
    required this.totalSteps,
    required this.activeDays,
    required this.goalDays,
    required this.dailyAverage,
    required this.bestDay,
    required this.bestDaySteps,
    required this.distanceKm,
    required this.longestStreak,
    required this.previousTotal,
  });

  final String title;
  final String from;
  final String to;
  final int totalSteps;
  final int activeDays;
  final int goalDays;
  final int dailyAverage;
  final String? bestDay;
  final int bestDaySteps;
  final double distanceKm;
  final int longestStreak;
  final int previousTotal;

  double? get changeVsPrevious => previousTotal <= 0 ? null : (totalSteps - previousTotal) / previousTotal;
}

const _months = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September',
  'October', 'November', 'December'];

Recap buildRecap({
  required Map<String, int> daily,
  required Set<String> restDays,
  required GoalHistory goals,
  required int strideCm,
  required int year,
  int? month, // null => yearly recap
  required String today,
}) {
  final from = month == null ? DateTime(year, 1, 1) : DateTime(year, month, 1);
  final toExclusive = month == null ? DateTime(year + 1, 1, 1) : DateTime(year, month + 1, 1);
  final prevFrom = month == null ? DateTime(year - 1, 1, 1) : DateTime(year, month - 1, 1);
  final todayDate = parseDayKey(today);
  final lastDay = toExclusive.isAfter(todayDate) ? todayDate : addDays(toExclusive, -1);

  var total = 0, active = 0, goalDays = 0, best = 0, prev = 0, run = 0, longest = 0;
  String? bestDay;
  var counted = 0;
  var d = from;
  while (!d.isAfter(lastDay)) {
    final key = dayKey(d);
    final s = daily[key] ?? 0;
    total += s;
    counted++;
    if (s > 0) active++;
    if (s >= goals.goalFor(key)) {
      goalDays++;
      run++;
      if (run > longest) longest = run;
    } else if (!restDays.contains(key)) {
      run = 0;
    }
    if (s > best) {
      best = s;
      bestDay = key;
    }
    d = nextDay(d);
  }
  var p = prevFrom;
  while (p.isBefore(from)) {
    prev += daily[dayKey(p)] ?? 0;
    p = nextDay(p);
  }
  return Recap(
    title: month == null ? '$year in steps' : '${_months[month - 1]} $year',
    from: dayKey(from),
    to: dayKey(lastDay),
    totalSteps: total,
    activeDays: active,
    goalDays: goalDays,
    dailyAverage: counted == 0 ? 0 : (total / counted).round(),
    bestDay: bestDay,
    bestDaySteps: best,
    distanceKm: distanceKm(total, strideCm),
    longestStreak: longest,
    previousTotal: prev,
  );
}
