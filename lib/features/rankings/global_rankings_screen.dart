import 'package:flutter/material.dart';

import '../../core/services.dart';
import '../../domain/countries.dart';
import '../../domain/day_key.dart';
import '../../widgets/ranking_list.dart';

/// Opt-in country and global rankings of real people. Each board for a date
/// uses every participant's own local calendar day.
class GlobalRankingsScreen extends StatefulWidget {
  const GlobalRankingsScreen({super.key});

  @override
  State<GlobalRankingsScreen> createState() => _GlobalRankingsScreenState();
}

class _GlobalRankingsScreenState extends State<GlobalRankingsScreen> {
  String _scope = 'GLOBAL';
  String _period = 'day';
  late PageLoader _loader = _make();

  PageLoader _make() {
    final scope = _scope;
    final period = _period;
    final date = dayKey(DateTime.now());
    return (afterRank, afterUser) =>
        services.api!.globalLeaderboard(scope, period, date, afterRank: afterRank, afterUser: afterUser);
  }

  @override
  Widget build(BuildContext context) {
    final profile = services.auth.profile;
    final optedIn = profile?['global_rankings_opt_in'] == true;
    final country = profile?['country_code'] as String?;
    return Scaffold(
      appBar: AppBar(title: const Text('Rankings')),
      body: Column(children: [
        if (!optedIn)
          Card(
            margin: const EdgeInsets.all(12),
            child: ListTile(
              leading: const Icon(Icons.visibility_off_outlined),
              title: const Text('You are not in these rankings'),
              subtitle: const Text('Turn on "Join country & global rankings" in Profile › Privacy to appear. You can browse either way.'),
            ),
          ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Wrap(spacing: 8, runSpacing: 8, children: [
            ChoiceChip(
              label: const Text('🌍 Global'),
              selected: _scope == 'GLOBAL',
              onSelected: (_) => setState(() {
                _scope = 'GLOBAL';
                _loader = _make();
              }),
            ),
            if (country != null)
              ChoiceChip(
                label: Text('${flagEmoji(country)} ${countryName(country)}'),
                selected: _scope == country,
                onSelected: (_) => setState(() {
                  _scope = country;
                  _loader = _make();
                }),
              ),
            const SizedBox(width: 12),
            for (final p in const [('day', 'Today'), ('week', 'Week'), ('month', 'Month')])
              ChoiceChip(
                label: Text(p.$2),
                selected: _period == p.$1,
                onSelected: (_) => setState(() {
                  _period = p.$1;
                  _loader = _make();
                }),
              ),
          ]),
        ),
        Expanded(child: RankingList(loader: _loader, emptyText: 'No opted-in walkers yet for this period.')),
      ]),
    );
  }
}
