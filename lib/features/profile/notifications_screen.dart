import 'package:flutter/material.dart';

import '../../core/services.dart';
import '../../data/remote/api.dart';
import '../../widgets/common.dart';

/// In-app notification inbox (cheers, taunts, daily challenge results).
/// Push delivery (FCM/APNs) needs platform credentials — see docs/HANDOVER.md.
class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  late Future<List<Map<String, dynamic>>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<Map<String, dynamic>>> _load() async {
    final rows = await services.api!.notifications();
    await services.api!.markNotificationsRead();
    return rows;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Notifications')),
        body: FutureBuilder<List<Map<String, dynamic>>>(
          future: _future,
          builder: (context, snap) {
            if (snap.hasError) {
              return ErrorRetry(message: friendlyError(snap.error!), onRetry: () => setState(() => _future = _load()));
            }
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            final rows = snap.data!;
            if (rows.isEmpty) return const Center(child: Text('Nothing yet. Cheers and challenge results show up here.'));
            return ListView.separated(
              itemCount: rows.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final n = rows[i];
                return ListTile(
                  leading: Text(switch (n['kind']) { 'cheer' => '👏', 'taunt' => '😜', 'challenge_day' => '🏆', _ => '🔔' },
                      style: const TextStyle(fontSize: 24)),
                  title: Text(n['title'] as String),
                  subtitle: Text('${n['body']}\n${fmtAgo(DateTime.parse(n['created_at'] as String).toLocal())}'),
                  isThreeLine: true,
                );
              },
            );
          },
        ),
      );
}
