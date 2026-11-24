import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/services.dart';
import '../../data/remote/api.dart';
import '../../widgets/common.dart';
import '../../widgets/ranking_list.dart';

class ChallengeDetailScreen extends StatefulWidget {
  const ChallengeDetailScreen({super.key, required this.challengeId, required this.title});
  final String challengeId;
  final String title;

  @override
  State<ChallengeDetailScreen> createState() => _ChallengeDetailScreenState();
}

class _ChallengeDetailScreenState extends State<ChallengeDetailScreen> {
  Map<String, dynamic>? _meta;
  bool _isAdmin = false;
  Timer? _clock;
  late final PageLoader _loader;
  final _listKey = GlobalKey<RankingListState>();

  @override
  void initState() {
    super.initState();
    _loader = (afterRank, afterUser) async {
      final page = await services.api!.challengeLeaderboard(widget.challengeId, afterRank: afterRank, afterUser: afterUser);
      if (mounted && afterRank == null) setState(() => _meta = page);
      return page;
    };
    _clock = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
    _checkAdmin();
  }

  Future<void> _checkAdmin() async {
    try {
      final mine = await services.api!.myChallenges();
      final c = mine.where((x) => x['id'] == widget.challengeId).toList();
      if (c.isEmpty) return;
      final groups = await services.api!.myGroups();
      final g = groups.where((x) => x['id'] == c.first['group_id']).toList();
      if (mounted && g.isNotEmpty) setState(() => _isAdmin = g.first['role'] == 'owner' || g.first['role'] == 'admin');
    } catch (_) {}
  }

  @override
  void dispose() {
    _clock?.cancel();
    super.dispose();
  }

  Future<void> _exportCsv() async {
    try {
      final csv = await services.api!.exportChallengeCsv(widget.challengeId);
      final dir = await getTemporaryDirectory();
      final safe = widget.title.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_');
      final file = File('${dir.path}/stridemate-$safe-${DateFormat('yyyyMMdd-HHmm').format(DateTime.now())}.csv');
      await file.writeAsString(csv);
      await Share.shareXFiles([XFile(file.path, mimeType: 'text/csv')], subject: '${widget.title} – StrideMate results');
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(e));
    }
  }

  String _countdown(String iso) {
    final d = DateTime.parse(iso).toLocal().difference(DateTime.now());
    if (d.isNegative) return 'any moment';
    return '${d.inHours}h ${d.inMinutes.remainder(60)}m';
  }

  @override
  Widget build(BuildContext context) {
    final m = _meta;
    return Scaffold(
      appBar: AppBar(title: Text(widget.title), actions: [
        if (_isAdmin)
          IconButton(tooltip: 'Export CSV', icon: const Icon(Icons.file_download_outlined), onPressed: _exportCsv),
        if (m != null && (m['me'] as Map)['joined'] == true && m['status'] != 'final')
          PopupMenuButton<String>(
            onSelected: (v) async {
              if (v == 'leave') {
                await services.api!.leaveChallenge(widget.challengeId);
                if (context.mounted) Navigator.of(context).pop();
              }
            },
            itemBuilder: (_) => const [PopupMenuItem(value: 'leave', child: Text('Leave challenge'))],
          ),
      ]),
      body: RankingList(
        key: _listKey,
        loader: _loader,
        header: (context, meta) {
          final me = (meta['me'] as Map).cast<String, dynamic>();
          final status = meta['status'] as String;
          final f = DateFormat.yMMMd();
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                '${f.format(DateTime.parse(meta['starts_on'] as String))} – '
                '${meta['ends_on'] == null ? 'ongoing' : f.format(DateTime.parse(meta['ends_on'] as String))} · '
                'scored in ${meta['time_zone']}',
              ),
              const SizedBox(height: 4),
              Text(switch (status) {
                'final' => 'Final results.',
                'provisional' =>
                  'Ended. Results are provisional until ${DateFormat.MMMd().add_jm().format(DateTime.parse(meta['final_at'] as String).toLocal())} while late uploads arrive.',
                'upcoming' => 'Starts soon.',
                _ => 'In progress.',
              }),
              if (meta['mystery_mode'] == true && meta['reveal_at'] != null)
                Card(
                  color: Theme.of(context).colorScheme.tertiaryContainer,
                  margin: const EdgeInsets.only(top: 12),
                  child: ListTile(
                    leading: const Text('🕵️', style: TextStyle(fontSize: 28)),
                    title: const Text('Mystery Mode'),
                    subtitle: Text('Today\'s steps are secret. Standings below include completed days only. '
                        'Today is revealed in ${_countdown(meta['reveal_at'] as String)}.'),
                  ),
                ),
              if (me['joined'] == true)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text('You: ${fmtInt(me['live_steps'] as num)} steps in this challenge '
                      '(${fmtInt(me['today_steps'] as num)} today).',
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                )
              else if (status == 'active' || status == 'upcoming')
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: FilledButton(
                    onPressed: () async {
                      try {
                        await services.api!.joinChallenge(widget.challengeId);
                        await _listKey.currentState?.reload();
                      } catch (e) {
                        if (context.mounted) showSnack(context, friendlyError(e));
                      }
                    },
                    child: const Text('Join this challenge'),
                  ),
                ),
            ]),
          );
        },
      ),
    );
  }
}
