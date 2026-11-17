import 'dart:io';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/services.dart';
import '../../data/sources/health_source.dart';
import '../../data/sources/phone_source.dart';
import '../../domain/source_merge.dart';
import '../../widgets/common.dart';

/// Step sources, the de-duplication policy, wearable guidance and diagnostics.
class SourcesScreen extends StatefulWidget {
  const SourcesScreen({super.key});

  @override
  State<SourcesScreen> createState() => _SourcesScreenState();
}

class _SourcesScreenState extends State<SourcesScreen> {
  Map<String, int>? _contributors;
  Map<String, dynamic>? _diag;

  String get _platformHealth => Platform.isIOS ? 'Apple Health' : 'Health Connect';

  @override
  void initState() {
    super.initState();
    services.steps.refreshSourceStates();
    _loadDiagnostics();
  }

  Future<void> _loadDiagnostics() async {
    try {
      final d = await services.phone.diagnostics();
      Map<String, int>? c;
      if (services.steps.healthState == HealthState.connected) {
        final now = DateTime.now();
        c = await services.steps.health.contributors(now.subtract(const Duration(days: 7)), now);
      }
      if (!mounted) return;
      setState(() {
        _diag = d;
        _contributors = c;
      });
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Step sources')),
      body: ListenableBuilder(
        listenable: Listenable.merge([services.steps, services.settings]),
        builder: (context, _) {
          final repo = services.steps;
          return ListView(padding: const EdgeInsets.all(16), children: [
            Card(
              child: Column(children: [
                ListTile(
                  leading: const Icon(Icons.smartphone),
                  title: Text(Platform.isIOS ? 'iPhone motion (Core Motion)' : 'Phone step sensor'),
                  subtitle: Text(switch (repo.phoneState) {
                    PhoneSensorState.ready => 'Counting. Works offline and without an account.',
                    PhoneSensorState.permissionNeeded => 'Needs motion permission.',
                    PhoneSensorState.permissionPermanentlyDenied => 'Permission denied — enable it in system settings.',
                    PhoneSensorState.unavailable => 'This device has no step-counter sensor.',
                    PhoneSensorState.unsupportedPlatform => 'Not supported on this platform.',
                  }),
                  trailing: switch (repo.phoneState) {
                    PhoneSensorState.permissionNeeded => TextButton(
                        onPressed: () async {
                          await services.phone.requestPermission();
                          await repo.refresh();
                        },
                        child: const Text('Allow')),
                    PhoneSensorState.permissionPermanentlyDenied =>
                      TextButton(onPressed: openAppSettings, child: const Text('Settings')),
                    _ => null,
                  },
                ),
                if (Platform.isAndroid)
                  SwitchListTile(
                    secondary: const Icon(Icons.notifications_active_outlined),
                    title: const Text('Live counting notification'),
                    subtitle: const Text('Keeps an ongoing notification with today\'s steps and refreshes the widget '
                        'more often. Uses slightly more battery. Counting works without it.'),
                    value: services.settings.liveCounting,
                    onChanged: (v) async {
                      if (v) await Permission.notification.request();
                      await repo.setLiveCounting(v);
                    },
                  ),
              ]),
            ),
            Card(
              child: Column(children: [
                ListTile(
                  leading: const Icon(Icons.favorite_outline),
                  title: Text(_platformHealth),
                  subtitle: Text(switch (repo.healthState) {
                    HealthState.connected => 'Connected. Steps from watches and fitness apps that write to $_platformHealth are included.',
                    HealthState.notConnected => 'Not connected.',
                    HealthState.notInstalled => 'Health Connect is not installed.',
                    HealthState.updateRequired => 'Health Connect needs an update.',
                    HealthState.unsupported => 'Not available on this device.',
                  }),
                ),
                OverflowBar(alignment: MainAxisAlignment.end, children: [
                  if (repo.healthState == HealthState.notInstalled || repo.healthState == HealthState.updateRequired)
                    TextButton(
                        onPressed: () => services.steps.health.installOrUpdateHealthConnect(),
                        child: const Text('Get Health Connect')),
                  if (repo.healthState == HealthState.notConnected)
                    FilledButton(
                      onPressed: () async {
                        final ok = await repo.connectHealth();
                        if (context.mounted && !ok) {
                          showSnack(context, 'Permission was not granted. You can try again any time.');
                        }
                        _loadDiagnostics();
                      },
                      child: const Text('Connect'),
                    ),
                  if (services.settings.healthEnabled)
                    TextButton(onPressed: () => _confirmDisconnect(context), child: const Text('Disconnect')),
                ]),
              ]),
            ),
            const SizedBox(height: 8),
            Text('Avoiding double counting', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            const Text('When your phone and a wearable both see the same walk, StrideMate never adds them together. '
                'It compares sources hour by hour:'),
            for (final opt in const [
              (SourcePolicy.auto, 'Automatic (recommended)', 'Use whichever source counted more steps in each hour.'),
              (SourcePolicy.preferHealth, 'Prefer my wearable', 'Use health-platform data when it has steps for that hour.'),
              (SourcePolicy.preferPhone, 'Prefer my phone', 'Use the phone sensor when it has steps for that hour.'),
            ])
              RadioListTile<SourcePolicy>(
                value: opt.$1,
                groupValue: services.settings.sourcePolicy,
                onChanged: (p) {
                  if (p != null) repo.setSourcePolicy(p);
                },
                title: Text(opt.$2),
                subtitle: Text(opt.$3),
              ),
            const SizedBox(height: 8),
            ExpansionTile(
              title: const Text('Wearables and other apps'),
              childrenPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              children: [
                Text(Platform.isIOS
                    ? 'StrideMate reads steps from Apple Health. Apple Watch writes there automatically. '
                        'For other brands, turn on Apple Health sync in the brand\'s companion app.'
                    : 'StrideMate reads steps from Health Connect. Turn on Health Connect sync in your device\'s '
                        'companion app; Health Connect then shares it with StrideMate.'),
                const SizedBox(height: 8),
                for (final w in wearableGuide)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(w.$1),
                    subtitle: Text(Platform.isIOS ? w.$3 : w.$2),
                  ),
                const Text('See docs/WEARABLES.md for what was verified and what needs a real device.'),
              ],
            ),
            if (_contributors != null)
              ExpansionTile(
                title: const Text('Apps that contributed steps (last 7 days)'),
                children: [
                  if (_contributors!.isEmpty) const ListTile(title: Text('None yet.')),
                  for (final e in _contributors!.entries)
                    ListTile(dense: true, title: Text(e.key), trailing: Text(fmtInt(e.value))),
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text('Raw per-app totals overlap; StrideMate uses the platform\'s de-duplicated total.'),
                  ),
                ],
              ),
            ExpansionTile(
              title: const Text('Background updates and diagnostics'),
              childrenPadding: const EdgeInsets.all(16),
              children: [
                Text(Platform.isIOS
                    ? 'iOS refreshes widgets and background data on its own schedule. Core Motion keeps 7 days of '
                        'step history, so opening the app catches up on anything missed.'
                    : 'The phone\'s step counter keeps counting while StrideMate is closed. StrideMate samples it about '
                        'every 15 minutes, at shutdown and after reboot. Android can delay sampling in battery saver, '
                        'Doze, or after you force-stop the app (no background work runs until you open it again). '
                        'A reboot while the phone could not be sampled may lose steps since the last sample.'),
                const SizedBox(height: 8),
                if (_diag != null) for (final e in _diag!.entries) Text('${e.key}: ${e.value}', style: const TextStyle(fontFamily: 'monospace')),
              ],
            ),
          ]);
        },
      ),
    );
  }

  Future<void> _confirmDisconnect(BuildContext context) async {
    final choice = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Disconnect $_platformHealth?'),
        content: const Text('StrideMate will stop reading steps from it. You can keep the steps already imported, '
            'or remove them from this device.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(c, 'keep'), child: const Text('Keep history')),
          TextButton(onPressed: () => Navigator.pop(c, 'delete'), child: const Text('Remove imported steps')),
        ],
      ),
    );
    if (choice == null) return;
    await services.steps.disconnectHealth(deleteData: choice == 'delete');
    if (Platform.isIOS && context.mounted) {
      showSnack(context, 'To fully revoke access, open Settings › Health › Data Access & Devices › StrideMate.');
    }
  }
}

/// (brand, Android path, iOS path). Checked November 2026 — see docs/WEARABLES.md.
const wearableGuide = <(String, String, String)>[
  ('Fitbit / Pixel Watch (Google Health app)',
      'Google Health app (formerly Fitbit) › Connections › Partner apps › Health Connect.',
      'Google Health app 5.05 or later › Profile › Partner apps › Apple Health.'),
  ('Garmin', 'Garmin Connect › Settings › Health Connect (needs Android 14 or later).',
      'Garmin Connect › Settings › Connected Apps › Apple Health.'),
  ('Samsung Galaxy Watch', 'Samsung Health › Settings › Health Connect › allow Steps.',
      'Not available: Samsung Health is Android-only.'),
  ('Oura', 'Oura app › Settings › Data sharing › Health Connect.', 'Oura app › Settings › Data sharing › Apple Health.'),
  ('WHOOP', 'WHOOP app › More › Integrations › Health Connect.', 'WHOOP app › More › Integrations › Apple Health.'),
  ('Withings', 'Withings app › Share/Profile › Apps › Health Connect. New accounts may need a paid Withings plan to export.',
      'Withings app › Profile › Settings › Export to Apple Health. New accounts may need a paid Withings plan to export.'),
  ('Xiaomi Mi Band / Smart Band', 'Mi Fitness › Profile › Third-party data › Health Connect.',
      'Mi Fitness › Profile › Third-party data › Apple Health.'),
  ('Amazfit (Zepp)', 'Zepp › Profile › Add accounts › Health Connect.', 'Zepp › Profile › Add accounts › Apple Health.'),
];
