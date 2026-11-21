import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../auth_service.dart';
import '../local_db.dart';
import '../remote/api.dart';
import '../settings_store.dart';
import '../step_repository.dart';
import 'sync_core.dart';

/// Runs SyncCore when signed in and online; restores history on a new device.
class SyncEngine extends ChangeNotifier {
  SyncEngine({required this.db, required this.api, required this.auth, required this.settings, required this.steps}) {
    _core = SyncCore(store: db, transport: api, newId: () => const Uuid().v4());
  }

  final LocalDb db;
  final Api api;
  final AuthService auth;
  final SettingsStore settings;
  final StepRepository steps;
  late final SyncCore _core;

  bool syncing = false;
  Object? lastError;
  int pending = 0;
  Timer? _timer;
  StreamSubscription<List<ConnectivityResult>>? _conn;
  StreamSubscription<void>? _stepSub;

  DateTime? get lastSync =>
      settings.lastSyncMs == null ? null : DateTime.fromMillisecondsSinceEpoch(settings.lastSyncMs!);

  void start() {
    _conn = Connectivity().onConnectivityChanged.listen((r) {
      if (r.any((c) => c != ConnectivityResult.none)) unawaited(syncNow());
    });
    _stepSub = steps.onRefreshed.listen((_) => unawaited(syncNow()));
    _timer = Timer.periodic(const Duration(minutes: 10), (_) => unawaited(syncNow()));
    auth.addListener(_onAuth);
    unawaited(syncNow());
  }

  void _onAuth() {
    if (auth.signedIn) {
      unawaited(syncNow());
    }
  }

  Future<void> syncNow() async {
    if (!auth.signedIn || syncing) return;
    syncing = true;
    notifyListeners();
    try {
      if (!settings.restoredFromCloud) await _restoreFromCloud();
      await _pushPreferences();
      final report = await _core.run();
      if (report.failures > 0) throw report.lastError ?? 'sync failed';
      await _pullPreferences();
      lastError = null;
      settings.lastSyncMs = DateTime.now().millisecondsSinceEpoch;
    } catch (e) {
      lastError = e;
    } finally {
      pending = await db.pendingUploadCount();
      syncing = false;
      notifyListeners();
    }
  }

  /// New device / reinstall: pull the effective hourly series as a read-only
  /// "cloud" source. Max-merge with local data means no double counting.
  Future<void> _restoreFromCloud() async {
    final now = DateTime.now().toUtc();
    var to = now.add(const Duration(hours: 1));
    for (var i = 0; i < 7; i++) {
      final from = to.subtract(const Duration(days: 60));
      final rows = await api.myHourly(from, to);
      if (rows.isNotEmpty) await db.importSyncedBuckets(rows);
      to = from;
    }
    final rest = await api.restDays();
    await db.replaceRestDays(rest);
    final goals = await api.goalHistory();
    if (goals.isNotEmpty) await db.replaceGoalHistory(goals);
    settings.restoredFromCloud = true;
    await steps.reloadFromDb();
  }

  Future<void> _pushPreferences() async {
    for (final r in await db.unsyncedRestDays()) {
      final day = r['day'] as String;
      try {
        await api.setRestDay(day, (r['deleted'] as int) == 0);
      } catch (e) {
        if (!friendlyError(e).contains('Rest Days')) rethrow; // rule violation: drop it
      }
      await db.markRestDaySynced(day);
    }
    for (final a in await db.unsyncedAchievements()) {
      await api.saveAchievement(a['key'] as String, a['unlocked_on'] as String);
      await db.markAchievementSynced(a['key'] as String);
    }
    final profile = auth.profile;
    if (profile != null) {
      final changes = <String, dynamic>{};
      if (profile['daily_goal'] != settings.dailyGoal) changes['daily_goal'] = settings.dailyGoal;
      final policy = switch (settings.sourcePolicy.name) {
        'preferPhone' => 'prefer_phone',
        'preferHealth' => 'prefer_health',
        _ => 'auto',
      };
      if (profile['source_policy'] != policy) changes['source_policy'] = policy;
      if (changes.isNotEmpty) await auth.updateProfile(changes);
    }
  }

  Future<void> _pullPreferences() async {
    final rest = await api.restDays();
    final local = await db.restDays();
    if (rest.difference(local).isNotEmpty) {
      await db.replaceRestDays(rest);
      await steps.reloadFromDb();
    }
  }

  /// Called after sign-out / account deletion.
  Future<void> resetForSignOut() async {
    await db.resetSyncState();
    settings.restoredFromCloud = false;
    settings.lastSyncMs = null;
    await steps.reloadFromDb();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _conn?.cancel();
    _stepSub?.cancel();
    auth.removeListener(_onAuth);
    super.dispose();
  }
}
