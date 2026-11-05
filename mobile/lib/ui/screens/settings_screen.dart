import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../data/models/entitlements.dart';
import '../../state/load_controller.dart';
import 'subscription_screen.dart';

import '../../state/session_controller.dart';
import '../widgets/auth_feedback.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.session});
  final SessionController session;
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with WidgetsBindingObserver {
  SessionController get session => widget.session;
  late final LoadController<AccountEntitlements> controller = LoadController(
    session.loadEntitlements,
  )..refresh();
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) controller.refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Settings and subscription'),
      actions: [
        IconButton(
          tooltip: 'Refresh subscription',
          onPressed: controller.refresh,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: ListenableBuilder(
      listenable: Listenable.merge([session, controller]),
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
            subtitle: Text(
              controller.data?.tier ?? session.user?.subscription ?? 'Unknown',
            ),
            onTap: () => context.push('/settings/subscription'),
            trailing: const Icon(Icons.chevron_right),
          ),
          if (controller.loading) const LinearProgressIndicator(),
          if (controller.error != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Text(controller.error!),
                  const Text(
                    'Displayed account tier may be from sign-in. Current model access could not be verified.',
                  ),
                  TextButton(
                    onPressed: controller.refresh,
                    child: const Text('Retry subscription details'),
                  ),
                ],
              ),
            ),
          if (!controller.loading &&
              controller.error == null &&
              controller.data != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: SubscriptionDetails(value: controller.data!),
            ),
          ListTile(
            leading: const Icon(Icons.privacy_tip_outlined),
            title: const Text('Privacy and data deletion'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/settings/privacy'),
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
