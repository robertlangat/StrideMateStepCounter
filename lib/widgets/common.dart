import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/services.dart';
import '../domain/step_math.dart';

final _int = NumberFormat.decimalPattern();
String fmtInt(num n) => _int.format(n);

String fmtDistance(int steps) {
  final km = distanceKm(steps, services.settings.strideCm);
  return services.settings.imperial ? '${kmToMiles(km).toStringAsFixed(2)} mi' : '${km.toStringAsFixed(2)} km';
}

String fmtKcal(int steps) => '~${estimatedKcal(steps, services.settings.strideCm, services.settings.weightKg).round()} kcal';

String fmtAgo(DateTime? t) {
  if (t == null) return 'never';
  final d = DateTime.now().difference(t);
  if (d.inSeconds < 60) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  if (d.inHours < 24) return '${d.inHours} h ago';
  return DateFormat.MMMd().add_jm().format(t);
}

void showSnack(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

/// Explains why a data source is unavailable and what to do about it.
class StatusBanner extends StatelessWidget {
  const StatusBanner({super.key, required this.icon, required this.title, required this.body, this.actionLabel, this.onAction});
  final IconData icon;
  final String title;
  final String body;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      color: cs.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: cs.onTertiaryContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: TextStyle(fontWeight: FontWeight.w700, color: cs.onTertiaryContainer)),
                  const SizedBox(height: 4),
                  Text(body, style: TextStyle(color: cs.onTertiaryContainer)),
                  if (actionLabel != null)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(onPressed: onAction, child: Text(actionLabel!)),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shown when a feature needs an account or a configured backend.
class SignInPrompt extends StatelessWidget {
  const SignInPrompt({super.key, required this.feature, required this.onSignIn});
  final String feature;
  final VoidCallback onSignIn;

  @override
  Widget build(BuildContext context) {
    final configured = services.auth.available;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.groups_2_outlined, size: 64),
            const SizedBox(height: 16),
            Text(feature, style: Theme.of(context).textTheme.titleLarge, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(
              configured
                  ? 'Create a free account to walk with friends. Step counting keeps working without one.'
                  : 'Social features need a StrideMate server. This build has no backend configured '
                      '(SUPABASE_URL / SUPABASE_ANON_KEY).',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            if (configured) FilledButton(onPressed: onSignIn, child: const Text('Sign in or create account')),
          ],
        ),
      ),
    );
  }
}

class ErrorRetry extends StatelessWidget {
  const ErrorRetry({super.key, required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: onRetry, child: const Text('Try again')),
          ]),
        ),
      );
}
