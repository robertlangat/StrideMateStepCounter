import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/services.dart';
import '../../data/remote/api.dart';
import '../../widgets/common.dart';
import '../../widgets/ranking_list.dart';
import '../challenges/challenge_detail_screen.dart';
import '../challenges/create_challenge_screen.dart';
import 'chat_view.dart';
import 'group_settings_screen.dart';
import 'invite_sheet.dart';
import 'members_view.dart';

class GroupDetailScreen extends StatefulWidget {
  const GroupDetailScreen({super.key, required this.groupId, required this.initialName});
  final String groupId;
  final String initialName;

  @override
  State<GroupDetailScreen> createState() => _GroupDetailScreenState();
}

class _GroupDetailScreenState extends State<GroupDetailScreen> {
  Map<String, dynamic>? _group;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final groups = await services.api!.myGroups();
      final g = groups.where((x) => x['id'] == widget.groupId).toList();
      if (!mounted) return;
      if (g.isEmpty) {
        Navigator.of(context).pop(); // no longer a member
        return;
      }
      setState(() => _group = g.first);
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(e));
    }
  }

  bool get _isAdmin => _group?['role'] == 'owner' || _group?['role'] == 'admin';

  @override
  Widget build(BuildContext context) {
    final g = _group;
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: Text(g?['name'] as String? ?? widget.initialName),
          actions: [
            if (_isAdmin)
              IconButton(
                tooltip: 'Invite people',
                icon: const Icon(Icons.person_add_alt),
                onPressed: () => showModalBottomSheet(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) => InviteSheet(groupId: widget.groupId, groupName: g?['name'] as String? ?? ''),
                ),
              ),
            IconButton(
              tooltip: 'Group settings',
              icon: const Icon(Icons.settings_outlined),
              onPressed: g == null
                  ? null
                  : () => Navigator.of(context)
                      .push(MaterialPageRoute(builder: (_) => GroupSettingsScreen(group: g)))
                      .then((_) => _load()),
            ),
          ],
          bottom: const TabBar(isScrollable: true, tabs: [
            Tab(text: 'Leaderboard'),
            Tab(text: 'Chat'),
            Tab(text: 'Members'),
            Tab(text: 'Challenges'),
          ]),
        ),
        body: g == null
            ? const Center(child: CircularProgressIndicator())
            : TabBarView(children: [
                _GroupLeaderboard(groupId: widget.groupId),
                ChatView(group: g),
                MembersView(groupId: widget.groupId, isAdmin: _isAdmin, myRole: g['role'] as String),
                _GroupChallenges(groupId: widget.groupId, isAdmin: _isAdmin, timeZone: g['time_zone'] as String),
              ]),
      ),
    );
  }
}

class _GroupLeaderboard extends StatefulWidget {
  const _GroupLeaderboard({required this.groupId});
  final String groupId;

  @override
  State<_GroupLeaderboard> createState() => _GroupLeaderboardState();
}

class _GroupLeaderboardState extends State<_GroupLeaderboard> {
  String _period = 'day';
  bool _previous = false;
  late PageLoader _loader = _makeLoader();

  PageLoader _makeLoader() {
    final period = _period;
    final previous = _previous;
    return (afterRank, afterUser) => services.api!.groupLeaderboard(widget.groupId, period,
        previous: previous, afterRank: afterRank, afterUser: afterUser);
  }

  void _select(String period, bool previous) => setState(() {
        _period = period;
        _previous = previous;
        _loader = _makeLoader();
      });

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
        child: Wrap(spacing: 8, children: [
          ChoiceChip(label: const Text('Today'), selected: _period == 'day' && !_previous, onSelected: (_) => _select('day', false)),
          ChoiceChip(label: const Text('Yesterday'), selected: _previous, onSelected: (_) => _select('day', true)),
          ChoiceChip(label: const Text('This week'), selected: _period == 'week', onSelected: (_) => _select('week', false)),
          ChoiceChip(label: const Text('This month'), selected: _period == 'month', onSelected: (_) => _select('month', false)),
        ]),
      ),
      Expanded(
        child: RankingList(
          loader: _loader,
          header: (context, meta) => Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              'Days end at midnight ${meta['time_zone']}. '
              '${meta['provisional'] == true ? 'Yesterday stays provisional for 48 h while late wearable data arrives. ' : ''}'
              'Updated ${meta['computed_at'] == null ? 'soon' : fmtAgo(DateTime.parse(meta['computed_at'] as String).toLocal())}.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ),
      ),
    ]);
  }
}

class _GroupChallenges extends StatefulWidget {
  const _GroupChallenges({required this.groupId, required this.isAdmin, required this.timeZone});
  final String groupId;
  final bool isAdmin;
  final String timeZone;

  @override
  State<_GroupChallenges> createState() => _GroupChallengesState();
}

class _GroupChallengesState extends State<_GroupChallenges> {
  late Future<List<Map<String, dynamic>>> _future = services.api!.groupChallenges(widget.groupId);

  void _reload() => setState(() => _future = services.api!.groupChallenges(widget.groupId));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: widget.isAdmin
          ? FloatingActionButton.extended(
              heroTag: 'new-challenge',
              icon: const Icon(Icons.add),
              label: const Text('New challenge'),
              onPressed: () => Navigator.of(context)
                  .push(MaterialPageRoute(
                      builder: (_) => CreateChallengeScreen(groupId: widget.groupId, groupTimeZone: widget.timeZone)))
                  .then((_) => _reload()),
            )
          : null,
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _future,
        builder: (context, snap) {
          if (snap.hasError) return ErrorRetry(message: friendlyError(snap.error!), onRetry: _reload);
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final list = snap.data!;
          if (list.isEmpty) {
            return Center(
                child: Padding(
              padding: const EdgeInsets.all(32),
              child: Text(widget.isAdmin ? 'Start a step challenge for this group.' : 'No challenges yet.',
                  textAlign: TextAlign.center),
            ));
          }
          return RefreshIndicator(
            onRefresh: () async => _reload(),
            child: ListView(padding: const EdgeInsets.only(bottom: 96), children: [
              for (final c in list) ChallengeTile(challenge: c, onChanged: _reload),
            ]),
          );
        },
      ),
    );
  }
}

class ChallengeTile extends StatelessWidget {
  const ChallengeTile({super.key, required this.challenge, this.onChanged, this.showGroup = false});
  final Map<String, dynamic> challenge;
  final VoidCallback? onChanged;
  final bool showGroup;

  @override
  Widget build(BuildContext context) {
    final c = challenge;
    final fmt = DateFormat.MMMd();
    final start = DateTime.parse(c['starts_on'] as String);
    final end = c['ends_on'] == null ? null : DateTime.parse(c['ends_on'] as String);
    final status = c['status'] as String;
    final joined = c['joined'] as bool? ?? true;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: ListTile(
        leading: Text(c['mystery_mode'] == true ? '🕵️' : '🏆', style: const TextStyle(fontSize: 28)),
        title: Text(c['name'] as String),
        subtitle: Text([
          if (showGroup) c['group_name'] as String,
          end == null ? 'From ${fmt.format(start)} · ongoing' : '${fmt.format(start)} – ${fmt.format(end)}',
          '${c['time_zone']}',
          switch (status) { 'final' => 'Final', 'provisional' => 'Ended · results provisional', 'upcoming' => 'Upcoming', _ => 'Active' },
          if (c['participant_count'] != null) '${fmtInt(c['participant_count'] as num)} walking',
        ].join(' · ')),
        trailing: joined
            ? const Icon(Icons.chevron_right)
            : status == 'final' || status == 'provisional'
                ? null
                : FilledButton.tonal(
                    onPressed: () async {
                      try {
                        await services.api!.joinChallenge(c['id'] as String);
                        onChanged?.call();
                      } catch (e) {
                        if (context.mounted) showSnack(context, friendlyError(e));
                      }
                    },
                    child: const Text('Join'),
                  ),
        onTap: () => Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => ChallengeDetailScreen(challengeId: c['id'] as String, title: c['name'] as String)))
            .then((_) => onChanged?.call()),
      ),
    );
  }
}
