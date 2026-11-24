import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../ads/ad_banner.dart';
import '../../core/services.dart';
import '../../domain/day_key.dart';
import '../../domain/goals.dart';
import '../../widgets/common.dart';
import '../../widgets/step_bar_chart.dart';
import '../profile/achievements_screen.dart';
import '../recap/recap_screen.dart';

enum HistoryRange { day, week, month, year }

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  HistoryRange _range = HistoryRange.week;
  DateTime _anchor = startOfDay(DateTime.now());
  List<ChartPoint> _points = [];
  int _total = 0;
  int _avg = 0;
  int _best = 0;
  int _goalDays = 0;
  String _title = '';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    services.steps.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    services.steps.removeListener(_load);
    super.dispose();
  }

  DateTime _shift(int dir) => switch (_range) {
        HistoryRange.day => addDays(_anchor, dir),
        HistoryRange.week => addDays(_anchor, 7 * dir),
        HistoryRange.month => DateTime(_anchor.year, _anchor.month + dir, 1),
        HistoryRange.year => DateTime(_anchor.year + dir, 1, 1),
      };

  bool get _atPresent {
    final next = _shift(1);
    return next.isAfter(startOfDay(DateTime.now()));
  }

  Future<void> _load() async {
    final repo = services.steps;
    final goals = repo.goals;
    final today = startOfDay(DateTime.now());
    final points = <ChartPoint>[];
    var total = 0, best = 0, goalDays = 0, counted = 0;

    switch (_range) {
      case HistoryRange.day:
        final hourly = await repo.hourlyFor(_anchor);
        for (var h = 0; h < 24; h++) {
          final start = DateTime(_anchor.year, _anchor.month, _anchor.day, h);
          final s = hourly[start.toUtc().millisecondsSinceEpoch] ?? 0;
          points.add(ChartPoint('$h', s, semanticLabel: DateFormat.j().format(start)));
          total += s;
          if (s > best) best = s;
        }
        counted = 1;
        _title = DateFormat.yMMMMEEEEd().format(_anchor);
      case HistoryRange.week:
        final start = startOfWeek(_anchor);
        final daily = await repo.dailyTotalsBetween(start, addDays(start, 6));
        for (var i = 0; i < 7; i++) {
          final d = addDays(start, i);
          final key = dayKey(d);
          final s = daily[key] ?? 0;
          points.add(ChartPoint(DateFormat.E().format(d).substring(0, 2), s,
              semanticLabel: DateFormat.MMMEd().format(d), highlight: d == today));
          if (!d.isAfter(today)) {
            total += s;
            counted++;
            if (s >= goals.goalFor(key)) goalDays++;
          }
          if (s > best) best = s;
        }
        _title = 'Week of ${DateFormat.MMMd().format(start)}';
      case HistoryRange.month:
        final start = startOfMonth(_anchor);
        final end = addDays(DateTime(start.year, start.month + 1, 1), -1);
        final daily = await repo.dailyTotalsBetween(start, end);
        for (var d = start; !d.isAfter(end); d = nextDay(d)) {
          final key = dayKey(d);
          final s = daily[key] ?? 0;
          points.add(ChartPoint('${d.day}', s, semanticLabel: DateFormat.MMMd().format(d), highlight: d == today));
          if (!d.isAfter(today)) {
            total += s;
            counted++;
            if (s >= goals.goalFor(key)) goalDays++;
          }
          if (s > best) best = s;
        }
        _title = DateFormat.yMMMM().format(start);
      case HistoryRange.year:
        final start = DateTime(_anchor.year, 1, 1);
        final daily = await repo.dailyTotalsBetween(start, DateTime(_anchor.year, 12, 31));
        final months = List<int>.filled(12, 0);
        daily.forEach((k, v) {
          final d = parseDayKey(k);
          months[d.month - 1] += v;
          if (!d.isAfter(today)) {
            total += v;
            if (v >= goals.goalFor(k)) goalDays++;
          }
          if (v > best) best = v;
        });
        for (var m = 0; m < 12; m++) {
          final md = DateTime(_anchor.year, m + 1, 1);
          points.add(ChartPoint(DateFormat.MMM().format(md).substring(0, 1), months[m],
              semanticLabel: DateFormat.yMMMM().format(md)));
        }
        final last = _anchor.year == today.year ? today : DateTime(_anchor.year, 12, 31);
        counted = last.difference(start).inDays + 1;
        _title = '${_anchor.year}';
    }

    if (!mounted) return;
    setState(() {
      _points = points;
      _total = total;
      _best = best;
      _goalDays = goalDays;
      _avg = counted == 0 ? 0 : (total / counted).round();
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final goal = services.steps.goals.goalFor(services.steps.today);
    return Scaffold(
      appBar: AppBar(title: const Text('History'), actions: [
        IconButton(
          tooltip: 'Recaps',
          icon: const Icon(Icons.auto_awesome),
          onPressed: () {
            Ads.maybeShowInterstitial();
            Navigator.of(context).push(MaterialPageRoute(builder: (_) => const RecapScreen()));
          },
        ),
        IconButton(
          tooltip: 'Achievements and records',
          icon: const Icon(Icons.military_tech_outlined),
          onPressed: () {
            Ads.maybeShowInterstitial();
            Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AchievementsScreen()));
          },
        ),
      ]),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SegmentedButton<HistoryRange>(
            // No tick on the selected segment: it squeezed "Month" onto two lines.
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: HistoryRange.day, label: Text('Day')),
              ButtonSegment(value: HistoryRange.week, label: Text('Week')),
              ButtonSegment(value: HistoryRange.month, label: Text('Month')),
              ButtonSegment(value: HistoryRange.year, label: Text('Year')),
            ],
            selected: {_range},
            onSelectionChanged: (s) {
              setState(() {
                _range = s.first;
                _anchor = startOfDay(DateTime.now());
              });
              _load();
            },
          ),
          const SizedBox(height: 8),
          Row(children: [
            IconButton(
              tooltip: 'Previous',
              icon: const Icon(Icons.chevron_left),
              onPressed: () {
                setState(() => _anchor = _shift(-1));
                _load();
              },
            ),
            Expanded(child: Text(_title, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium)),
            IconButton(
              tooltip: 'Next',
              icon: const Icon(Icons.chevron_right),
              onPressed: _atPresent
                  ? null
                  : () {
                      setState(() => _anchor = _shift(1));
                      _load();
                    },
            ),
          ]),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Wrap(spacing: 24, runSpacing: 12, children: [
                _Stat('Total', fmtInt(_total)),
                _Stat(_range == HistoryRange.day ? 'Distance' : 'Daily average',
                    _range == HistoryRange.day ? fmtDistance(_total) : fmtInt(_avg)),
                _Stat(_range == HistoryRange.day ? 'Best hour' : 'Best day', fmtInt(_best)),
                if (_range != HistoryRange.day) _Stat('Goal days', '$_goalDays'),
              ]),
            ),
          ),
          const SizedBox(height: 12),
          if (_loading)
            const Padding(padding: EdgeInsets.all(48), child: Center(child: CircularProgressIndicator()))
          else
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: StepBarChart(
                  title: switch (_range) {
                    HistoryRange.day => 'Steps per hour',
                    HistoryRange.year => 'Steps per month',
                    _ => 'Steps per day',
                  },
                  points: _points,
                  goal: (_range == HistoryRange.week || _range == HistoryRange.month) ? goal : null,
                ),
              ),
            ),
          const SizedBox(height: 8),
          Text(
            'Totals combine your phone and connected health sources without double counting '
            '(${services.settings.sourcePolicy.name == 'auto' ? 'highest source each hour' : 'your preferred source first'}).',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Semantics(
        label: '$label $value',
        excludeSemantics: true,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: Theme.of(context).textTheme.bodySmall),
          Text(value, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
        ]),
      );
}

// Exposed for the achievements screen.
StreakResult streakFor(Map<String, int> daily) => services.steps.streak(daily);
