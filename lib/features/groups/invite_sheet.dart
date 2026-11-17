import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import '../../config/app_config.dart';
import '../../core/services.dart';
import '../../data/remote/api.dart';
import '../../widgets/common.dart';

/// Owners/admins create expiring, optionally single-use invite codes and links,
/// and can revoke them at any time.
class InviteSheet extends StatefulWidget {
  const InviteSheet({super.key, required this.groupId, required this.groupName});
  final String groupId;
  final String groupName;

  @override
  State<InviteSheet> createState() => _InviteSheetState();
}

class _InviteSheetState extends State<InviteSheet> {
  int _hours = 168;
  int? _maxUses;
  late Future<List<Map<String, dynamic>>> _invites = services.api!.invites(widget.groupId);

  String _link(String code) => '${AppConfig.inviteBaseUrl}/$code';

  Future<void> _create() async {
    try {
      final inv = await services.api!.createInvite(widget.groupId, _hours, _maxUses);
      final code = inv['code'] as String;
      setState(() => _invites = services.api!.invites(widget.groupId));
      await Share.share(
        'Walk with me on StrideMate! Join "${widget.groupName}" with code $code\n'
        '${_link(code)}\n(or open stridemate://join/$code)',
        subject: 'Join my StrideMate group',
      );
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Invite people', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: DropdownButtonFormField<int>(
                value: _hours,
                decoration: const InputDecoration(labelText: 'Expires after', border: OutlineInputBorder()),
                items: const [
                  DropdownMenuItem(value: 24, child: Text('1 day')),
                  DropdownMenuItem(value: 168, child: Text('7 days')),
                  DropdownMenuItem(value: 720, child: Text('30 days')),
                ],
                onChanged: (v) => setState(() => _hours = v ?? 168),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: DropdownButtonFormField<int?>(
                value: _maxUses,
                decoration: const InputDecoration(labelText: 'Uses', border: OutlineInputBorder()),
                items: const [
                  DropdownMenuItem(value: null, child: Text('Unlimited')),
                  DropdownMenuItem(value: 1, child: Text('1 person')),
                  DropdownMenuItem(value: 10, child: Text('10 people')),
                  DropdownMenuItem(value: 100, child: Text('100 people')),
                ],
                onChanged: (v) => setState(() => _maxUses = v),
              ),
            ),
          ]),
          const SizedBox(height: 12),
          FilledButton.icon(onPressed: _create, icon: const Icon(Icons.share), label: const Text('Create and share invite')),
          const SizedBox(height: 16),
          Text('Active invites', style: Theme.of(context).textTheme.titleSmall),
          FutureBuilder<List<Map<String, dynamic>>>(
            future: _invites,
            builder: (context, snap) {
              if (!snap.hasData) return const LinearProgressIndicator();
              if (snap.data!.isEmpty) return const Padding(padding: EdgeInsets.all(8), child: Text('None'));
              return ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 260),
                child: ListView(shrinkWrap: true, children: [
                  for (final inv in snap.data!)
                    ListTile(
                      title: SelectableText(inv['code'] as String, style: const TextStyle(fontFamily: 'monospace', fontSize: 18)),
                      subtitle: Text('Expires ${DateFormat.MMMd().add_jm().format(DateTime.parse(inv['expires_at'] as String).toLocal())}'
                          ' · used ${inv['uses']}${inv['max_uses'] == null ? '' : '/${inv['max_uses']}'}'),
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        IconButton(
                          tooltip: 'Copy link',
                          icon: const Icon(Icons.copy),
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: _link(inv['code'] as String)));
                            showSnack(context, 'Invite link copied');
                          },
                        ),
                        IconButton(
                          tooltip: 'Revoke',
                          icon: const Icon(Icons.link_off),
                          onPressed: () async {
                            await services.api!.revokeInvite(inv['code'] as String);
                            setState(() => _invites = services.api!.invites(widget.groupId));
                          },
                        ),
                      ]),
                    ),
                ]),
              );
            },
          ),
        ]),
      ),
    );
  }
}
