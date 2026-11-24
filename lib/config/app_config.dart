import 'dart:io';

import 'package:flutter/foundation.dart';

/// Build-time configuration (pass with --dart-define or --dart-define-from-file).
/// Nothing secret lives here: the Supabase anon key is public by design and every
/// table is protected by Row Level Security + server-side RPC checks.
class AppConfig {
  static const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

  static const _supportEmail = String.fromEnvironment('SUPPORT_EMAIL');
  static const _termsUrl = String.fromEnvironment('TERMS_URL');
  static const _privacyUrl = String.fromEnvironment('PRIVACY_URL');
  static const _inviteBaseUrl = String.fromEnvironment('INVITE_BASE_URL');

  // Placeholders until the real values are provided (see README > Configuration).
  // Empty defines (e.g. an unset CI secret) also fall back to the placeholder.
  static String get supportEmail => _supportEmail.isEmpty ? 'support@stridemate.example' : _supportEmail;
  static String get termsUrl => _termsUrl.isEmpty ? 'https://stridemate.example/terms' : _termsUrl;
  static String get privacyUrl => _privacyUrl.isEmpty ? 'https://stridemate.example/privacy' : _privacyUrl;

  /// Public web page that forwards to stridemate://join/CODE (optional).
  static String get inviteBaseUrl => _inviteBaseUrl.isEmpty ? 'https://stridemate.example/join' : _inviteBaseUrl;

  // ---- AdMob ------------------------------------------------------------------
  // Release builds use StrideMate's real AdMob units. Debug builds, and the
  // sideloaded test APK (built with --dart-define=USE_TEST_ADS=true), use Google's
  // official TEST units so nobody taps real ads on their own phone (AdMob can
  // suspend accounts for that). The AdMob *app* ID is set in
  // android/app/build.gradle.kts and ios/Runner/Info.plist.
  static const _adsEnabled = String.fromEnvironment('ADS_ENABLED', defaultValue: 'true');
  static const _forceTestAds = bool.fromEnvironment('USE_TEST_ADS');

  static bool get adsEnabled => _adsEnabled.toLowerCase() != 'false';
  static bool get usingTestAds => _forceTestAds || kDebugMode;

  // Real StrideMate units (Android).
  static const _realBannerAndroid = 'ca-app-pub-8306955081407788/1308277343';
  static const _realInterstitialAndroid = 'ca-app-pub-8306955081407788/1257587713';

  // Google test units.
  static const _testBannerAndroid = 'ca-app-pub-3940256099942544/9214589741';
  static const _testInterstitialAndroid = 'ca-app-pub-3940256099942544/1033173712';
  static const _testBannerIos = 'ca-app-pub-3940256099942544/2435281174';
  static const _testInterstitialIos = 'ca-app-pub-3940256099942544/4411468910';

  static String get bannerAdUnit => Platform.isIOS
      ? _testBannerIos // no real iOS units yet
      : (usingTestAds ? _testBannerAndroid : _realBannerAndroid);

  static String get interstitialAdUnit => Platform.isIOS
      ? _testInterstitialIos // no real iOS units yet
      : (usingTestAds ? _testInterstitialAndroid : _realInterstitialAndroid);

  /// Seeds sample data for store screenshots only (see lib/core/demo_data.dart).
  static const demoMode = bool.fromEnvironment('DEMO_DATA');

  static bool get backendConfigured => supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty;
  static bool get placeholdersInUse =>
      supportEmail.endsWith('.example') || termsUrl.contains('.example') || privacyUrl.contains('.example');
}
