import 'package:flutter/material.dart';

import '../domain/countries.dart';
import 'common.dart';

typedef PageLoader = Future<Map<String, dynamic>> Function(int? afterRank, String? afterUser);

/// Paginated leaderboard (keyset pages of 50) with the viewer's own row pinned
/// even when they are far outside the loaded page. Ties share a rank.
class RankingList extends StatefulWidget {
  const RankingList({super.key, required this.loader, this.header, this.emptyText = 'No one ranked yet.'});
  final PageLoader loader;
  final Widget Function(BuildContext, Map<String, dynamic>)? header;
  final String emptyText;

  @override
  State<RankingList> createState() => RankingListState();
}

class RankingListState extends State<RankingList> {
  final _rows = <Map<String, dynamic>>[];
  Map<String, dynamic>? _meta;
  bool _loading = false;
  bool _done = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    reload();
  }

  @override
  void didUpdateWidget(covariant RankingList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.loader != widget.loader) reload();
  }

  Future<void> reload() async {
    setState(() {
      _rows.clear();
      _done = false;
      _meta = null;
      _error = null;
    });
    await _more();
  }

  Future<void> _more() async {
    if (_loading || _done) return;
    setState(() => _loading = true);
    try {
      final last = _rows.isEmpty ? null : _rows.last;
      final page = await widget.loader(last?['rank'] as int?, last?['user_id'] as String?);
      final rows = (page['rows'] as List).cast<Map<String, dynamic>>();
      if (!mounted) return;
      setState(() {
        _meta = page;
        _rows.addAll(rows);
        _done = rows.length < 50;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null && _rows.isEmpty) {
      return ErrorRetry(message: friendlyErrorText(_error!), onRetry: reload);
    }
    final meta = _meta;
    final me = (meta?['me'] as Map?)?.cast<String, dynamic>();
    final total = meta?['total_ranked'] as int? ?? 0;
    return RefreshIndicator(
      onRefresh: reload,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: _rows.length + 3,
        itemBuilder: (context, i) {
          if (i == 0) {
            return Column(children: [
              if (meta != null && widget.header != null) widget.header!(context, meta),
              if (me != null) _MeRow(me: me, total: total),
              if (meta != null && _rows.isEmpty && !_loading)
                Padding(padding: const EdgeInsets.all(32), child: Text(widget.emptyText)),
            ]);
          }
          if (i == _rows.length + 1) {
            if (_done) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.all(16),
              child: Center(
                child: _loading
                    ? const CircularProgressIndicator()
                    : OutlinedButton(onPressed: _more, child: const Text('Load more')),
              ),
            );
          }
          if (i == _rows.length + 2) {
            return const Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 24),
              child: Text('Equal step totals share a rank (1, 2, 2, 4). Members who keep their steps private are not listed.',
                  style: TextStyle(fontSize: 12)),
            );
          }
          final r = _rows[i - 1];
          final isMe = r['is_me'] == true;
          final country = r['country_code'] as String?;
          return Semantics(
            label: 'Rank ${r['rank']}, ${r['display_name']}${isMe ? ' (you)' : ''}, ${fmtInt(r['steps'] as num)} steps',
            excludeSemantics: true,
            child: ListTile(
              tileColor: isMe ? Theme.of(context).colorScheme.secondaryContainer : null,
              leading: SizedBox(
                width: 44,
                child: Text('#${r['rank']}', style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
              title: Text('${country != null ? '${flagEmoji(country)} ' : ''}${r['display_name']}${isMe ? ' (you)' : ''}'),
              trailing: Text(fmtInt(r['steps'] as num), style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
          );
        },
      ),
    );
  }
}

class _MeRow extends StatelessWidget {
  const _MeRow({required this.me, required this.total});
  final Map<String, dynamic> me;
  final int total;

  @override
  Widget build(BuildContext context) {
    final rank = me['rank'];
    final live = me['live_steps'] ?? me['steps'];
    final board = me['board_steps'];
    final String text;
    if (rank == null) {
      text = me['ranked'] == false || me['visible'] == false
          ? 'You are not ranked because your steps are hidden from this group.'
          : 'You are not ranked here yet.';
    } else {
      text = 'You are #$rank of ${fmtInt(total)}';
    }
    return Card(
      margin: const EdgeInsets.all(12),
      color: Theme.of(context).colorScheme.primaryContainer,
      child: ListTile(
        leading: const Icon(Icons.person_pin_circle_outlined),
        title: Text(text, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: live == null
            ? null
            : Text('Your total: ${fmtInt(live as num)} steps'
                '${board != null && board != live ? ' · others currently see ${fmtInt(board as num)}' : ''}'),
      ),
    );
  }
}

String friendlyErrorText(Object e) {
  final s = e.toString();
  return s.length > 200 ? '${s.substring(0, 200)}…' : s;
}
