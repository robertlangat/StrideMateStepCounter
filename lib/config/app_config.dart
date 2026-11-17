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

  static bool get backendConfigured => supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty;
  static bool get placeholdersInUse =>
      supportEmail.endsWith('.example') || termsUrl.contains('.example') || privacyUrl.contains('.example');
}
