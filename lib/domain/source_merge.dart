/// Source-priority policy that prevents double counting.
///
/// Every source reports *cumulative steps per UTC hour*. Phones and wearables
/// often see the same walk, so totals are never summed across sources:
///
///  * auto (default): per hour, take the MAX across sources. Hours where only the
///    watch was worn, or only the phone was carried, still count; overlapping hours
///    count once.
///  * preferPhone: use phone-sensor hours that have steps, else the max of the rest.
///  * preferHealth: use Health Connect / Apple Health hours that have steps, else phone.
///
/// Health Connect and Apple Health already de-duplicate *between* apps using the
/// user's data-source priority, so StrideMate reads their aggregate total as one
/// source. The same policy runs on the server (recompute_effective) so the app,
/// leaderboards and challenges always agree.
library;

import 'day_key.dart';

enum SourceKind { phone, health }

enum SourcePolicy { auto, preferPhone, preferHealth }

SourcePolicy sourcePolicyFromName(String? name) => switch (name) {
      'prefer_phone' => SourcePolicy.preferPhone,
      'prefer_health' => SourcePolicy.preferHealth,
      _ => SourcePolicy.auto,
    };

String sourcePolicyName(SourcePolicy p) => switch (p) {
      SourcePolicy.auto => 'auto',
      SourcePolicy.preferPhone => 'prefer_phone',
      SourcePolicy.preferHealth => 'prefer_health',
    };

class SourceBucket {
  const SourceBucket({required this.sourceId, required this.kind, required this.hourUtc, required this.steps});

  final String sourceId;
  final SourceKind kind;
  final DateTime hourUtc;
  final int steps;

  int get hourMsUtc => hourUtc.millisecondsSinceEpoch;
}

/// Effective steps per UTC hour (key = epoch ms of the hour start).
Map<int, int> mergeHourly(Iterable<SourceBucket> buckets, SourcePolicy policy) {
  final phoneMax = <int, int>{};
  final healthMax = <int, int>{};
  for (final b in buckets) {
    if (b.steps <= 0) continue;
    final target = b.kind == SourceKind.phone ? phoneMax : healthMax;
    final h = b.hourMsUtc;
    final current = target[h];
    if (current == null || b.steps > current) target[h] = b.steps;
  }
  final hours = {...phoneMax.keys, ...healthMax.keys};
  final out = <int, int>{};
  for (final h in hours) {
    final p = phoneMax[h] ?? 0;
    final w = healthMax[h] ?? 0;
    out[h] = switch (policy) {
      SourcePolicy.auto => p > w ? p : w,
      SourcePolicy.preferPhone => p > 0 ? p : w,
      SourcePolicy.preferHealth => w > 0 ? w : p,
    };
  }
  return out;
}

/// Sum effective hours into local calendar days (device time zone).
Map<String, int> dailyTotals(Map<int, int> effectiveHourly) {
  final out = <String, int>{};
  effectiveHourly.forEach((hourMs, steps) {
    final key = dayKey(DateTime.fromMillisecondsSinceEpoch(hourMs, isUtc: true).toLocal());
    out[key] = (out[key] ?? 0) + steps;
  });
  return out;
}

/// Effective steps recorded in [startLocal, endLocal).
int stepsBetween(Map<int, int> effectiveHourly, DateTime startLocal, DateTime endLocal) {
  final from = startLocal.toUtc().millisecondsSinceEpoch;
  final to = endLocal.toUtc().millisecondsSinceEpoch;
  var sum = 0;
  effectiveHourly.forEach((h, s) {
    if (h >= from && h < to) sum += s;
  });
  return sum;
}
