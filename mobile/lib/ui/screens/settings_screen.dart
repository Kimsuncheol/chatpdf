import 'package:flutter/material.dart';

import '../../state/session_controller.dart';
import '../widgets/auth_feedback.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.session});
  final SessionController session;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Settings and subscription')),
    body: ListenableBuilder(
      listenable: session,
      builder: (context, _) => ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.person_outline),
            title: const Text('Account'),
            subtitle: Text(session.user?.email ?? ''),
          ),
          ListTile(
            leading: const Icon(Icons.workspace_premium_outlined),
            title: const Text('Subscription'),
            subtitle: Text(session.user?.subscription ?? 'Unknown'),
          ),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Your subscription and available AI models are managed by the server. Subscription purchases are not connected yet.',
            ),
          ),
          if (session.error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: AuthFeedback(message: session.error!),
            ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: OutlinedButton.icon(
              onPressed: session.busy ? null : session.signOut,
              icon: session.action == AuthAction.signOut
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.logout),
              label: Text(
                session.action == AuthAction.signOut
                    ? 'Signing out…'
                    : 'Sign out',
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
