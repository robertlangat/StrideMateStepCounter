import 'package:flutter/material.dart';

import '../../core/services.dart';
import '../../data/remote/api.dart';
import '../../widgets/common.dart';
import '../groups/group_detail_screen.dart';
import '../profile/auth_screen.dart';
import '../rankings/global_rankings_screen.dart';

class ChallengesScreen extends StatefulWidget {
  const ChallengesScreen({super.key});

  @override
  State<ChallengesScreen> createState() => _ChallengesScreenState();
}

class _ChallengesScreenState extends State<ChallengesScreen> {
  Future<List<Map<String, dynamic>>>? _future;

  @override
  void initState() {
    super.initState();
    services.auth.addListener(_reload);
    _reload();
  }

  @override
  void dispose() {
    services.auth.removeListener(_reload);
    super.dispose();
  }

  void _reload() {
    if (!mounted) return;
    setState(() => _future = services.auth.signedIn ? services.api!.myChallenges() : null);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Challenges')),
      body: ListView(padding: const EdgeInsets.only(bottom: 32), children: [
        Card(
          margin: const EdgeInsets.all(16),
          child: ListTile(
            leading: const Text('🌍', style: TextStyle(fontSize: 28)),
            title: const Text('Country & global rankings'),
            subtitle: const Text('Opt-in rankings of real walkers.'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => services.auth.signedIn
                ? Navigator.of(context).push(MaterialPageRoute(builder: (_) => const GlobalRankingsScreen()))
                : Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AuthScreen())),
          ),
        ),
        const SizedBox(height: 8),
        if (!services.auth.signedIn)
          SizedBox(
            height: 360,
            child: SignInPrompt(
              feature: 'Step challenges with your groups',
              onSignIn: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AuthScreen())),
            ),
          )
        else
          FutureBuilder<List<Map<String, dynamic>>>(
            future: _future,
            builder: (context, snap) {
              if (snap.hasError) return ErrorRetry(message: friendlyError(snap.error!), onRetry: _reload);
              if (!snap.hasData) return const Padding(padding: EdgeInsets.all(48), child: Center(child: CircularProgressIndicator()));
              if (snap.data!.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.all(32),
                  child: Text('You are not in any challenges yet. Group admins can start one from a group\'s Challenges tab.',
                      textAlign: TextAlign.center),
                );
              }
              return Column(children: [
                for (final c in snap.data!) ChallengeTile(challenge: c, onChanged: _reload, showGroup: true),
              ]);
            },
          ),
      ]),
    );
  }
}
