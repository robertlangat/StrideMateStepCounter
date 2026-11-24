import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../domain/source_merge.dart';
import '../domain/step_math.dart';

/// Device-level preferences (everything works without an account).
class SettingsStore extends ChangeNotifier {
  SettingsStore._(this._p);
  final SharedPreferences _p;

  static Future<SettingsStore> load() async => SettingsStore._(await SharedPreferences.getInstance());

  bool get onboarded => _p.getBool('onboarded') ?? false;
  set onboarded(bool v) => _set('onboarded', v);

  int get dailyGoal => _p.getInt('daily_goal') ?? 8000;
  set dailyGoal(int v) => _set('daily_goal', v);

  int get strideCm => _p.getInt('stride_cm') ?? defaultStrideCm;
  set strideCm(int v) => _set('stride_cm', v);

  double get weightKg => _p.getDouble('weight_kg') ?? defaultWeightKg;
  set weightKg(double v) => _set('weight_kg', v);

  bool get imperial => _p.getBool('imperial') ?? false;
  set imperial(bool v) => _set('imperial', v);

  ThemeMode get themeMode => ThemeMode.values[_p.getInt('theme_mode') ?? 0];
  set themeMode(ThemeMode v) => _set('theme_mode', v.index);

  SourcePolicy get sourcePolicy => sourcePolicyFromName(_p.getString('source_policy'));
  set sourcePolicy(SourcePolicy v) => _set('source_policy', sourcePolicyName(v));

  bool get healthEnabled => _p.getBool('health_enabled') ?? false;
  set healthEnabled(bool v) => _set('health_enabled', v);

  bool get liveCounting => _p.getBool('live_counting') ?? false;
  set liveCounting(bool v) => _set('live_counting', v);

  bool get showBots => _p.getBool('show_bots') ?? true;
  set showBots(bool v) => _set('show_bots', v);

  Set<String> get enabledBots => (_p.getStringList('enabled_bots') ?? ['chill', 'active', 'yesterday']).toSet();
  set enabledBots(Set<String> v) => _set('enabled_bots', v.toList());

  int? get lastSyncMs => _p.getInt('last_sync_ms');
  set lastSyncMs(int? v) => v == null ? _remove('last_sync_ms') : _set('last_sync_ms', v);

  int? get lastHealthFetchMs => _p.getInt('last_health_fetch_ms');
  set lastHealthFetchMs(int? v) => v == null ? _remove('last_health_fetch_ms') : _set('last_health_fetch_ms', v);

  int get trackingSinceMs => _p.getInt('tracking_since_ms') ?? DateTime.now().millisecondsSinceEpoch;
  void ensureTrackingSince() {
    if (!_p.containsKey('tracking_since_ms')) _set('tracking_since_ms', DateTime.now().millisecondsSinceEpoch);
  }

  bool get restoredFromCloud => _p.getBool('restored_from_cloud') ?? false;
  set restoredFromCloud(bool v) => _set('restored_from_cloud', v);

  String get deviceId {
    var id = _p.getString('device_id');
    if (id == null) {
      id = const Uuid().v4();
      _p.setString('device_id', id);
    }
    return id;
  }

  void _set(String k, Object v) {
    if (v is bool) _p.setBool(k, v);
    if (v is int) _p.setInt(k, v);
    if (v is double) _p.setDouble(k, v);
    if (v is String) _p.setString(k, v);
    if (v is List<String>) _p.setStringList(k, v);
    notifyListeners();
  }

  void _remove(String k) {
    _p.remove(k);
    notifyListeners();
  }
}
