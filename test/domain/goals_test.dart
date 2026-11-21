import 'package:flutter_test/flutter_test.dart';
import 'package:stridemate/domain/bots.dart';
import 'package:stridemate/domain/day_key.dart';
import 'package:stridemate/domain/goals.dart';
import 'package:stridemate/domain/recap.dart';
import 'package:stridemate/domain/step_math.dart';

void main() {
  final goals = GoalHistory({'2026-01-01': 8000});

  group('streaks and rest days', () {
    test('rest day keeps the streak without extending it', () {
      final daily = {'2026-11-12': 9000, '2026-11-13': 9000, '2026-11-14': 100, '2026-11-15': 9000};
      final r = computeStreak(daily: daily, restDays: {'2026-11-14'}, goals: goals, today: '2026-11-16');
      expect(r.current, 3);
    });

    test('today in progress does not break the streak; meeting it extends', () {
      final daily = {'2026-11-14': 9000, '2026-11-15': 9000, '2026-11-16': 3000};
      expect(computeStreak(daily: daily, restDays: {}, goals: goals, today: '2026-11-16').current, 2);
      daily['2026-11-16'] = 8000;
      final r = computeStreak(daily: daily, restDays: {}, goals: goals, today: '2026-11-16');
      expect(r.current, 3);
      expect(r.todayMet, isTrue);
    });

    test('a missed day (or a day with no data) ends the streak', () {
      final daily = {'2026-11-12': 9000, '2026-11-14': 9000, '2026-11-15': 9000};
      final r = computeStreak(daily: daily, restDays: {}, goals: goals, today: '2026-11-16');
      expect(r.current, 2);
      expect(r.longest, 2);
    });

    test('goal changes apply from their day forward only', () {
      final history = GoalHistory({'2026-11-01': 8000, '2026-11-15': 12000});
      expect(history.goalFor('2026-11-14'), 8000);
      expect(history.goalFor('2026-11-15'), 12000);
      final daily = {'2026-11-14': 9000, '2026-11-15': 9000};
      expect(computeStreak(daily: daily, restDays: {}, goals: history, today: '2026-11-16').current, 0);
    });
  });

  group('achievements and records', () {
    test('earned on the first qualifying day, deterministically', () {
      final daily = <String, int>{};
      var d = DateTime(2026, 10, 1);
      for (var i = 0; i < 31; i++) {
        daily[dayKey(d)] = i == 5 ? 21000 : 10500;
        d = nextDay(d);
      }
      final a = computeAchievements(daily: daily, restDays: {}, goals: goals, strideCm: 75);
      expect(a['first_goal'], '2026-10-01');
      expect(a['day_10k'], '2026-10-01');
      expect(a['day_20k'], '2026-10-06');
      expect(a['streak_7'], '2026-10-07');
      expect(a['streak_30'], '2026-10-30');
      expect(a.containsKey('lifetime_1m'), isFalse);
      expect(computeAchievements(daily: daily, restDays: {}, goals: goals, strideCm: 75), a);
    });

    test('records', () {
      final r = computeRecords({'2026-11-02': 5000, '2026-11-03': 15000, '2026-11-10': 7000});
      expect(r.bestDay, '2026-11-03');
      expect(r.bestWeekStart, '2026-11-02');
      expect(r.bestWeekSteps, 20000);
      expect(r.lifetimeSteps, 27000);
    });
  });

  group('walking bots', () {
    test('pace bots', () {
      expect(chillBotSteps(DateTime(2026, 11, 16, 6)), 0);
      expect(chillBotSteps(DateTime(2026, 11, 16, 14)), 3000);
      expect(chillBotSteps(DateTime(2026, 11, 16, 22)), 6000);
      expect(activeBotSteps(DateTime(2026, 11, 16, 21)), 12000);
    });

    test('Yesterday Bot uses the total at the same local time yesterday', () {
      final y9 = hourStartUtc(DateTime(2026, 11, 15, 9)).millisecondsSinceEpoch;
      final y10 = hourStartUtc(DateTime(2026, 11, 15, 10)).millisecondsSinceEpoch;
      final y20 = hourStartUtc(DateTime(2026, 11, 15, 20)).millisecondsSinceEpoch;
      final hourly = {y9: 1000, y10: 600, y20: 5000};
      final steps = yesterdayBotSteps(
        nowLocal: DateTime(2026, 11, 16, 10, 30),
        effectiveHourly: hourly,
        trackingSince: DateTime(2026, 11, 1),
      );
      expect(steps, 1300); // 1000 + half of the 10:00 hour; the evening is not counted yet
    });

    test('Yesterday Bot needs history', () {
      expect(
          yesterdayBotSteps(nowLocal: DateTime(2026, 11, 16, 10), effectiveHourly: {}, trackingSince: DateTime(2026, 11, 1)),
          isNull);
      expect(
          yesterdayBotSteps(
              nowLocal: DateTime(2026, 11, 16, 10),
              effectiveHourly: {hourStartUtc(DateTime(2026, 11, 15, 9)).millisecondsSinceEpoch: 10},
              trackingSince: DateTime(2026, 11, 15, 8)),
          isNull);
    });
  });

  test('distance and calories are estimates from stride and weight', () {
    expect(distanceKm(10000, 75), closeTo(7.5, 1e-9));
    expect(estimatedKcal(10000, 75, 70), closeTo(409.5, 0.1));
  });

  test('monthly recap', () {
    final daily = {'2026-10-01': 9000, '2026-10-02': 2000, '2026-10-31': 12000, '2026-09-15': 10000};
    final r = buildRecap(daily: daily, restDays: {}, goals: goals, strideCm: 75, year: 2026, month: 10, today: '2026-11-16');
    expect(r.title, 'October 2026');
    expect(r.totalSteps, 23000);
    expect(r.goalDays, 2);
    expect(r.bestDay, '2026-10-31');
    expect(r.previousTotal, 10000);
    expect(r.dailyAverage, (23000 / 31).round());
  });
}
