import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/app_config.dart';
import 'remote/api.dart';

/// Optional account (email one-time code). Needed only for cloud sync and social
/// features; step counting works without it.
class AuthService extends ChangeNotifier {
  AuthService(this.api) {
    if (api != null) {
      _sub = api!.client.auth.onAuthStateChange.listen((s) {
        if (s.event == AuthChangeEvent.signedIn) _loadProfile();
        if (s.event == AuthChangeEvent.signedOut) profile = null;
        notifyListeners();
      });
      if (signedIn) _loadProfile();
    }
  }

  final Api? api;
  StreamSubscription<AuthState>? _sub;
  Map<String, dynamic>? profile;

  bool get available => api != null && AppConfig.backendConfigured;
  bool get signedIn => api?.client.auth.currentUser != null;
  String? get email => api?.client.auth.currentUser?.email;
  String? get userId => api?.client.auth.currentUser?.id;
  String get displayName => (profile?['display_name'] as String?) ?? 'You';

  Future<void> sendCode(String email) =>
      api!.client.auth.signInWithOtp(email: email.trim(), shouldCreateUser: true);

  Future<void> verifyCode(String email, String code) async {
    await api!.client.auth.verifyOTP(type: OtpType.email, email: email.trim(), token: code.trim());
    await _syncTimeZone();
    await _loadProfile();
  }

  Future<void> signOut() async {
    await api!.client.auth.signOut();
    profile = null;
    notifyListeners();
  }

  Future<void> _loadProfile() async {
    try {
      profile = await api!.myProfile();
      notifyListeners();
    } catch (_) {/* offline: keep cached */}
  }

  Future<void> reloadProfile() => _loadProfile();

  Future<void> updateProfile(Map<String, dynamic> fields) async {
    await api!.updateProfile(fields);
    await _loadProfile();
  }

  /// Keep the server's notion of "my day" aligned with the device (travel, DST).
  Future<void> _syncTimeZone() async {
    try {
      final tz = await FlutterTimezone.getLocalTimezone();
      final current = (await api!.myProfile())?['time_zone'];
      if (current != tz) await api!.updateProfile({'time_zone': tz});
    } catch (_) {}
  }

  Future<void> onResume() async {
    if (signedIn) await _syncTimeZone();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
