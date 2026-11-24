import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/services.dart';
import '../../domain/day_key.dart';
import '../../domain/recap.dart';
import '../../theme/app_theme.dart';
import '../../widgets/common.dart';

/// Monthly and yearly StrideMate Recaps, shareable as an image with an optional photo.
class RecapScreen extends StatefulWidget {
  const RecapScreen({super.key});

  @override
  State<RecapScreen> createState() => _RecapScreenState();
}

enum RecapStat { total, average, best, goalDays, distance, streak, change }

class _RecapScreenState extends State<RecapScreen> {
  final _boundary = GlobalKey();
  bool _yearly = false;
  late DateTime _period = DateTime(DateTime.now().year, DateTime.now().month, 1);
  Recap? _recap;
  File? _photo;
  final _selected = {RecapStat.total, RecapStat.average, RecapStat.best, RecapStat.goalDays, RecapStat.distance};

  @override
  void initState() {
    super.initState();
    _build();
  }

  Future<void> _build() async {
    final repo = services.steps;
    final daily = await repo.allDailyTotals();
    final recap = buildRecap(
      daily: {...daily, repo.today: repo.todaySteps},
      restDays: repo.restDays,
      goals: repo.goals,
      strideCm: services.settings.strideCm,
      year: _period.year,
      month: _yearly ? null : _period.month,
      today: repo.today,
    );
    if (mounted) setState(() => _recap = recap);
  }

  Future<void> _pickPhoto() async {
    final x = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 1600, imageQuality: 85);
    if (x != null) setState(() => _photo = File(x.path));
  }

  Future<void> _share() async {
    try {
      final boundary = _boundary.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 3);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/stridemate-recap-${DateTime.now().millisecondsSinceEpoch}.png');
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      await Share.shareXFiles([XFile(file.path, mimeType: 'image/png')], text: 'My ${_recap!.title} on StrideMate');
    } catch (e) {
      if (mounted) showSnack(context, 'Could not create the image: $e');
    }
  }

  List<(String, String)> _lines(Recap r) {
    final change = r.changeVsPrevious;
    return [
      if (_selected.contains(RecapStat.total)) ('Steps', fmtInt(r.totalSteps)),
      if (_selected.contains(RecapStat.average)) ('Daily average', fmtInt(r.dailyAverage)),
      if (_selected.contains(RecapStat.best) && r.bestDay != null)
        ('Best day', '${fmtInt(r.bestDaySteps)} · ${DateFormat.MMMd().format(parseDayKey(r.bestDay!))}'),
      if (_selected.contains(RecapStat.goalDays)) ('Goal days', '${r.goalDays}'),
      if (_selected.contains(RecapStat.distance))
        ('Distance', services.settings.imperial ? '${(r.distanceKm * 0.621371).toStringAsFixed(1)} mi' : '${r.distanceKm.toStringAsFixed(1)} km'),
      if (_selected.contains(RecapStat.streak)) ('Longest streak', '${r.longestStreak} days'),
      if (_selected.contains(RecapStat.change) && change != null)
        ('vs previous', '${change >= 0 ? '+' : ''}${(change * 100).round()}%'),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final r = _recap;
    final now = DateTime.now();
    final periods = _yearly
        ? [for (var y = now.year; y > now.year - 5; y--) DateTime(y, 1, 1)]
        : [for (var i = 0; i < 24; i++) DateTime(now.year, now.month - i, 1)];
    return Scaffold(
      appBar: AppBar(title: const Text('StrideMate Recap')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        SegmentedButton<bool>(
          segments: const [ButtonSegment(value: false, label: Text('Monthly')), ButtonSegment(value: true, label: Text('Yearly'))],
          selected: {_yearly},
          onSelectionChanged: (v) {
            setState(() {
              _yearly = v.first;
              _period = _yearly ? DateTime(now.year, 1, 1) : DateTime(now.year, now.month, 1);
            });
            _build();
          },
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<DateTime>(
          value: periods.firstWhere((p) => p == _period, orElse: () => periods.first),
          decoration: const InputDecoration(border: OutlineInputBorder()),
          items: [
            for (final p in periods)
              DropdownMenuItem(value: p, child: Text(_yearly ? '${p.year}' : DateFormat.yMMMM().format(p))),
          ],
          onChanged: (p) {
            if (p == null) return;
            setState(() => _period = p);
            _build();
          },
        ),
        const SizedBox(height: 16),
        if (r != null)
          Center(
            child: RepaintBoundary(
              key: _boundary,
              child: _RecapCard(recap: r, lines: _lines(r), photo: _photo),
            ),
          ),
        const SizedBox(height: 16),
        Text('Choose what to share', style: Theme.of(context).textTheme.titleSmall),
        Wrap(spacing: 8, children: [
          for (final s in RecapStat.values)
            FilterChip(
              label: Text(switch (s) {
                RecapStat.total => 'Total steps',
                RecapStat.average => 'Daily average',
                RecapStat.best => 'Best day',
                RecapStat.goalDays => 'Goal days',
                RecapStat.distance => 'Distance',
                RecapStat.streak => 'Longest streak',
                RecapStat.change => 'Change vs previous',
              }),
              selected: _selected.contains(s),
              onSelected: (v) => setState(() => v ? _selected.add(s) : _selected.remove(s)),
            ),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          OutlinedButton.icon(onPressed: _pickPhoto, icon: const Icon(Icons.add_photo_alternate_outlined), label: Text(_photo == null ? 'Add photo' : 'Change photo')),
          if (_photo != null) TextButton(onPressed: () => setState(() => _photo = null), child: const Text('Remove photo')),
        ]),
        const SizedBox(height: 8),
        FilledButton.icon(onPressed: r == null ? null : _share, icon: const Icon(Icons.share), label: const Text('Share image')),
        const SizedBox(height: 8),
        const Text('Only the stats you select are drawn on the image. Nothing is uploaded by StrideMate.'),
      ]),
    );
  }
}

class _RecapCard extends StatelessWidget {
  const _RecapCard({required this.recap, required this.lines, this.photo});
  final Recap recap;
  final List<(String, String)> lines;
  final File? photo;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 340,
      height: 440,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: SmColors.navy,
        borderRadius: BorderRadius.circular(28),
        image: photo == null
            ? null
            : DecorationImage(
                image: FileImage(photo!),
                fit: BoxFit.cover,
                colorFilter: ColorFilter.mode(SmColors.navy.withValues(alpha: 0.55), BlendMode.darken),
              ),
      ),
      padding: const EdgeInsets.all(24),
      child: DefaultTextStyle(
        style: const TextStyle(color: SmColors.ivory),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Image.asset('assets/branding/walker_mark.png', height: 36),
            const SizedBox(width: 10),
            const Text('StrideMate Recap', style: TextStyle(color: SmColors.mint, fontWeight: FontWeight.w700, fontSize: 16)),
          ]),
          const SizedBox(height: 16),
          Text(recap.title, style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w800, color: SmColors.ivory)),
          const Spacer(),
          for (final l in lines)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(children: [
                Expanded(child: Text(l.$1, style: const TextStyle(fontSize: 15, color: SmColors.ivory))),
                Text(l.$2, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800, color: SmColors.mint)),
              ]),
            ),
          const SizedBox(height: 8),
          const Text('Walk together with StrideMate', style: TextStyle(fontSize: 12, color: SmColors.ivory)),
        ]),
      ),
    );
  }
}
