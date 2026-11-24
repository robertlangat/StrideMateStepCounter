import 'package:flutter_test/flutter_test.dart';
import 'package:stridemate/domain/day_key.dart';
import 'package:stridemate/domain/source_merge.dart';

SourceBucket b(String src, SourceKind k, DateTime localHour, int steps) =>
    SourceBucket(sourceId: src, kind: k, hourUtc: hourStartUtc(localHour), steps: steps);

void main() {
  final day = DateTime(2026, 11, 16);
  final h9 = DateTime(2026, 11, 16, 9);
  final h10 = DateTime(2026, 11, 16, 10);

  group('source de-duplication', () {
    test('overlapping phone + wearable hour is counted once (auto = max)', () {
      final merged = mergeHourly([
        b('phone:android', SourceKind.phone, h9, 1000),
        b('health:connect', SourceKind.health, h9, 1200),
      ], SourcePolicy.auto);
      expect(merged.values.single, 1200);
    });

    test('non-overlapping hours from different sources both count', () {
      final merged = mergeHourly([
        b('phone:android', SourceKind.phone, h9, 800),
        b('health:connect', SourceKind.health, h10, 700),
      ], SourcePolicy.auto);
      expect(stepsBetween(merged, day, nextDay(day)), 1500);
    });

    test('preferences fall back when the preferred source has no steps', () {
      final buckets = [
        b('phone:android', SourceKind.phone, h9, 1000),
        b('health:connect', SourceKind.health, h9, 1200),
        b('health:connect', SourceKind.health, h10, 500),
      ];
      expect(stepsBetween(mergeHourly(buckets, SourcePolicy.preferPhone), day, nextDay(day)), 1500);
      expect(stepsBetween(mergeHourly(buckets, SourcePolicy.preferHealth), day, nextDay(day)), 1700);
    });

    test('duplicate events for the same source and hour never sum', () {
      final merged = mergeHourly([
        b('phone:android', SourceKind.phone, h9, 300),
        b('phone:android', SourceKind.phone, h9, 300),
        b('phone:android', SourceKind.phone, h9, 280),
      ], SourcePolicy.auto);
      expect(merged.values.single, 300);
    });

    test('policy names round-trip with the server values', () {
      for (final p in SourcePolicy.values) {
        expect(sourcePolicyFromName(sourcePolicyName(p)), p);
      }
      expect(sourcePolicyName(SourcePolicy.preferHealth), 'prefer_health');
    });
  });

  group('midnight rollover (device time zone)', () {
    test('23:00 and 00:00 local hours land on different days', () {
      final merged = mergeHourly([
        b('phone:android', SourceKind.phone, DateTime(2026, 11, 16, 23), 400),
        b('phone:android', SourceKind.phone, DateTime(2026, 11, 17, 0), 600),
      ], SourcePolicy.auto);
      final daily = dailyTotals(merged);
      expect(daily['2026-11-16'], 400);
      expect(daily['2026-11-17'], 600);
    });

    test('day keys and DST-safe day arithmetic', () {
      expect(dayKey(DateTime(2026, 3, 9)), '2026-03-09');
      expect(nextDay(DateTime(2026, 3, 8)), DateTime(2026, 3, 9));
      expect(dayKeysBetween(DateTime(2026, 12, 30), DateTime(2027, 1, 2)),
          ['2026-12-30', '2026-12-31', '2027-01-01', '2027-01-02']);
      expect(startOfWeek(DateTime(2026, 11, 22)), DateTime(2026, 11, 16)); // Sunday -> Monday
    });
  });
}
