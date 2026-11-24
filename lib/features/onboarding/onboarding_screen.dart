import 'package:flutter/material.dart';

import '../../core/services.dart';
import '../../data/sources/phone_source.dart';
import '../../theme/app_theme.dart';
import '../../widgets/common.dart';

/// Original onboarding copy. No account needed; permissions are requested only
/// when the user taps the button that needs them.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _pages = PageController();
  int _page = 0;
  double _goal = 8000;
  double _stride = 75;
  bool _busy = false;

  Future<void> _finish({required bool askPermission}) async {
    setState(() => _busy = true);
    services.settings.strideCm = _stride.round();
    await services.steps.setDailyGoal(_goal.round());
    if (askPermission) {
      final s = await services.phone.requestPermission();
      if (mounted && s != PhoneSensorState.ready) {
        showSnack(context, 'No problem — you can allow motion access later from the Today tab.');
      }
    }
    services.settings.onboarded = true; // _RootGate swaps to the home shell
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final pages = <Widget>[
      _Page(
        image: Image.asset('assets/branding/walker_mark.png', height: 160, semanticLabel: 'StrideMate walker'),
        title: 'Every step is better together',
        body: 'StrideMate counts your steps, cheers you on, and turns everyday walks into friendly '
            'challenges with the people you care about. Always free — no subscriptions, no paywalls.',
      ),
      _Page(
        image: const Icon(Icons.lock_outline, size: 120),
        title: 'Private by default',
        body: 'Start counting right away — no account needed. Your activity stays on this phone '
            'unless you sign in for sync, groups or challenges. StrideMate never asks for your location.',
      ),
      Padding(
        padding: const EdgeInsets.all(24),
        child: ListView(children: [
          Text('Set your daily goal', style: text.headlineSmall),
          const SizedBox(height: 8),
          Text('${fmtInt(_goal.round())} steps', style: text.displaySmall?.copyWith(fontWeight: FontWeight.w800)),
          Slider(
            value: _goal,
            min: 2000,
            max: 25000,
            divisions: 46,
            label: fmtInt(_goal.round()),
            semanticFormatterCallback: (v) => '${fmtInt(v.round())} steps',
            onChanged: (v) => setState(() => _goal = v),
          ),
          const SizedBox(height: 16),
          Text('Stride length', style: text.titleMedium),
          Text('Used to estimate distance. ${_stride.round()} cm', style: text.bodyMedium),
          Slider(
            value: _stride,
            min: 40,
            max: 120,
            divisions: 80,
            label: '${_stride.round()} cm',
            semanticFormatterCallback: (v) => '${v.round()} centimetres',
            onChanged: (v) => setState(() => _stride = v),
          ),
          const SizedBox(height: 24),
          Text('Motion access', style: text.titleMedium),
          const SizedBox(height: 4),
          const Text('To count steps with your phone, StrideMate needs permission to read physical '
              'activity. You can also connect Health Connect or Apple Health later to include your watch.'),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _busy ? null : () => _finish(askPermission: true),
            icon: const Icon(Icons.directions_walk),
            label: const Text('Allow motion access and start'),
          ),
          TextButton(
            onPressed: _busy ? null : () => _finish(askPermission: false),
            child: const Text('Not now'),
          ),
        ]),
      ),
    ];

    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: PageView(
              controller: _pages,
              onPageChanged: (i) => setState(() => _page = i),
              children: pages,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
            child: Row(children: [
              for (var i = 0; i < pages.length; i++)
                Container(
                  margin: const EdgeInsets.only(right: 6),
                  width: i == _page ? 22 : 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: i == _page ? SmColors.mintDark : Colors.grey.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              const Spacer(),
              if (_page < pages.length - 1)
                FilledButton(
                  onPressed: () => _pages.nextPage(duration: const Duration(milliseconds: 300), curve: Curves.easeOut),
                  child: const Text('Next'),
                ),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _Page extends StatelessWidget {
  const _Page({required this.image, required this.title, required this.body});
  final Widget image;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.all(32),
        children: [
          const SizedBox(height: 32),
          Center(child: image),
          const SizedBox(height: 32),
          Text(title, style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 12),
          Text(body, style: Theme.of(context).textTheme.bodyLarge),
        ],
      );
}
