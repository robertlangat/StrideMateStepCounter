import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/services.dart';
import '../../domain/day_key.dart';
import '../../domain/goals.dart';
import '../../widgets/common.dart';

class AchievementsScreen extends StatefulWidget {
  const AchievementsScreen({super.key});

  @override
  State<AchievementsScreen> createState() => _AchievementsScreenState();
}

class _AchievementsScreenState extends State<AchievementsScreen> {
  Map<String, String> _unlocked = {};
  PersonalRecords? _records;
  StreakResult? _streak;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final daily = await services.steps.allDailyTotals();
    final unlocked = await services.db.achievementsUnlocked();
    if (!mounted) return;
    setState(() {
      _unlocked = unlocked;
      _records = computeRecords(daily);
      _streak = services.steps.streak(daily);
    });
  }

  String _date(String? key) => key == null ? '—' : DateFormat.yMMMd().format(parseDayKey(key));

  @override
  Widget build(BuildContext context) {
    final r = _records;
    return Scaffold(
      appBar: AppBar(title: const Text('Achievements & records')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text('Personal records', style: Theme.of(context).textTheme.titleMedium),
        Card(
          child: Column(children: [
            ListTile(title: const Text('Best day'), subtitle: Text(_date(r?.bestDay)), trailing: Text(fmtInt(r?.bestDaySteps ?? 0))),
            ListTile(
                title: const Text('Best week'),
                subtitle: Text(r?.bestWeekStart == null ? '—' : 'Week of ${_date(r!.bestWeekStart)}'),
                trailing: Text(fmtInt(r?.bestWeekSteps ?? 0))),
            ListTile(
                title: const Text('Best month'),
                subtitle: Text(r?.bestMonth == null ? '—' : DateFormat.yMMMM().format(parseDayKey('${r!.bestMonth}-01'))),
                trailing: Text(fmtInt(r?.bestMonthSteps ?? 0))),
            ListTile(title: const Text('Current streak'), trailing: Text('${_streak?.current ?? 0} days')),
            ListTile(title: const Text('Longest streak'), trailing: Text('${_streak?.longest ?? 0} days')),
            ListTile(title: const Text('Lifetime steps'), trailing: Text(fmtInt(r?.lifetimeSteps ?? 0))),
          ]),
        ),
        const SizedBox(height: 16),
        Text('Achievements', style: Theme.of(context).textTheme.titleMedium),
        for (final a in achievements)
          Card(
            child: ListTile(
              leading: Opacity(
                opacity: _unlocked.containsKey(a.key) ? 1 : 0.3,
                child: Text(a.icon, style: const TextStyle(fontSize: 30)),
              ),
              title: Text(a.title),
              subtitle: Text(a.description),
              trailing: _unlocked.containsKey(a.key)
                  ? Text(_date(_unlocked[a.key]))
                  : const Text('Locked', semanticsLabel: 'Not yet earned'),
            ),
          ),
        const SizedBox(height: 8),
        const Text('Streak rules: a day counts when you reach that day\'s goal. Rest Days (up to 2 per week, '
            'scheduled in advance) keep your streak alive without adding to it. Today only counts once you reach '
            'your goal, and never breaks your streak while it is still in progress.'),
      ]),
    );
  }
}
