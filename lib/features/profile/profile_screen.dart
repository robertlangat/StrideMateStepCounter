import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../config/app_config.dart';
import '../../core/services.dart';
import '../../data/remote/api.dart';
import '../../domain/bots.dart';
import '../../domain/countries.dart';
import '../../widgets/common.dart';
import 'auth_screen.dart';
import 'notifications_screen.dart';
import 'rest_days_screen.dart';
import 'sources_screen.dart';

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: ListenableBuilder(
        listenable: Listenable.merge([services.auth, services.settings, services.steps]),
        builder: (context, _) {
          final auth = services.auth;
          final s = services.settings;
          final profile = auth.profile;
          return ListView(padding: const EdgeInsets.all(16), children: [
            _section(context, 'Account'),
            Card(
              child: !auth.available
                  ? const ListTile(
                      leading: Icon(Icons.cloud_off),
                      title: Text('Offline build'),
                      subtitle: Text('No StrideMate server is configured, so sync and social features are off. '
                          'Step counting, history, goals and bots all work.'),
                    )
                  : !auth.signedIn
                      ? ListTile(
                          leading: const Icon(Icons.login),
                          title: const Text('Sign in or create a free account'),
                          subtitle: const Text('Back up your steps and walk with groups. Optional.'),
                          onTap: () => _push(context, const AuthScreen()),
                        )
                      : Column(children: [
                          ListTile(
                            leading: CircleAvatar(child: Text((profile?['avatar_emoji'] as String?) ?? '🚶')),
                            title: Text(auth.displayName),
                            subtitle: Text(auth.email ?? ''),
                            trailing: const Icon(Icons.edit_outlined),
                            onTap: () => _editName(context),
                          ),
                          ListTile(
                            leading: const Icon(Icons.notifications_outlined),
                            title: const Text('Notifications'),
                            onTap: () => _push(context, const NotificationsScreen()),
                          ),
                          ListTile(
                            leading: const Icon(Icons.logout),
                            title: const Text('Sign out'),
                            subtitle: const Text('Your steps stay on this device.'),
                            onTap: () async {
                              await auth.signOut();
                              await services.sync?.resetForSignOut();
                            },
                          ),
                        ]),
            ),
            _section(context, 'Goals'),
            Card(
              child: Column(children: [
                ListTile(
                  leading: const Icon(Icons.flag_outlined),
                  title: const Text('Daily goal'),
                  trailing: Text('${fmtInt(s.dailyGoal)} steps'),
                  onTap: () => _editGoal(context),
                ),
                ListTile(
                  leading: const Icon(Icons.bedtime_outlined),
                  title: const Text('Rest Days'),
                  subtitle: Text('${services.steps.restDays.where((d) => d.compareTo(services.steps.today) >= 0).length} upcoming'),
                  onTap: () => _push(context, const RestDaysScreen()),
                ),
                ListTile(
                  leading: const Icon(Icons.straighten),
                  title: const Text('Stride length'),
                  subtitle: const Text('Used for distance estimates'),
                  trailing: Text('${s.strideCm} cm'),
                  onTap: () => _editNumber(context, 'Stride length (cm)', s.strideCm.toDouble(), 40, 120,
                      (v) => s.strideCm = v.round()),
                ),
                ListTile(
                  leading: const Icon(Icons.monitor_weight_outlined),
                  title: const Text('Body weight'),
                  subtitle: const Text('Used only for the calorie estimate, stored on this device'),
                  trailing: Text('${s.weightKg.round()} kg'),
                  onTap: () => _editNumber(context, 'Weight (kg)', s.weightKg, 30, 250, (v) => s.weightKg = v),
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.public),
                  title: const Text('Show miles'),
                  value: s.imperial,
                  onChanged: (v) => s.imperial = v,
                ),
              ]),
            ),
            _section(context, 'Steps & devices'),
            Card(
              child: ListTile(
                leading: const Icon(Icons.watch_outlined),
                title: const Text('Step sources'),
                subtitle: Text(Platform.isIOS ? 'iPhone, Apple Health and wearables' : 'Phone sensor, Health Connect and wearables'),
                onTap: () => _push(context, const SourcesScreen()),
              ),
            ),
            _section(context, 'Walking bots'),
            Card(
              child: Column(children: [
                SwitchListTile(
                  title: const Text('Show bots on Today'),
                  subtitle: const Text('Personal practice opponents. Never in group or global rankings.'),
                  value: s.showBots,
                  onChanged: (v) => s.showBots = v,
                ),
                for (final b in bots)
                  CheckboxListTile(
                    title: Text('${b.emoji}  ${b.name}'),
                    subtitle: Text(b.description),
                    value: s.enabledBots.contains(b.kind.name),
                    onChanged: !s.showBots
                        ? null
                        : (v) {
                            final set = {...s.enabledBots};
                            v == true ? set.add(b.kind.name) : set.remove(b.kind.name);
                            s.enabledBots = set;
                          },
                  ),
              ]),
            ),
            if (auth.signedIn) ...[
              _section(context, 'Privacy'),
              Card(
                child: Column(children: [
                  SwitchListTile(
                    title: const Text('Keep my steps private'),
                    subtitle: const Text('Nobody else sees your totals — not in any group, challenge or ranking. '
                        'You can also choose per group in each group\'s settings.'),
                    value: (profile?['steps_private'] as bool?) ?? false,
                    onChanged: (v) => _update(context, {'steps_private': v}),
                  ),
                  SwitchListTile(
                    title: const Text('Join country & global rankings'),
                    subtitle: const Text('Opt-in. Shows your display name, country and step totals to other '
                        'StrideMate users. Bots are never ranked.'),
                    value: (profile?['global_rankings_opt_in'] as bool?) ?? false,
                    onChanged: (v) => _update(context, {'global_rankings_opt_in': v}),
                  ),
                  ListTile(
                    title: const Text('Country'),
                    subtitle: const Text('Chosen by you; StrideMate never uses GPS.'),
                    trailing: Text(countryName(profile?['country_code'] as String?)),
                    onTap: () => _pickCountry(context),
                  ),
                ]),
              ),
            ],
            _section(context, 'Your data'),
            Card(
              child: Column(children: [
                ListTile(
                  leading: const Icon(Icons.download_outlined),
                  title: const Text('Export my data'),
                  subtitle: const Text('Everything on this device, plus your account data if signed in (JSON).'),
                  onTap: () => _export(context),
                ),
                if (auth.signedIn)
                  ListTile(
                    leading: Icon(Icons.delete_forever_outlined, color: Theme.of(context).colorScheme.error),
                    title: const Text('Delete account'),
                    subtitle: const Text('Deletes your account, synced steps, memberships and messages.'),
                    onTap: () => _deleteAccount(context),
                  ),
                ListTile(
                  leading: const Icon(Icons.phonelink_erase),
                  title: const Text('Erase data on this device'),
                  onTap: () => _eraseLocal(context),
                ),
              ]),
            ),
            _section(context, 'Appearance'),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: SegmentedButton<ThemeMode>(
                  segments: const [
                    ButtonSegment(value: ThemeMode.system, label: Text('System')),
                    ButtonSegment(value: ThemeMode.light, label: Text('Light')),
                    ButtonSegment(value: ThemeMode.dark, label: Text('Dark')),
                  ],
                  selected: {s.themeMode},
                  onSelectionChanged: (v) => s.themeMode = v.first,
                ),
              ),
            ),
            _section(context, 'About'),
            Card(
              child: Column(children: [
                ListTile(
                  leading: const Icon(Icons.mail_outline),
                  title: const Text('Contact support'),
                  subtitle: Text(AppConfig.supportEmail),
                  onTap: () => launchUrl(Uri(scheme: 'mailto', path: AppConfig.supportEmail, query: 'subject=StrideMate')),
                ),
                ListTile(
                  leading: const Icon(Icons.description_outlined),
                  title: const Text('Terms of Use'),
                  onTap: () => launchUrl(Uri.parse(AppConfig.termsUrl), mode: LaunchMode.externalApplication),
                ),
                ListTile(
                  leading: const Icon(Icons.privacy_tip_outlined),
                  title: const Text('Privacy Policy'),
                  onTap: () => launchUrl(Uri.parse(AppConfig.privacyUrl), mode: LaunchMode.externalApplication),
                ),
                FutureBuilder<PackageInfo>(
                  future: PackageInfo.fromPlatform(),
                  builder: (context, snap) => ListTile(
                    leading: const Icon(Icons.info_outline),
                    title: const Text('StrideMate – Step Counter'),
                    subtitle: Text('Version ${snap.data?.version ?? ''} · free, no subscriptions'),
                  ),
                ),
              ]),
            ),
          ]);
        },
      ),
    );
  }

  Widget _section(BuildContext context, String title) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
        child: Text(title, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
      );

  void _push(BuildContext context, Widget page) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));

  Future<void> _update(BuildContext context, Map<String, dynamic> fields) async {
    try {
      await services.auth.updateProfile(fields);
    } catch (e) {
      if (context.mounted) showSnack(context, friendlyError(e));
    }
  }

  Future<void> _editName(BuildContext context) async {
    final c = TextEditingController(text: services.auth.displayName);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Display name'),
        content: TextField(controller: c, maxLength: 40, decoration: const InputDecoration(helperText: 'Shown to your groups')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('Save')),
        ],
      ),
    );
    if (name != null && name.isNotEmpty && context.mounted) await _update(context, {'display_name': name});
  }

  Future<void> _editGoal(BuildContext context) async {
    var goal = services.settings.dailyGoal.toDouble();
    final result = await showDialog<int>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: const Text('Daily goal'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('${fmtInt(goal.round())} steps', style: Theme.of(ctx).textTheme.headlineSmall),
            Slider(
              value: goal,
              min: 1000,
              max: 30000,
              divisions: 58,
              semanticFormatterCallback: (v) => '${fmtInt(v.round())} steps',
              onChanged: (v) => set(() => goal = v),
            ),
            const Text('Applies from today. Past days keep the goal they had.'),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, goal.round()), child: const Text('Save')),
          ],
        ),
      ),
    );
    if (result != null) {
      await services.steps.setDailyGoal(result);
      await services.sync?.syncNow();
    }
  }

  Future<void> _editNumber(BuildContext context, String title, double value, double min, double max,
      void Function(double) save) async {
    var v = value.clamp(min, max).toDouble();
    final result = await showDialog<double>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: Text(title),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(v.round().toString(), style: Theme.of(ctx).textTheme.headlineSmall),
            Slider(value: v, min: min, max: max, divisions: (max - min).round(), onChanged: (x) => set(() => v = x)),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, v), child: const Text('Save')),
          ],
        ),
      ),
    );
    if (result != null) save(result);
  }

  Future<void> _pickCountry(BuildContext context) async {
    final code = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.8,
        builder: (ctx, scroll) => ListView.builder(
          controller: scroll,
          itemCount: countries.length + 1,
          itemBuilder: (ctx, i) => i == 0
              ? ListTile(title: const Text('Prefer not to say'), onTap: () => Navigator.pop(ctx, ''))
              : ListTile(
                  leading: Text(flagEmoji(countries[i - 1].$1), style: const TextStyle(fontSize: 22)),
                  title: Text(countries[i - 1].$2),
                  onTap: () => Navigator.pop(ctx, countries[i - 1].$1),
                ),
        ),
      ),
    );
    if (code != null && context.mounted) await _update(context, {'country_code': code.isEmpty ? null : code});
  }

  Future<void> _export(BuildContext context) async {
    try {
      final data = <String, dynamic>{
        'app': 'StrideMate',
        'exported_at': DateTime.now().toUtc().toIso8601String(),
        'device': await services.db.exportAll(),
      };
      if (services.auth.signedIn) data['account'] = await services.api!.exportMyData();
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/stridemate-export-${DateTime.now().millisecondsSinceEpoch}.json');
      await file.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
      await Share.shareXFiles([XFile(file.path, mimeType: 'application/json')], subject: 'My StrideMate data');
    } catch (e) {
      if (context.mounted) showSnack(context, friendlyError(e));
    }
  }

  Future<void> _deleteAccount(BuildContext context) async {
    final c = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete your account?'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('This permanently deletes your account, synced step history, group memberships, messages and '
              'challenge entries. Groups you own pass to an admin or the longest-standing member. '
              'Type DELETE to confirm.'),
          TextField(controller: c),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim() == 'DELETE'), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await services.api!.deleteMyAccount();
      await services.auth.signOut();
      await services.sync?.resetForSignOut();
      if (context.mounted) showSnack(context, 'Your account has been deleted.');
    } catch (e) {
      if (context.mounted) showSnack(context, friendlyError(e));
    }
  }

  Future<void> _eraseLocal(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Erase this device\'s data?'),
        content: const Text('Removes step history, Rest Days and achievements stored on this phone. Data already '
            'synced to your account is not affected.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Erase')),
        ],
      ),
    );
    if (ok != true) return;
    await services.db.wipe();
    services.settings.restoredFromCloud = false;
    await services.steps.reloadFromDb();
  }
}
