import 'dart:io';

import 'package:health/health.dart';

import '../../domain/day_key.dart';
import '../../domain/source_merge.dart';

enum HealthState { connected, notConnected, notInstalled, updateRequired, unsupported }

/// Health Connect (Android) / Apple Health (iOS) as ONE source.
///
/// We read the platform's aggregated step total per hour. Both platforms
/// de-duplicate across contributing apps (Health Connect by the user's app
/// priority list, HealthKit by source priority), so watches and rings that sync
/// into them (Fitbit, Garmin, Samsung Health, Oura, WHOOP, Withings, Mi Band /
/// Zepp, Amazfit …) are covered without double counting. StrideMate never writes
/// steps back, so its own phone count is not re-imported.
class HealthStepSource {
  HealthStepSource() : _health = Health();
  final Health _health;
  bool _configured = false;

  String get sourceId => Platform.isIOS ? 'health:apple' : 'health:connect';
  static const _types = [HealthDataType.STEPS];

  Future<void> _configure() async {
    if (_configured) return;
    await _health.configure();
    _configured = true;
  }

  Future<HealthState> state({required bool userEnabled}) async {
    if (!(Platform.isAndroid || Platform.isIOS)) return HealthState.unsupported;
    await _configure();
    if (Platform.isAndroid) {
      final status = await _health.getHealthConnectSdkStatus();
      if (status == HealthConnectSdkStatus.sdkUnavailable) return HealthState.notInstalled;
      if (status == HealthConnectSdkStatus.sdkUnavailableProviderUpdateRequired) return HealthState.updateRequired;
    }
    if (!userEnabled) return HealthState.notConnected;
    // iOS never reveals whether *read* access was granted (privacy); hasPermissions
    // returns null there, so we treat "user enabled + prompt shown" as connected.
    final has = await _health.hasPermissions(_types, permissions: [HealthDataAccess.READ]);
    if (has == false) return HealthState.notConnected;
    return HealthState.connected;
  }

  Future<void> installOrUpdateHealthConnect() async {
    if (Platform.isAndroid) await _health.installHealthConnect();
  }

  Future<bool> connect() async {
    await _configure();
    return _health.requestAuthorization(_types, permissions: [HealthDataAccess.READ]);
  }

  /// Revokes StrideMate's Health Connect permissions (Android). On iOS the user
  /// must turn access off in Settings › Health › Data Access; we stop reading.
  Future<void> disconnect() async {
    await _configure();
    if (Platform.isAndroid) {
      try {
        await _health.revokePermissions();
      } catch (_) {/* older Health Connect versions: user revokes in HC settings */}
    }
  }

  /// Hourly aggregated totals. Days without steps cost one query; active days 24.
  Future<List<SourceBucket>> fetch(DateTime fromLocal, DateTime toLocal) async {
    await _configure();
    final out = <SourceBucket>[];
    var day = startOfDay(fromLocal);
    while (day.isBefore(toLocal)) {
      final dayEnd = nextDay(day);
      final dayTotal = await _total(day, dayEnd.isBefore(toLocal) ? dayEnd : toLocal);
      if (dayTotal > 0) {
        var h = hourStartUtc(day).toLocal();
        while (h.isBefore(dayEnd) && h.isBefore(toLocal)) {
          final hEnd = h.add(const Duration(hours: 1));
          final s = await _total(h, hEnd);
          if (s > 0) {
            out.add(SourceBucket(sourceId: sourceId, kind: SourceKind.health, hourUtc: h.toUtc(), steps: s));
          }
          h = hEnd;
        }
      }
      day = dayEnd;
    }
    return out;
  }

  Future<int> _total(DateTime from, DateTime to) async {
    if (!to.isAfter(from)) return 0;
    final now = DateTime.now();
    final end = to.isAfter(now) ? now : to;
    if (!end.isAfter(from)) return 0;
    return await _health.getTotalStepsInInterval(from, end) ?? 0;
  }

  /// Names of apps/devices that wrote steps recently (diagnostics screen).
  Future<Map<String, int>> contributors(DateTime from, DateTime to) async {
    await _configure();
    final points = await _health.getHealthDataFromTypes(types: _types, startTime: from, endTime: to);
    final out = <String, int>{};
    for (final p in points) {
      final v = p.value;
      final n = v is NumericHealthValue ? v.numericValue.round() : 0;
      final name = p.sourceName.isEmpty ? p.sourceId : p.sourceName;
      out[name] = (out[name] ?? 0) + n;
    }
    return out;
  }
}
