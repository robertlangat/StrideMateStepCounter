import 'package:flutter/material.dart';

import '../../core/services.dart';
import '../../data/remote/api.dart';
import '../../widgets/common.dart';

class GroupSettingsScreen extends StatefulWidget {
  const GroupSettingsScreen({super.key, required this.group});
  final Map<String, dynamic> group;

  @override
  State<GroupSettingsScreen> createState() => _GroupSettingsScreenState();
}

class _GroupSettingsScreenState extends State<GroupSettingsScreen> {
  late Map<String, dynamic> g = {...widget.group};

  String get _id => g['id'] as String;
  bool get _isAdmin => g['role'] == 'owner' || g['role'] == 'admin';

  Future<void> _run(Future<void> Function() action, void Function() apply) async {
    try {
      await action();
      setState(apply);
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final api = services.api!;
    return Scaffold(
      appBar: AppBar(title: const Text('Group settings')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text('Your privacy in this group', style: Theme.of(context).textTheme.titleSmall),
        Card(
          child: Column(children: [
            SwitchListTile(
              title: const Text('Share my step totals here'),
              subtitle: const Text('When off, you are left out of this group\'s leaderboards, challenge standings '
                  'and CSV exports. Your other groups are not affected.'),
              value: g['share_steps'] == true,
              onChanged: (v) => _run(() => api.setMembershipPrefs(_id, shareSteps: v), () => g['share_steps'] = v),
            ),
            SwitchListTile(
              title: const Text('Mute taunts'),
              subtitle: const Text('Hide playful taunts in this group and stop others sending them to you.'),
              value: g['taunts_muted'] == true,
              onChanged: (v) => _run(() => api.setMembershipPrefs(_id, tauntsMuted: v), () => g['taunts_muted'] = v),
            ),
          ]),
        ),
        if (_isAdmin) ...[
          const SizedBox(height: 16),
          Text('Admin', style: Theme.of(context).textTheme.titleSmall),
          Card(
            child: Column(children: [
              SwitchListTile(
                title: const Text('Group chat'),
                value: g['chat_enabled'] == true,
                onChanged: (v) => _run(() => api.updateGroup(_id, chatEnabled: v), () => g['chat_enabled'] = v),
              ),
              SwitchListTile(
                title: const Text('Allow playful taunts'),
                value: g['taunts_enabled'] == true,
                onChanged: (v) => _run(() => api.updateGroup(_id, tauntsEnabled: v), () => g['taunts_enabled'] = v),
              ),
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Rename group'),
                onTap: () async {
                  final c = TextEditingController(text: g['name'] as String);
                  final name = await showDialog<String>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('Group name'),
                      content: TextField(controller: c, maxLength: 60),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
                        FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('Save')),
                      ],
                    ),
                  );
                  if (name != null && name.isNotEmpty) await _run(() => api.updateGroup(_id, name: name), () => g['name'] = name);
                },
              ),
              ListTile(
                leading: const Icon(Icons.flag_outlined),
                title: const Text('Reports'),
                subtitle: const Text('Review reported messages and members'),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ReportsScreen(groupId: _id))),
              ),
            ]),
          ),
        ],
        const SizedBox(height: 16),
        Card(
          child: ListTile(
            leading: Icon(Icons.exit_to_app, color: Theme.of(context).colorScheme.error),
            title: const Text('Leave group'),
            subtitle: Text(g['role'] == 'owner'
                ? 'Ownership passes to the longest-standing admin (or member). If you are the last member, the group is deleted.'
                : 'You can rejoin later with a new invite.'),
            onTap: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: Text('Leave ${g['name']}?'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                    FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Leave')),
                  ],
                ),
              );
              if (ok != true) return;
              try {
                await api.leaveGroup(_id);
                if (context.mounted) Navigator.of(context).popUntil((r) => r.isFirst);
              } catch (e) {
                if (context.mounted) showSnack(context, friendlyError(e));
              }
            },
          ),
        ),
      ]),
    );
  }
}

class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key, required this.groupId});
  final String groupId;

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  late Future<List<Map<String, dynamic>>> _future = services.api!.reports(widget.groupId);

  void _reload() => setState(() => _future = services.api!.reports(widget.groupId));

  Future<void> _act(Map<String, dynamic> r, String action) async {
    final api = services.api!;
    try {
      if (action == 'delete' && r['message_id'] != null) await api.deleteMessage(r['message_id'] as int);
      if (action == 'remove' && r['reported_user_id'] != null) {
        await api.removeMember(widget.groupId, r['reported_user_id'] as String);
      }
      if (action == 'mute' && r['reported_user_id'] != null) {
        await api.muteMember(widget.groupId, r['reported_user_id'] as String, 24 * 60);
      }
      await api.resolveReport(r['id'] as int, action == 'dismiss' ? 'dismissed' : 'actioned');
      _reload();
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(e));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Reports')),
        body: FutureBuilder<List<Map<String, dynamic>>>(
          future: _future,
          builder: (context, snap) {
            if (snap.hasError) return ErrorRetry(message: friendlyError(snap.error!), onRetry: _reload);
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            if (snap.data!.isEmpty) return const Center(child: Text('No open reports.'));
            return ListView(children: [
              for (final r in snap.data!)
                Card(
                  margin: const EdgeInsets.all(12),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('About ${r['reported_name'] ?? 'a member'} · by ${r['reporter_name'] ?? 'a member'}',
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                      if (r['message_body'] != null) Text('"${r['message_body']}"'),
                      Text('Reason: ${r['reason']}'),
                      Wrap(spacing: 8, children: [
                        if (r['message_id'] != null)
                          TextButton(onPressed: () => _act(r, 'delete'), child: const Text('Delete message')),
                        TextButton(onPressed: () => _act(r, 'mute'), child: const Text('Mute 24 h')),
                        TextButton(onPressed: () => _act(r, 'remove'), child: const Text('Remove member')),
                        TextButton(onPressed: () => _act(r, 'dismiss'), child: const Text('Dismiss')),
                      ]),
                    ]),
                  ),
                ),
            ]);
          },
        ),
      );
}
