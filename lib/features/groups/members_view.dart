import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/services.dart';
import '../../data/remote/api.dart';
import '../../widgets/common.dart';

/// Paginated, searchable member list (works for 15,000-member groups).
class MembersView extends StatefulWidget {
  const MembersView({super.key, required this.groupId, required this.isAdmin, required this.myRole});
  final String groupId;
  final bool isAdmin;
  final String myRole;

  @override
  State<MembersView> createState() => _MembersViewState();
}

class _MembersViewState extends State<MembersView> {
  final _rows = <Map<String, dynamic>>[];
  String _search = '';
  bool _loading = false;
  bool _done = false;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _more();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _reset() async {
    setState(() {
      _rows.clear();
      _done = false;
    });
    await _more();
  }

  Future<void> _more() async {
    if (_loading || _done) return;
    setState(() => _loading = true);
    try {
      final last = _rows.isEmpty ? null : _rows.last;
      final page = await services.api!.members(widget.groupId,
          afterJoined: last?['joined_at'] as String?, afterUser: last?['user_id'] as String?, search: _search);
      if (!mounted) return;
      setState(() {
        _rows.addAll(page);
        _done = page.length < 50;
      });
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _actions(Map<String, dynamic> m) async {
    final me = services.auth.userId;
    final uid = m['user_id'] as String;
    if (uid == me) return;
    final role = m['role'] as String;
    final canModerate = widget.isAdmin && role != 'owner' && (widget.myRole == 'owner' || role == 'member');
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(title: Text(m['display_name'] as String), subtitle: Text(role)),
          if (widget.myRole == 'owner' && role == 'member')
            ListTile(leading: const Icon(Icons.shield_outlined), title: const Text('Make admin'), onTap: () => Navigator.pop(ctx, 'admin')),
          if (widget.myRole == 'owner' && role == 'admin')
            ListTile(leading: const Icon(Icons.remove_moderator_outlined), title: const Text('Remove admin role'), onTap: () => Navigator.pop(ctx, 'member')),
          if (widget.myRole == 'owner')
            ListTile(leading: const Icon(Icons.workspace_premium_outlined), title: const Text('Transfer ownership'), onTap: () => Navigator.pop(ctx, 'owner')),
          if (canModerate) ...[
            ListTile(leading: const Icon(Icons.volume_off_outlined), title: const Text('Mute in chat for 24 h'), onTap: () => Navigator.pop(ctx, 'mute')),
            ListTile(leading: const Icon(Icons.volume_up_outlined), title: const Text('Unmute'), onTap: () => Navigator.pop(ctx, 'unmute')),
            ListTile(leading: const Icon(Icons.person_remove_outlined), title: const Text('Remove from group'), onTap: () => Navigator.pop(ctx, 'remove')),
          ],
          ListTile(
            leading: const Icon(Icons.block),
            title: Text(m['blocked_by_me'] == true ? 'Unblock' : 'Block'),
            onTap: () => Navigator.pop(ctx, m['blocked_by_me'] == true ? 'unblock' : 'block'),
          ),
          ListTile(leading: const Icon(Icons.flag_outlined), title: const Text('Report to group admins'), onTap: () => Navigator.pop(ctx, 'report')),
        ]),
      ),
    );
    if (action == null) return;
    final api = services.api!;
    try {
      switch (action) {
        case 'admin' || 'member' || 'owner':
          await api.setRole(widget.groupId, uid, action);
        case 'mute':
          await api.muteMember(widget.groupId, uid, 24 * 60);
        case 'unmute':
          await api.muteMember(widget.groupId, uid, 0);
        case 'remove':
          await api.removeMember(widget.groupId, uid);
        case 'block':
          await api.blockUser(uid, true);
        case 'unblock':
          await api.blockUser(uid, false);
        case 'report':
          await api.report(widget.groupId, userId: uid, reason: 'Reported from member list');
      }
      if (mounted) showSnack(context, 'Done.');
      await _reset();
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Padding(
        padding: const EdgeInsets.all(12),
        child: TextField(
          decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search members', border: OutlineInputBorder()),
          onChanged: (v) {
            _debounce?.cancel();
            _debounce = Timer(const Duration(milliseconds: 400), () {
              _search = v.trim();
              _reset();
            });
          },
        ),
      ),
      Expanded(
        child: NotificationListener<ScrollNotification>(
          onNotification: (n) {
            if (n.metrics.pixels > n.metrics.maxScrollExtent - 400) _more();
            return false;
          },
          child: ListView.builder(
            itemCount: _rows.length + 1,
            itemBuilder: (context, i) {
              if (i == _rows.length) {
                return _loading
                    ? const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()))
                    : const SizedBox(height: 32);
              }
              final m = _rows[i];
              final muted = m['chat_muted_until'] != null && DateTime.parse(m['chat_muted_until'] as String).isAfter(DateTime.now());
              return ListTile(
                leading: CircleAvatar(child: Text((m['avatar_emoji'] as String?) ?? (m['display_name'] as String).characters.first)),
                title: Text(m['display_name'] as String),
                subtitle: Text([
                  m['role'] as String,
                  if (muted) 'muted',
                  if (m['blocked_by_me'] == true) 'blocked',
                ].join(' · ')),
                onTap: () => _actions(m),
              );
            },
          ),
        ),
      ),
    ]);
  }
}
