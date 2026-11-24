import 'dart:math';

import '../data/local_db.dart';
import '../data/settings_store.dart';
import '../domain/day_key.dart';
import '../domain/source_merge.dart';

/// Sample walking history used ONLY for store screenshots
/// (`--dart-define=DEMO_DATA=true`). Never enabled in normal builds.
Future<void> seedDemoData(LocalDb db, SettingsStore settings) async {
  if (await db.earliestHourMs() != null) return;
  settings.onboarded = true;
  settings.dailyGoal = 8000;
  settings.strideCm = 75;
  settings.weightKg = 70;

  final rnd = Random(20261124);
  final now = DateTime.now();
  final today = startOfDay(now);
  // Share of a day's steps per local hour: commute, lunch walk, evening walk.
  const weights = <int, double>{
    6: 0.03, 7: 0.09, 8: 0.07, 9: 0.03, 10: 0.04, 11: 0.04, 12: 0.11, 13: 0.07, 14: 0.03,
    15: 0.04, 16: 0.05, 17: 0.12, 18: 0.13, 19: 0.07, 20: 0.05, 21: 0.03,
  };
  final buckets = <SourceBucket>[];
  void addDay(DateTime day, int total, {int? untilHour}) {
    final hours = weights.keys.where((h) => untilHour == null || h <= untilHour).toList();
    final sum = hours.fold<double>(0, (a, h) => a + weights[h]!);
    var assigned = 0;
    for (var i = 0; i < hours.length; i++) {
      final h = hours[i];
      final steps = i == hours.length - 1 ? total - assigned : (total * weights[h]! / sum).round();
      assigned += steps;
      buckets.add(SourceBucket(
        sourceId: 'phone:android',
        kind: SourceKind.phone,
        hourUtc: hourStartUtc(DateTime(day.year, day.month, day.day, h)),
        steps: steps,
      ));
    }
  }

  for (var d = 150; d >= 1; d--) {
    final day = addDays(today, -d);
    final weekend = day.weekday >= DateTime.saturday;
    var total = (weekend ? 10800 : 8900) + rnd.nextInt(4200) - 1500;
    if (d > 14 && d % 9 == 4) total = 3800 + rnd.nextInt(2500); // a few quieter days
    if (d == 23) total = 21450; // a personal best
    addDay(day, total);
  }
  final hourNow = now.hour.clamp(6, 21);
  addDay(today, 6840, untilHour: hourNow);

  await db.upsertBuckets(buckets);
  await db.setGoalFrom(dayKey(addDays(today, -150)), 8000);
  // One planned Rest Day later this week.
  await db.setRestDay(dayKey(addDays(today, 3)), true);
}
