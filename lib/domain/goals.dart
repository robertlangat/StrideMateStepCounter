/// Daily goals, Rest Days, streaks, personal records and achievements.
///
/// RULES (same on every device because they run on synced data):
///  * Goal history: changing your goal applies from that day forward; past days
///    keep the goal that was in force then.
///  * A day is MET when steps >= that day's goal.
///  * Rest Days are scheduled for today or a future day (max 2 per ISO week,
///    enforced on the server too). A rest day never breaks a streak and never
///    extends it. If you meet your goal on a rest day it simply counts as met.
///  * Today never breaks a streak while it is in progress: the current streak is
///    counted from yesterday backwards, plus today once it is met.
///  * Any other day below goal (including days with no data) ends the streak.
library;

import 'day_key.dart';

class GoalHistory {
  GoalHistory(Map<String, int> changes, {this.fallback = 8000})
      : _changes = (changes.entries.toList()..sort((a, b) => a.key.compareTo(b.key)));

  final List<MapEntry<String, int>> _changes;
  final int fallback;

  int goalFor(String day) {
    var goal = _changes.isEmpty ? fallback : _changes.first.value;
    for (final c in _changes) {
      if (c.key.compareTo(day) <= 0) {
        goal = c.value;
      } else {
        break;
      }
    }
    return goal;
  }
}

enum DayStatus { met, rest, missed, pending }

DayStatus statusFor(String day, String today, Map<String, int> daily, Set<String> restDays, GoalHistory goals) {
  final met = (daily[day] ?? 0) >= goals.goalFor(day);
  if (met) return DayStatus.met;
  if (restDays.contains(day)) return DayStatus.rest;
  if (day == today) return DayStatus.pending;
  return DayStatus.missed;
}

class StreakResult {
  const StreakResult({required this.current, required this.longest, required this.todayMet});
  final int current;
  final int longest;
  final bool todayMet;
}

StreakResult computeStreak({
  required Map<String, int> daily,
  required Set<String> restDays,
  required GoalHistory goals,
  required String today,
  String? firstDay,
}) {
  final todayDate = parseDayKey(today);
  final start = firstDay ?? (daily.keys.isEmpty ? today : (daily.keys.toList()..sort()).first);

  // current streak
  var current = 0;
  final todayStatus = statusFor(today, today, daily, restDays, goals);
  if (todayStatus == DayStatus.met) current = 1;
  var d = addDays(todayDate, -1);
  while (dayKey(d).compareTo(start) >= 0) {
    final s = statusFor(dayKey(d), today, daily, restDays, goals);
    if (s == DayStatus.met) {
      current++;
    } else if (s != DayStatus.rest) {
      break;
    }
    d = addDays(d, -1);
  }

  // longest streak
  var longest = 0;
  var run = 0;
  var cursor = parseDayKey(start);
  while (!cursor.isAfter(todayDate)) {
    final key = dayKey(cursor);
    final s = statusFor(key, today, daily, restDays, goals);
    if (s == DayStatus.met) {
      run++;
      if (run > longest) longest = run;
    } else if (s == DayStatus.missed) {
      run = 0;
    }
    cursor = nextDay(cursor);
  }
  if (current > longest) longest = current;
  return StreakResult(current: current, longest: longest, todayMet: todayStatus == DayStatus.met);
}

class PersonalRecords {
  const PersonalRecords({this.bestDay, this.bestDaySteps = 0, this.bestWeekStart, this.bestWeekSteps = 0,
      this.bestMonth, this.bestMonthSteps = 0, this.lifetimeSteps = 0});
  final String? bestDay;
  final int bestDaySteps;
  final String? bestWeekStart;
  final int bestWeekSteps;
  final String? bestMonth; // YYYY-MM
  final int bestMonthSteps;
  final int lifetimeSteps;
}

PersonalRecords computeRecords(Map<String, int> daily) {
  String? bestDay;
  var bestDaySteps = 0;
  final weeks = <String, int>{};
  final months = <String, int>{};
  var lifetime = 0;
  daily.forEach((day, steps) {
    lifetime += steps;
    if (steps > bestDaySteps) {
      bestDaySteps = steps;
      bestDay = day;
    }
    final w = dayKey(startOfWeek(parseDayKey(day)));
    weeks[w] = (weeks[w] ?? 0) + steps;
    final m = day.substring(0, 7);
    months[m] = (months[m] ?? 0) + steps;
  });
  MapEntry<String, int>? top(Map<String, int> m) =>
      m.entries.fold<MapEntry<String, int>?>(null, (best, e) => best == null || e.value > best.value ? e : best);
  final w = top(weeks);
  final mo = top(months);
  return PersonalRecords(
    bestDay: bestDay,
    bestDaySteps: bestDaySteps,
    bestWeekStart: w?.key,
    bestWeekSteps: w?.value ?? 0,
    bestMonth: mo?.key,
    bestMonthSteps: mo?.value ?? 0,
    lifetimeSteps: lifetime,
  );
}

class Achievement {
  const Achievement(this.key, this.title, this.description, this.icon);
  final String key;
  final String title;
  final String description;
  final String icon;
}

const achievements = <Achievement>[
  Achievement('first_goal', 'First goal', 'Meet your daily goal for the first time.', '🎯'),
  Achievement('day_10k', 'Ten thousand', 'Walk 10,000 steps in one day.', '🔟'),
  Achievement('day_20k', 'Twenty thousand', 'Walk 20,000 steps in one day.', '🚀'),
  Achievement('marathon_day', 'Marathon day', 'Cover 42.2 km of walking in one day (by stride estimate).', '🏅'),
  Achievement('streak_7', 'Week streak', 'Meet your goal 7 days in a row.', '🔥'),
  Achievement('streak_30', 'Month streak', 'Meet your goal 30 days in a row.', '🌟'),
  Achievement('week_70k', 'Big week', 'Walk 70,000 steps in one Monday–Sunday week.', '📅'),
  Achievement('lifetime_1m', 'Millionaire', 'Walk 1,000,000 steps in total.', '💎'),
];

/// Returns achievement key -> first day it was earned. Deterministic for the
/// same data, so every device derives the same result.
Map<String, String> computeAchievements({
  required Map<String, int> daily,
  required Set<String> restDays,
  required GoalHistory goals,
  required int strideCm,
}) {
  final out = <String, String>{};
  final days = daily.keys.toList()..sort();
  var lifetime = 0;
  var run = 0;
  final weekSums = <String, int>{};
  void earn(String key, String day) => out.putIfAbsent(key, () => day);
  for (final day in days) {
    final steps = daily[day] ?? 0;
    lifetime += steps;
    final met = steps >= goals.goalFor(day);
    if (met) earn('first_goal', day);
    if (steps >= 10000) earn('day_10k', day);
    if (steps >= 20000) earn('day_20k', day);
    if (steps * strideCm / 100000.0 >= 42.195) earn('marathon_day', day);
    if (lifetime >= 1000000) earn('lifetime_1m', day);
    final w = dayKey(startOfWeek(parseDayKey(day)));
    weekSums[w] = (weekSums[w] ?? 0) + steps;
    if (weekSums[w]! >= 70000) earn('week_70k', day);
  }
  // Streak achievements walk every calendar day (gaps are missed days).
  if (days.isNotEmpty) {
    var cursor = parseDayKey(days.first);
    final end = parseDayKey(days.last);
    while (!cursor.isAfter(end)) {
      final key = dayKey(cursor);
      final steps = daily[key] ?? 0;
      if (steps >= goals.goalFor(key)) {
        run++;
        if (run >= 7) earn('streak_7', key);
        if (run >= 30) earn('streak_30', key);
      } else if (!restDays.contains(key)) {
        run = 0;
      }
      cursor = nextDay(cursor);
    }
  }
  return out;
}
