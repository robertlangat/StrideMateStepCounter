import 'package:flutter/material.dart';
import 'package:flutter_timezone/flutter_timezone.dart';

import '../../app.dart';
import '../../core/services.dart';
import '../../data/remote/api.dart';
import '../../widgets/common.dart';
import '../../widgets/time_zone_field.dart';
import '../profile/auth_screen.dart';
import 'group_detail_screen.dart';

class GroupsScreen extends StatefulWidget {
  const GroupsScreen({super.key});

  @override
  State<GroupsScreen> createState() => _GroupsScreenState();
}

class _GroupsScreenState extends State<GroupsScreen> {
  Future<List<Map<String, dynamic>>>? _future;

  @override
  void initState() {
    super.initState();
    services.auth.addListener(_onAuth);
    HomeShell.pendingInviteCode.addListener(_onInvite);
    _onAuth();
    WidgetsBinding.instance.addPostFrameCallback((_) => _onInvite());
  }

  @override
  void dispose() {
    services.auth.removeListener(_onAuth);
    HomeShell.pendingInviteCode.removeListener(_onInvite);
    super.dispose();
  }

  void _onAuth() {
    if (!mounted) return;
    setState(() => _future = services.auth.signedIn ? services.api!.myGroups() : null);
    _onInvite();
  }

  void _reload() => setState(() => _future = services.api!.myGroups());

  void _onInvite() {
    final code = HomeShell.pendingInviteCode.value;
    if (code == null || !mounted) return;
    if (!services.auth.signedIn) {
      showSnack(context, 'Sign in to join the group you were invited to.');
      return;
    }
    HomeShell.pendingInviteCode.value = null;
    _join(code);
  }

  Future<void> _join([String? prefilled]) async {
    final c = TextEditingController(text: prefilled ?? '');
    final code = prefilled ??
        await showDialog<String>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Join a group'),
            content: TextField(
              controller: c,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(labelText: 'Invite code'),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('Join')),
            ],
          ),
        );
    if (code == null || code.isEmpty) return;
    try {
      final id = await services.api!.joinGroup(code);
      _reload();
      if (!mounted) return;
      final groups = await services.api!.myGroups();
      final g = groups.firstWhere((x) => x['id'] == id, orElse: () => {'id': id, 'name': 'Group'});
      if (mounted) _open(g);
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(e));
    }
  }

  Future<void> _create() async {
    final deviceZone = await FlutterTimezone.getLocalTimezone();
    if (!mounted) return;
    final name = TextEditingController();
    final desc = TextEditingController();
    var tz = deviceZone;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: const Text('New private group'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: name, maxLength: 60, decoration: const InputDecoration(labelText: 'Group name')),
              TextField(controller: desc, maxLength: 280, decoration: const InputDecoration(labelText: 'Description (optional)')),
              const SizedBox(height: 8),
              TimeZoneField(value: tz, deviceZone: deviceZone, onChanged: (z) => set(() => tz = z)),
              const SizedBox(height: 8),
              const Text('Only people with an invite can join. Groups hold up to 15,000 members.'),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, name.text.trim().isNotEmpty), child: const Text('Create')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    try {
      final id = await services.api!.createGroup(name.text.trim(), desc.text.trim(), tz);
      _reload();
      _open({'id': id, 'name': name.text.trim(), 'role': 'owner', 'time_zone': tz});
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(e));
    }
  }

  void _open(Map<String, dynamic> g) => Navigator.of(context)
      .push(MaterialPageRoute(builder: (_) => GroupDetailScreen(groupId: g['id'] as String, initialName: g['name'] as String)))
      .then((_) => _reload());

  @override
  Widget build(BuildContext context) {
    if (!services.auth.signedIn) {
      return Scaffold(
        appBar: AppBar(title: const Text('Groups')),
        body: SignInPrompt(
          feature: 'Private groups for friends, family, coworkers and clubs',
          onSignIn: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AuthScreen())),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Groups'), actions: [
        TextButton.icon(onPressed: () => _join(), icon: const Icon(Icons.vpn_key_outlined), label: const Text('Join')),
      ]),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _create,
        icon: const Icon(Icons.add),
        label: const Text('New group'),
      ),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _future,
        builder: (context, snap) {
          if (snap.hasError) return ErrorRetry(message: friendlyError(snap.error!), onRetry: _reload);
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final groups = snap.data!;
          if (groups.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text('No groups yet. Create one and invite your people, or join with an invite code.',
                    textAlign: TextAlign.center),
              ),
            );
          }
          return RefreshIndicator(
            onRefresh: () async => _reload(),
            child: ListView.builder(
              padding: const EdgeInsets.only(bottom: 96),
              itemCount: groups.length,
              itemBuilder: (context, i) {
                final g = groups[i];
                return Card(
                  margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: ListTile(
                    leading: CircleAvatar(child: Text((g['name'] as String).characters.first.toUpperCase())),
                    title: Text(g['name'] as String),
                    subtitle: Text('${fmtInt(g['member_count'] as num)} members · ${g['role']}'
                        '${g['share_steps'] == false ? ' · your steps hidden here' : ''}'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _open(g),
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}
