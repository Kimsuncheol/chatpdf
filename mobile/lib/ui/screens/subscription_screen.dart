import 'package:flutter/material.dart';

import '../../data/models/entitlements.dart';
import '../../state/load_controller.dart';
import '../../state/session_controller.dart';
import '../widgets/async_content.dart';

class SubscriptionScreen extends StatefulWidget {
  const SubscriptionScreen({super.key, required this.session});
  final SessionController session;
  @override
  State<SubscriptionScreen> createState() => _SubscriptionScreenState();
}

class _SubscriptionScreenState extends State<SubscriptionScreen> {
  late final controller = LoadController(widget.session.loadEntitlements)
    ..refresh();
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Subscription')),
    body: AsyncContent<AccountEntitlements>(
      controller: controller,
      builder: (value) => ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            'Current plan: ${value.tier}',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 12),
          SubscriptionDetails(value: value),
          const Divider(height: 32),
          const Text(
            'Subscription preview — payments are not available',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          const Text(
            'Free plan: configured Gemma model.\nPaid plan: configured Kimi model while the subscription is active.\n\nThis preview cannot purchase, renew or change your plan. No payment will be collected and no access will be granted.',
          ),
          const SizedBox(height: 16),
          const FilledButton(
            onPressed: null,
            child: Text('Purchases coming later'),
          ),
          TextButton(
            onPressed: controller.refresh,
            child: const Text('Refresh subscription'),
          ),
        ],
      ),
    ),
  );
}

class SubscriptionDetails extends StatelessWidget {
  const SubscriptionDetails({super.key, required this.value});
  final AccountEntitlements value;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('Status: ${value.status}'),
      const SizedBox(height: 8),
      Text(
        value.expiresAt == null
            ? 'Expiration: not provided'
            : 'Expires: ${value.expiresAt!.toUtc().toIso8601String()} (UTC)',
      ),
      const SizedBox(height: 12),
      Text(
        value.chatAvailable && value.models.isNotEmpty
            ? 'Available model access: ${value.family ?? "configured model"}\n${value.models.join(", ")}'
            : value.unavailableReason == 'subscription_expired'
            ? 'Model access unavailable: your subscription has expired. Contact your account administrator to renew or switch to free.'
            : 'Model access is unavailable. The server has not enabled a model for this account.',
      ),
      const SizedBox(height: 8),
      const Text('Access is verified by the server for every chat request.'),
    ],
  );
}
