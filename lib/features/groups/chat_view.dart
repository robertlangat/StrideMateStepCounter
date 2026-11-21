import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/services.dart';
import '../../data/remote/api.dart';
import '../../widgets/common.dart';

/// Group chat with realtime updates, quick cheers and (mutable) playful taunts.
class ChatView extends StatefulWidget {
  const ChatView({super.key, required this.group});
  final Map<String, dynamic> group;

  @override
  State<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends State<ChatView> {
  final _messages = <Map<String, dynamic>>[];
  final _input = TextEditingController();
  final _names = <String, String>{};
  RealtimeChannel? _channel;
  bool _loading = true;
  bool _sending = false;
  bool _hasMore = true;

  String get _groupId => widget.group['id'] as String;
  bool get _isAdmin => widget.group['role'] == 'owner' || widget.group['role'] == 'admin';

  @override
  void initState() {
    super.initState();
    _loadOlder();
    // RLS on messages is evaluated per subscriber, so blocked authors and muted
    // taunts are filtered server-side for realtime too.
    _channel = services.api!.subscribeToChat(_groupId, (row) async {
      if (_messages.any((m) => m['id'] == row['id'])) return;
      final uid = row['user_id'] as String?;
      if (uid != null && !_names.containsKey(uid)) await _resolveNames();
      if (!mounted) return;
      setState(() => _messages.insert(0, {...row, 'display_name': _names[uid] ?? 'Member'}));
    });
  }

  Future<void> _resolveNames() async {
    try {
      final rows = await services.api!.members(_groupId, limit: 200);
      for (final r in rows) {
        _names[r['user_id'] as String] = r['display_name'] as String;
      }
    } catch (_) {}
  }

  Future<void> _loadOlder() async {
    try {
      final before = _messages.isEmpty ? null : _messages.last['id'] as int;
      final rows = await services.api!.messages(_groupId, beforeId: before);
      for (final r in rows) {
        if (r['user_id'] != null) _names[r['user_id'] as String] = r['display_name'] as String;
      }
      if (!mounted) return;
      setState(() {
        _messages.addAll(rows);
        _hasMore = rows.length == 50;
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        showSnack(context, friendlyError(e));
      }
    }
  }

  @override
  void dispose() {
    if (_channel != null) services.api!.unsubscribe(_channel!);
    _input.dispose();
    super.dispose();
  }

  Future<void> _send({String? body, String? preset, String? target}) async {
    setState(() => _sending = true);
    try {
      await services.api!.sendMessage(_groupId, body: body, presetKey: preset, target: target);
      _input.clear();
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(e));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _openQuickActions() async {
    final presets = await services.api!.presets();
    final members = await services.api!.members(_groupId, limit: 200);
    final me = services.auth.userId;
    if (!mounted) return;
    String? target;
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Cheer or tease someone', style: Theme.of(ctx).textTheme.titleMedium),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                value: target,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Who?', border: OutlineInputBorder()),
                items: [
                  for (final m in members.where((m) => m['user_id'] != me && m['blocked_by_me'] != true))
                    DropdownMenuItem(value: m['user_id'] as String, child: Text(m['display_name'] as String)),
                ],
                onChanged: (v) => set(() => target = v),
              ),
              const SizedBox(height: 12),
              const Text('Cheers'),
              Wrap(spacing: 8, children: [
                for (final p in presets.where((p) => p['kind'] == 'cheer'))
                  ActionChip(
                    label: Text((p['body'] as String).replaceAll('{target}', '…')),
                    onPressed: target == null
                        ? null
                        : () {
                            Navigator.pop(ctx);
                            _send(preset: p['key'] as String, target: target);
                          },
                  ),
              ]),
              if (widget.group['taunts_enabled'] == true) ...[
                const SizedBox(height: 12),
                const Text('Playful taunts (members can mute these)'),
                Wrap(spacing: 8, children: [
                  for (final p in presets.where((p) => p['kind'] == 'taunt'))
                    ActionChip(
                      label: Text((p['body'] as String).replaceAll('{target}', '…')),
                      onPressed: target == null
                          ? null
                          : () {
                              Navigator.pop(ctx);
                              _send(preset: p['key'] as String, target: target);
                            },
                    ),
                ]),
              ],
            ]),
          ),
        ),
      ),
    );
  }

  Future<void> _messageActions(Map<String, dynamic> m) async {
    final mine = m['user_id'] == services.auth.userId;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (mine || _isAdmin)
            ListTile(leading: const Icon(Icons.delete_outline), title: const Text('Delete message'), onTap: () => Navigator.pop(ctx, 'delete')),
          if (!mine) ...[
            ListTile(leading: const Icon(Icons.flag_outlined), title: const Text('Report'), onTap: () => Navigator.pop(ctx, 'report')),
            ListTile(leading: const Icon(Icons.block), title: Text('Block ${m['display_name']}'), onTap: () => Navigator.pop(ctx, 'block')),
          ],
        ]),
      ),
    );
    if (action == null || !mounted) return;
    try {
      switch (action) {
        case 'delete':
          await services.api!.deleteMessage(m['id'] as int);
          setState(() => _messages.removeWhere((x) => x['id'] == m['id']));
        case 'report':
          final reason = await _askReason();
          if (reason == null) return;
          await services.api!.report(_groupId, messageId: m['id'] as int, reason: reason);
          if (mounted) showSnack(context, 'Thanks. The group admins will review it.');
        case 'block':
          await services.api!.blockUser(m['user_id'] as String, true);
          setState(() => _messages.removeWhere((x) => x['user_id'] == m['user_id']));
          if (mounted) showSnack(context, 'Blocked. You won\'t see their messages, cheers or taunts.');
      }
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(e));
    }
  }

  Future<String?> _askReason() {
    final c = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Report message'),
        content: TextField(controller: c, maxLength: 500, decoration: const InputDecoration(labelText: 'What\'s wrong?')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim().isEmpty ? 'Inappropriate' : c.text.trim()), child: const Text('Report')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.group['chat_enabled'] != true) {
      return const Center(child: Text('Chat is turned off in this group.'));
    }
    final me = services.auth.userId;
    final cs = Theme.of(context).colorScheme;
    return Column(children: [
      Expanded(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView.builder(
                reverse: true,
                itemCount: _messages.length + (_hasMore ? 1 : 0),
                itemBuilder: (context, i) {
                  if (i == _messages.length) {
                    return TextButton(onPressed: _loadOlder, child: const Text('Load earlier messages'));
                  }
                  final m = _messages[i];
                  final mine = m['user_id'] == me;
                  final kind = m['kind'] as String;
                  final time = DateFormat.jm().format(DateTime.parse(m['created_at'] as String).toLocal());
                  return GestureDetector(
                    onLongPress: () => _messageActions(m),
                    child: Align(
                      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
                      child: Container(
                        constraints: const BoxConstraints(maxWidth: 320),
                        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: kind == 'text'
                              ? (mine ? cs.primaryContainer : cs.surfaceContainerHighest)
                              : cs.tertiaryContainer,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          if (!mine) Text(m['display_name'] as String? ?? 'Member', style: const TextStyle(fontWeight: FontWeight.w700)),
                          Text('${kind == 'cheer' ? '👏 ' : kind == 'taunt' ? '😜 ' : ''}${m['body']}'),
                          Text(time, style: Theme.of(context).textTheme.labelSmall),
                        ]),
                      ),
                    ),
                  );
                },
              ),
      ),
      SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
          child: Row(children: [
            IconButton(tooltip: 'Cheers and taunts', icon: const Icon(Icons.celebration_outlined), onPressed: _openQuickActions),
            Expanded(
              child: TextField(
                controller: _input,
                minLines: 1,
                maxLines: 4,
                maxLength: 1000,
                buildCounter: (_, {required currentLength, required isFocused, maxLength}) => null,
                decoration: const InputDecoration(hintText: 'Message', border: OutlineInputBorder()),
              ),
            ),
            IconButton(
              tooltip: 'Send',
              icon: const Icon(Icons.send),
              onPressed: _sending
                  ? null
                  : () {
                      final t = _input.text.trim();
                      if (t.isNotEmpty) _send(body: t);
                    },
            ),
          ]),
        ),
      ),
    ]);
  }
}
