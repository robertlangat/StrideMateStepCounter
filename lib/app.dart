import 'dart:async';

import 'package:flutter/material.dart';

import 'config/app_config.dart';
import 'core/services.dart';
import 'features/challenges/challenges_screen.dart';
import 'features/groups/groups_screen.dart';
import 'features/history/history_screen.dart';
import 'features/onboarding/onboarding_screen.dart';
import 'features/profile/profile_screen.dart';
import 'features/today/today_screen.dart';
import 'theme/app_theme.dart';

class StrideMateApp extends StatelessWidget {
  const StrideMateApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: services.settings,
      builder: (context, _) => MaterialApp(
        title: 'StrideMate',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: services.settings.themeMode,
        home: const _RootGate(),
      ),
    );
  }
}

/// Shows onboarding until it is completed, then the five-tab shell.
class _RootGate extends StatelessWidget {
  const _RootGate();

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: services.settings,
        builder: (context, _) => services.settings.onboarded ? const HomeShell() : const OnboardingScreen(),
      );
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  static final tabIndex = ValueNotifier<int>(0);
  static final pendingInviteCode = ValueNotifier<String?>(null);

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(services.steps.init());
    services.sync?.start();
    _listenForInvites();
  }

  Future<void> _listenForInvites() async {
    void handle(String? link) {
      if (link == null) return;
      final uri = Uri.tryParse(link);
      if (uri == null) return;
      final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
      final code = uri.scheme == 'stridemate' && uri.host == 'join'
          ? (segments.isNotEmpty ? segments.first : null)
          : (segments.length >= 2 && segments[segments.length - 2] == 'join' ? segments.last : null);
      if (code != null && AppConfig.backendConfigured) {
        HomeShell.pendingInviteCode.value = code.toUpperCase();
        HomeShell.tabIndex.value = 1;
      }
    }

    try {
      services.phone.onLink(handle);
      handle(await services.phone.initialLink());
    } catch (_) {}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(services.steps.refresh());
      unawaited(services.auth.onResume());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Groups and Challenges need the StrideMate server. In a build without
  /// SUPABASE_URL / SUPABASE_ANON_KEY they are left out entirely, and come back
  /// automatically in a build that has the backend configured.
  static final _tabs = <(Widget, NavigationDestination)>[
    (const TodayScreen(),
        const NavigationDestination(icon: Icon(Icons.directions_walk_outlined), selectedIcon: Icon(Icons.directions_walk), label: 'Today')),
    if (AppConfig.backendConfigured) ...[
      (const GroupsScreen(),
          const NavigationDestination(icon: Icon(Icons.groups_outlined), selectedIcon: Icon(Icons.groups), label: 'Groups')),
      (const ChallengesScreen(),
          const NavigationDestination(icon: Icon(Icons.emoji_events_outlined), selectedIcon: Icon(Icons.emoji_events), label: 'Challenges')),
    ],
    (const HistoryScreen(),
        const NavigationDestination(icon: Icon(Icons.bar_chart_outlined), selectedIcon: Icon(Icons.bar_chart), label: 'History')),
    (const ProfileScreen(),
        const NavigationDestination(icon: Icon(Icons.person_outline), selectedIcon: Icon(Icons.person), label: 'Profile')),
  ];

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: HomeShell.tabIndex,
      builder: (context, index, _) {
        final safeIndex = index.clamp(0, _tabs.length - 1);
        return Scaffold(
          body: IndexedStack(index: safeIndex, children: [for (final t in _tabs) t.$1]),
          bottomNavigationBar: NavigationBar(
            selectedIndex: safeIndex,
            onDestinationSelected: (i) => HomeShell.tabIndex.value = i,
            destinations: [for (final t in _tabs) t.$2],
          ),
        );
      },
    );
  }
}
