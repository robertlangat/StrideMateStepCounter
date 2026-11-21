import 'package:flutter/material.dart';

import '../../config/app_config.dart';
import '../../core/services.dart';
import '../../data/remote/api.dart';
import '../../widgets/common.dart';

/// Email one-time-code sign in. Accounts are free and only needed for sync,
/// groups, challenges and rankings.
class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _email = TextEditingController();
  final _code = TextEditingController();
  bool _sent = false;
  bool _busy = false;

  Future<void> _send() async {
    final email = _email.text.trim();
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)) {
      showSnack(context, 'Please enter a valid email address.');
      return;
    }
    setState(() => _busy = true);
    try {
      await services.auth.sendCode(email);
      setState(() => _sent = true);
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _verify() async {
    setState(() => _busy = true);
    try {
      await services.auth.verifyCode(_email.text, _code.text);
      await services.sync?.syncNow();
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Sign in')),
      body: ListView(padding: const EdgeInsets.all(24), children: [
        Text('Walk together', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8),
        const Text('Sign in with your email to back up your steps and join groups and challenges. '
            'We\'ll email you a 6-digit code — no password needed. StrideMate is free.'),
        const SizedBox(height: 24),
        TextField(
          controller: _email,
          enabled: !_sent,
          keyboardType: TextInputType.emailAddress,
          autofillHints: const [AutofillHints.email],
          decoration: const InputDecoration(labelText: 'Email', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 16),
        if (_sent) ...[
          TextField(
            controller: _code,
            keyboardType: TextInputType.number,
            autofillHints: const [AutofillHints.oneTimeCode],
            maxLength: 10,
            decoration: const InputDecoration(labelText: 'Code from the email', border: OutlineInputBorder()),
          ),
          FilledButton(onPressed: _busy ? null : _verify, child: const Text('Verify and sign in')),
          TextButton(onPressed: _busy ? null : () => setState(() => _sent = false), child: const Text('Use a different email')),
        ] else
          FilledButton(onPressed: _busy ? null : _send, child: const Text('Email me a code')),
        const SizedBox(height: 24),
        Text('By continuing you agree to the Terms (${AppConfig.termsUrl}) and Privacy Policy (${AppConfig.privacyUrl}).',
            style: Theme.of(context).textTheme.bodySmall),
      ]),
    );
  }
}
