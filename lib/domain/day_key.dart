/// Calendar helpers. A "day key" is the local calendar date `YYYY-MM-DD`.
/// Hour buckets are stored by UTC hour start, so any whole-hour time zone's
/// day boundary falls exactly on a bucket boundary.
library;

const int hourMs = 3600000;

String dayKey(DateTime local) {
  final d = local.isUtc ? local.toLocal() : local;
  return '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

DateTime parseDayKey(String key) {
  final p = key.split('-');
  return DateTime(int.parse(p[0]), int.parse(p[1]), int.parse(p[2]));
}

/// Start of the local day containing [t] (DST-safe: built from Y/M/D).
DateTime startOfDay(DateTime t) => DateTime(t.year, t.month, t.day);

/// Start of the following local day (DST-safe, unlike adding 24 hours).
DateTime nextDay(DateTime dayStart) => DateTime(dayStart.year, dayStart.month, dayStart.day + 1);

DateTime addDays(DateTime dayStart, int days) => DateTime(dayStart.year, dayStart.month, dayStart.day + days);

/// UTC hour start for any instant.
DateTime hourStartUtc(DateTime t) {
  final ms = t.toUtc().millisecondsSinceEpoch;
  return DateTime.fromMillisecondsSinceEpoch(ms - (ms % hourMs), isUtc: true);
}

/// ISO week (Monday) start for a local day.
DateTime startOfWeek(DateTime day) => addDays(startOfDay(day), -(day.weekday - DateTime.monday));

DateTime startOfMonth(DateTime day) => DateTime(day.year, day.month, 1);

List<String> dayKeysBetween(DateTime fromDay, DateTime toDayInclusive) {
  final out = <String>[];
  var d = startOfDay(fromDay);
  final end = startOfDay(toDayInclusive);
  while (!d.isAfter(end)) {
    out.add(dayKey(d));
    d = nextDay(d);
  }
  return out;
}
