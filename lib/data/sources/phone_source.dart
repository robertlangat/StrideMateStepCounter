import 'dart:io';

import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../domain/source_merge.dart';

enum PhoneSensorState { ready, permissionNeeded, permissionPermanentlyDenied, unavailable, unsupportedPlatform }

/// The phone's own step counter.
///  * Android: hardware TYPE_STEP_COUNTER via the native StepStore (counts while
///    the app is closed; sampled by WorkManager and on shutdown/boot).
///  * iOS: Core Motion CMPedometer (the motion coprocessor keeps 7 days of history).
/// Neither requests location.
class PhoneStepSource {
  static const _android = MethodChannel('stridemate/steps');
  static const _ios = MethodChannel('stridemate/motion');

  String get sourceId => Platform.isIOS ? 'phone:ios' : 'phone:android';

  Future<PhoneSensorState> state() async {
    if (!(Platform.isAndroid || Platform.isIOS)) return PhoneSensorState.unsupportedPlatform;
    final available = Platform.isAndroid
        ? (await _android.invokeMethod<bool>('isStepCounterAvailable') ?? false)
        : (await _ios.invokeMethod<bool>('isAvailable') ?? false);
    if (!available) return PhoneSensorState.unavailable;
    final perm = Platform.isAndroid ? Permission.activityRecognition : Permission.sensors;
    final status = await perm.status;
    if (status.isGranted || status.isLimited) return PhoneSensorState.ready;
    if (status.isPermanentlyDenied || status.isRestricted) return PhoneSensorState.permissionPermanentlyDenied;
    return PhoneSensorState.permissionNeeded;
  }

  /// Ask for motion permission. Call only from a user action that needs it.
  Future<PhoneSensorState> requestPermission() async {
    if (Platform.isAndroid) {
      await Permission.activityRecognition.request();
    } else if (Platform.isIOS) {
      // The first CMPedometer query triggers the iOS Motion & Fitness prompt.
      await _ios.invokeMethod('requestAuthorization');
    }
    return state();
  }

  Future<List<SourceBucket>> fetch(DateTime fromUtc, DateTime toUtc) async {
    if (await state() != PhoneSensorState.ready) return const [];
    final List<dynamic>? rows;
    if (Platform.isAndroid) {
      await _android.invokeMethod('sampleNow');
      rows = await _android.invokeMethod<List<dynamic>>('getHourly', {
        'fromMs': fromUtc.millisecondsSinceEpoch,
        'toMs': toUtc.millisecondsSinceEpoch,
      });
    } else {
      rows = await _ios.invokeMethod<List<dynamic>>('queryHourly', {
        'fromMs': fromUtc.millisecondsSinceEpoch,
        'toMs': toUtc.millisecondsSinceEpoch,
      });
    }
    return (rows ?? const [])
        .cast<Map<dynamic, dynamic>>()
        .map((r) => SourceBucket(
              sourceId: sourceId,
              kind: SourceKind.phone,
              hourUtc: DateTime.fromMillisecondsSinceEpoch((r['hour_ms'] as num).toInt(), isUtc: true),
              steps: (r['steps'] as num).toInt(),
            ))
        .where((b) => b.steps > 0)
        .toList();
  }

  Future<Map<String, dynamic>> diagnostics() async {
    if (!Platform.isAndroid) return {'platform': Platform.operatingSystem};
    final d = await _android.invokeMethod<Map<dynamic, dynamic>>('diagnostics');
    return (d ?? {}).map((k, v) => MapEntry(k.toString(), v));
  }

  Future<void> scheduleBackgroundSampling() async {
    if (Platform.isAndroid) await _android.invokeMethod('scheduleSampling');
  }

  Future<void> setLiveCounting(bool on) async {
    if (Platform.isAndroid) await _android.invokeMethod('setLiveCounting', {'enabled': on});
  }

  Future<void> setDailyGoal(int goal) async {
    if (Platform.isAndroid) await _android.invokeMethod('setDailyGoal', {'goal': goal});
  }

  Future<String?> initialLink() async {
    if (!Platform.isAndroid) return _ios.invokeMethod<String>('getInitialLink');
    return _android.invokeMethod<String>('getInitialLink');
  }

  void onLink(void Function(String link) handler) {
    Future<dynamic> h(MethodCall call) async {
      if (call.method == 'onLink' && call.arguments is String) handler(call.arguments as String);
    }
    if (Platform.isAndroid) {
      _android.setMethodCallHandler(h);
    } else if (Platform.isIOS) {
      _ios.setMethodCallHandler(h);
    }
  }
}
