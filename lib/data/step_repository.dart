import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/day_key.dart';
import '../domain/goals.dart';
import '../domain/source_merge.dart';
import 'local_db.dart';
import 'settings_store.dart';
import 'sources/health_source.dart';
import 'sources/phone_source.dart';
import 'widget_bridge.dart';

/// Collects steps from every enabled source into the local store and exposes
/// de-duplicated totals to the UI. Works fully offline and without an account.
class StepRepository extends ChangeNotifier {
  StepRepository({required this.db, required this.settings, required this.phone, required this.health});

  final LocalDb db;
  final SettingsStore settings;
  final PhoneStepSource phone;
  final HealthStepSource health;

  PhoneSensorState phoneState = PhoneSensorState.unavailable;
  HealthState healthState = HealthState.notConnected;
  int todaySteps = 0;
  DateTime? lastUpdated;
  bool refreshing = false;
  Object? lastError;
  Map<int, int> _recentEffective = {};
  Map<String, int> _dailyCache = {};
  Set<String> restDays = {};
  Map<String, int> goalChanges = {};
  final _refreshed = StreamController<void>.broadcast();
  Stream<void> get onRefreshed => _refreshed.stream;

  Map<int, int> get recentEffectiveHourly => _recentEffective;
  GoalHistory get goals => GoalHistory(goalChanges, fallback: settings.dailyGoal);
  String get today => dayKey(DateTime.now());

  Future<void> init() async {
    // Called from a widget's initState: let the first frame finish before any
    // listener is notified (notifying during build is an error).
    await Future<void>.delayed(Duration.zero);
    settings.ensureTrackingSince();
    restDays = await db.restDays();
    goalChanges = await db.goalHistory();
    if (goalChanges.isEmpty) {
      await db.setGoalFrom(today, settings.dailyGoal);
      goalChanges = await db.goalHistory();
    }
    try {
      await phone.scheduleBackgroundSampling();
      await phone.setDailyGoal(settings.dailyGoal);
      if (settings.liveCounting) await phone.setLiveCounting(true);
    } catch (_) {}
    await refresh();
  }

  Future<void> refreshSourceStates() async {
    try {
      phoneState = await phone.state();
    } catch (_) {
      phoneState = PhoneSensorState.unavailable;
    }
    try {
      healthState = await health.state(userEnabled: settings.healthEnabled);
    } catch (_) {
      healthState = HealthState.unsupported;
    }
    notifyListeners();
  }

  Future<void> refresh() async {
    if (refreshing) return;
    refreshing = true;
    lastError = null;
    notifyListeners();
    final now = DateTime.now();
    try {
      await refreshSourceStates();
      var fetched = false;

      // Phone sensor / Core Motion: re-read the last week (hour totals can grow
      // after a long gap is spread out, and Core Motion keeps 7 days).
      if (phoneState == PhoneSensorState.ready) {
        final from = now.subtract(const Duration(days: 7));
        await db.upsertBuckets(await phone.fetch(from.toUtc(), now.toUtc().add(const Duration(hours: 1))));
        fetched = true;
      }

      // Health Connect / Apple Health: wearables can upload hours or days late,
      // so always re-read the last 48 h; backfill 30 days on first connection.
      if (settings.healthEnabled && healthState == HealthState.connected) {
        final last = settings.lastHealthFetchMs;
        final from = last == null
            ? startOfDay(now.subtract(const Duration(days: 30)))
            : DateTime.fromMillisecondsSinceEpoch(last).subtract(const Duration(hours: 48));
        await db.upsertBuckets(await health.fetch(from, now));
        settings.lastHealthFetchMs = now.millisecondsSinceEpoch;
        fetched = true;
      }

      if (fetched) lastUpdated = now;
      await _recompute(now);
      await _updateAchievements();
      await WidgetBridge.push(steps: todaySteps, goal: goals.goalFor(today), updated: lastUpdated ?? now);
    } catch (e) {
      lastError = e;
      await _recompute(now);
    } finally {
      refreshing = false;
      notifyListeners();
      _refreshed.add(null);
    }
  }

  Future<void> _recompute(DateTime now) async {
    final from = startOfDay(now.subtract(const Duration(days: 9)));
    final buckets = await db.bucketsBetween(from.toUtc(), now.toUtc().add(const Duration(hours: 2)));
    _recentEffective = mergeHourly(buckets, settings.sourcePolicy);
    todaySteps = stepsBetween(_recentEffective, startOfDay(now), nextDay(startOfDay(now)));
    _dailyCache = {};
    final latest = await db.latestUpdateMs();
    if (lastUpdated == null && latest != null) lastUpdated = DateTime.fromMillisecondsSinceEpoch(latest);
  }

  /// De-duplicated daily totals (device time zone) for an inclusive day range.
  Future<Map<String, int>> dailyTotalsBetween(DateTime fromDay, DateTime toDay) async {
    final start = startOfDay(fromDay);
    final end = nextDay(startOfDay(toDay));
    final buckets = await db.bucketsBetween(start.toUtc(), end.toUtc());
    final daily = dailyTotals(mergeHourly(buckets, settings.sourcePolicy));
    daily.removeWhere((k, _) => k.compareTo(dayKey(start)) < 0 || k.compareTo(dayKey(addDays(end, -1))) > 0);
    return daily;
  }

  Future<Map<int, int>> hourlyFor(DateTime day) async {
    final start = startOfDay(day);
    final buckets = await db.bucketsBetween(start.toUtc(), nextDay(start).toUtc());
    return mergeHourly(buckets, settings.sourcePolicy);
  }

  Future<Map<String, int>> allDailyTotals() async {
    if (_dailyCache.isNotEmpty) return _dailyCache;
    final earliest = await db.earliestHourMs();
    if (earliest == null) return {};
    _dailyCache = await dailyTotalsBetween(DateTime.fromMillisecondsSinceEpoch(earliest), DateTime.now());
    return _dailyCache;
  }

  StreakResult streak(Map<String, int> daily) =>
      computeStreak(daily: daily, restDays: restDays, goals: goals, today: today);

  Future<void> _updateAchievements() async {
    final daily = await allDailyTotals();
    if (daily.isEmpty) return;
    final earned = computeAchievements(daily: daily, restDays: restDays, goals: goals, strideCm: settings.strideCm);
    await db.saveAchievements(earned);
  }

  Future<void> setDailyGoal(int goal) async {
    settings.dailyGoal = goal;
    await db.setGoalFrom(today, goal);
    goalChanges = await db.goalHistory();
    try {
      await phone.setDailyGoal(goal);
    } catch (_) {}
    notifyListeners();
    await WidgetBridge.push(steps: todaySteps, goal: goal, updated: lastUpdated ?? DateTime.now());
  }

  /// Local rule check mirrors the server (today or future, max 2 per ISO week).
  String? canSetRestDay(String day) {
    if (day.compareTo(today) < 0) return 'Rest Days can only be set for today or later.';
    final week = startOfWeek(parseDayKey(day));
    final inWeek = restDays.where((d) => d != day && startOfWeek(parseDayKey(d)).isAtSameMomentAs(week)).length;
    if (inWeek >= 2) return 'You can schedule at most 2 Rest Days per week.';
    return null;
  }

  Future<void> setRestDay(String day, bool on) async {
    await db.setRestDay(day, on);
    restDays = await db.restDays();
    notifyListeners();
  }

  Future<void> reloadFromDb() async {
    restDays = await db.restDays();
    goalChanges = await db.goalHistory();
    await _recompute(DateTime.now());
    notifyListeners();
  }

  Future<void> setSourcePolicy(SourcePolicy p) async {
    settings.sourcePolicy = p;
    await _recompute(DateTime.now());
    notifyListeners();
  }

  Future<bool> connectHealth() async {
    final ok = await health.connect();
    settings.healthEnabled = ok;
    settings.lastHealthFetchMs = null;
    await refresh();
    return ok;
  }

  /// Stops reading the health platform. With [deleteData] the imported history
  /// is removed from this device (and stops being uploaded).
  Future<void> disconnectHealth({required bool deleteData}) async {
    settings.healthEnabled = false;
    await health.disconnect();
    if (deleteData) await db.deleteSource(health.sourceId);
    await refresh();
  }

  Future<void> setLiveCounting(bool on) async {
    settings.liveCounting = on;
    await phone.setLiveCounting(on);
    notifyListeners();
  }

  @override
  void dispose() {
    _refreshed.close();
    super.dispose();
  }
}
