import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/services.dart';
import '../../data/sources/health_source.dart';
import '../../data/sources/phone_source.dart';
import '../../domain/bots.dart';
import '../../domain/goals.dart';
import '../profile/sources_screen.dart';
import '../../widgets/common.dart';
import '../../widgets/step_ring.dart';

class TodayScreen extends StatefulWidget {
  const TodayScreen({super.key});

  @override
  State<TodayScreen> createState() => _TodayScreenState();
}

class _TodayScreenState extends State<TodayScreen> {
  Timer? _tick;
  StreakResult? _streak;

  @override
  void initState() {
    super.initState();
    // Re-sample every minute while visible so the count feels live.
    _tick = Timer.periodic(const Duration(minutes: 1), (_) => services.steps.refresh());
    services.steps.addListener(_loadStreak);
    _loadStreak();
  }

  Future<void> _loadStreak() async {
    final daily = await services.steps.allDailyTotals();
    final today = services.steps.today;
    final withToday = {...daily, today: services.steps.todaySteps};
    if (mounted) setState(() => _streak = services.steps.streak(withToday));
  }

  @override
  void dispose() {
    _tick?.cancel();
    services.steps.removeListener(_loadStreak);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final listen = Listenable.merge([services.steps, services.settings, services.auth, if (services.sync != null) services.sync!]);
    return Scaffold(
      appBar: AppBar(title: const Text('Today')),
      body: ListenableBuilder(
        listenable: listen,
        builder: (context, _) {
          final repo = services.steps;
          final steps = repo.todaySteps;
          final goal = repo.goals.goalFor(repo.today);
          final isRest = repo.restDays.contains(repo.today);
          return RefreshIndicator(
            onRefresh: () async {
              await repo.refresh();
              await services.sync?.syncNow();
            },
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
              children: [
                ..._banners(context),
                const SizedBox(height: 8),
                Center(child: StepRing(steps: steps, goal: goal)),
                const SizedBox(height: 16),
                _StatsRow(steps: steps),
                const SizedBox(height: 8),
                _SyncLine(),
                const SizedBox(height: 12),
                Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: [
                  if (_streak != null)
                    Chip(
                      avatar: const Text('🔥'),
                      label: Text('${_streak!.current}-day streak'),
                    ),
                  if (isRest) const Chip(avatar: Text('🛌'), label: Text('Rest Day — streak protected')),
                ]),
                const SizedBox(height: 16),
                if (services.settings.showBots) _BotsCard(steps: steps),
              ],
            ),
          );
        },
      ),
    );
  }

  List<Widget> _banners(BuildContext context) {
    final repo = services.steps;
    final out = <Widget>[];
    switch (repo.phoneState) {
      case PhoneSensorState.permissionNeeded:
        out.add(StatusBanner(
          icon: Icons.directions_walk,
          title: 'Allow motion access to count steps',
          body: Platform.isIOS
              ? 'StrideMate uses Motion & Fitness to count steps with your iPhone. No location is used.'
              : 'StrideMate needs the "Physical activity" permission to read your phone\'s step counter. No location is used.',
          actionLabel: 'Allow',
          onAction: () async {
            await services.phone.requestPermission();
            await repo.refresh();
          },
        ));
      case PhoneSensorState.permissionPermanentlyDenied:
        out.add(StatusBanner(
          icon: Icons.block,
          title: 'Motion access is turned off',
          body: Platform.isIOS
              ? 'Turn on Settings › Privacy & Security › Motion & Fitness › StrideMate, then come back.'
              : 'Open App info › Permissions › Physical activity and choose Allow, then come back. '
                  'Steps recorded before the change are kept.',
          actionLabel: 'Open settings',
          onAction: () => openAppSettings(),
        ));
      case PhoneSensorState.unavailable:
        if (repo.healthState != HealthState.connected) {
          out.add(StatusBanner(
            icon: Icons.sensors_off,
            title: 'This phone has no step sensor',
            body: 'Connect ${Platform.isIOS ? 'Apple Health' : 'Health Connect'} to count steps from a watch, '
                'band or another fitness app instead.',
            actionLabel: 'Connect a source',
            onAction: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SourcesScreen())),
          ));
        }
      case PhoneSensorState.ready:
      case PhoneSensorState.unsupportedPlatform:
        break;
    }
    if (services.settings.healthEnabled && repo.healthState != HealthState.connected) {
      out.add(StatusBanner(
        icon: Icons.watch_off_outlined,
        title: Platform.isIOS ? 'Apple Health is not available' : 'Health Connect needs attention',
        body: switch (repo.healthState) {
          HealthState.notInstalled => 'Install Health Connect from Google Play to include steps from your watch or other apps.',
          HealthState.updateRequired => 'Update Health Connect from Google Play, then return to StrideMate.',
          _ => 'StrideMate no longer has permission to read steps. Reconnect to include your wearable.',
        },
        actionLabel: 'Fix',
        onAction: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SourcesScreen())),
      ));
    }
    if (repo.lastUpdated != null && DateTime.now().difference(repo.lastUpdated!) > const Duration(hours: 3)) {
      out.add(StatusBanner(
        icon: Icons.schedule,
        title: 'Steps may be out of date',
        body: 'Last updated ${fmtAgo(repo.lastUpdated)}. Android and iOS can pause background updates after '
            'a force-stop, in battery saver, or after permission changes. Pull down to refresh.',
      ));
    }
    return out;
  }
}

class _StatsRow extends StatelessWidget {
  const _StatsRow({required this.steps});
  final int steps;

  @override
  Widget build(BuildContext context) {
    Widget cell(IconData icon, String value, String label) => Expanded(
          child: Semantics(
            label: '$label: $value',
            excludeSemantics: true,
            child: Column(children: [
              Icon(icon),
              const SizedBox(height: 4),
              Text(value, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
              Text(label, style: Theme.of(context).textTheme.bodySmall, textAlign: TextAlign.center),
            ]),
          ),
        );
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
        child: Row(children: [
          cell(Icons.straighten, fmtDistance(steps), 'Distance'),
          cell(Icons.local_fire_department_outlined, fmtKcal(steps), 'Calories (estimate)'),
        ]),
      ),
    );
  }
}

class _SyncLine extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final repo = services.steps;
    final sync = services.sync;
    final String text;
    if (!services.auth.signedIn || sync == null) {
      text = 'Updated ${fmtAgo(repo.lastUpdated)} · stored on this device';
    } else if (sync.syncing) {
      text = 'Syncing…';
    } else if (sync.lastError != null) {
      text = 'Updated ${fmtAgo(repo.lastUpdated)} · last sync ${fmtAgo(sync.lastSync)} · will retry when online';
    } else {
      text = 'Updated ${fmtAgo(repo.lastUpdated)} · last sync ${fmtAgo(sync.lastSync)}';
    }
    return Text(text, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall);
  }
}

class _BotsCard extends StatelessWidget {
  const _BotsCard({required this.steps});
  final int steps;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final enabled = services.settings.enabledBots;
    final yesterday = yesterdayBotSteps(
      nowLocal: now,
      effectiveHourly: services.steps.recentEffectiveHourly,
      trackingSince: DateTime.fromMillisecondsSinceEpoch(services.settings.trackingSinceMs),
    );
    final rows = <Widget>[];
    for (final b in bots) {
      if (!enabled.contains(b.kind.name)) continue;
      final int? botSteps = switch (b.kind) {
        BotKind.chill => chillBotSteps(now),
        BotKind.active => activeBotSteps(now),
        BotKind.yesterday => yesterday,
      };
      final diff = botSteps == null ? null : steps - botSteps;
      rows.add(ListTile(
        leading: Text(b.emoji, style: const TextStyle(fontSize: 28)),
        title: Row(children: [
          Text(b.name),
          const SizedBox(width: 6),
          const _BotTag(),
        ]),
        subtitle: Text(botSteps == null
            ? 'Not enough history yet — check back tomorrow.'
            : '${fmtInt(botSteps)} steps by now · ${b.description}'),
        trailing: diff == null
            ? null
            : Text(diff >= 0 ? '+${fmtInt(diff)}' : fmtInt(diff),
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: diff >= 0 ? Theme.of(context).colorScheme.secondary : Theme.of(context).colorScheme.error,
                )),
      ));
    }
    if (rows.isEmpty) return const SizedBox.shrink();
    return Card(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Text('You vs the walking bots', style: Theme.of(context).textTheme.titleMedium),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: Text('Virtual competitors for personal challenges. Bots never appear in group or global rankings.'),
        ),
        ...rows,
      ]),
    );
  }
}

class _BotTag extends StatelessWidget {
  const _BotTag();

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          border: Border.all(color: Theme.of(context).colorScheme.outline),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text('BOT', style: Theme.of(context).textTheme.labelSmall),
      );
}

