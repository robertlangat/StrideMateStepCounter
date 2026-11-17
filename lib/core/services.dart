import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/app_config.dart';
import '../data/auth_service.dart';
import '../data/local_db.dart';
import '../data/remote/api.dart';
import '../data/settings_store.dart';
import '../data/sources/health_source.dart';
import '../data/sources/phone_source.dart';
import '../data/step_repository.dart';
import '../data/sync/sync_engine.dart';
import '../data/widget_bridge.dart';

/// Application-wide services, created once at start-up.
class Services {
  Services._({
    required this.settings,
    required this.db,
    required this.steps,
    required this.auth,
    required this.api,
    required this.sync,
    required this.phone,
  });

  final SettingsStore settings;
  final LocalDb db;
  final StepRepository steps;
  final AuthService auth;
  final Api? api;
  final SyncEngine? sync;
  final PhoneStepSource phone;

  static late Services instance;

  static Future<Services> create() async {
    final settings = await SettingsStore.load();
    final db = await LocalDb.open();
    await WidgetBridge.init();
    final phone = PhoneStepSource();
    final steps = StepRepository(db: db, settings: settings, phone: phone, health: HealthStepSource());

    Api? api;
    if (AppConfig.backendConfigured) {
      await Supabase.initialize(url: AppConfig.supabaseUrl, anonKey: AppConfig.supabaseAnonKey);
      api = Api(Supabase.instance.client);
    }
    final auth = AuthService(api);
    final sync = api == null ? null : SyncEngine(db: db, api: api, auth: auth, settings: settings, steps: steps);
    instance = Services._(settings: settings, db: db, steps: steps, auth: auth, api: api, sync: sync, phone: phone);
    return instance;
  }
}

Services get services => Services.instance;
