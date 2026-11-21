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
  // Defaults are Google's official TEST ad units, which always serve test ads and
  // are safe to tap. Replace them with your own units only for release builds
  // (ADMOB_BANNER_ANDROID / ADMOB_BANNER_IOS). The AdMob *app* IDs live in
  // android/app/build.gradle.kts (ADMOB_APP_ID_ANDROID) and ios/Runner/Info.plist.
  static const _adsEnabled = String.fromEnvironment('ADS_ENABLED', defaultValue: 'true');
  static const _bannerAndroid = String.fromEnvironment('ADMOB_BANNER_ANDROID');
  static const _bannerIos = String.fromEnvironment('ADMOB_BANNER_IOS');

  static bool get adsEnabled => _adsEnabled.toLowerCase() != 'false';
  static String get bannerAdUnitAndroid =>
      _bannerAndroid.isEmpty ? 'ca-app-pub-3940256099942544/9214589741' : _bannerAndroid; // test adaptive banner
  static String get bannerAdUnitIos =>
      _bannerIos.isEmpty ? 'ca-app-pub-3940256099942544/2435281174' : _bannerIos; // test adaptive banner
  static bool get usingTestAds => _bannerAndroid.isEmpty && _bannerIos.isEmpty;

  static bool get backendConfigured => supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty;
  static bool get placeholdersInUse =>
      supportEmail.endsWith('.example') || termsUrl.contains('.example') || privacyUrl.contains('.example');
}
