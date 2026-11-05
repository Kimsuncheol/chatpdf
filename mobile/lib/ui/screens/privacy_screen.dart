import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class PrivacyScreen extends StatelessWidget {
  const PrivacyScreen({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Privacy and data')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          'Your documents and chats',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 12),
        const Text(
          'PDFs, extracted text, indexes and chat history are stored by the ChatPDF server. Retrieved text and questions are sent to the configured embedding and chat providers. Processing may take place on another service, depending on the deployment.\n\nAuthentication tokens use secure platform storage. Signing out removes this device’s saved session; it does not delete server data.',
        ),
        const Divider(height: 32),
        const Text(
          'Delete a document',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        const Text(
          'Open your library and choose Delete on a document. You will be asked to confirm. Deletion removes its stored PDF, extracted content, index and associated conversations from active storage. Backups follow the server’s retention policy.',
        ),
        TextButton(
          onPressed: () => context.go('/'),
          child: const Text('Open document library'),
        ),
        const Divider(height: 32),
        const Text(
          'Delete your account',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        const Text(
          'Self-service account deletion is not available yet. Contact the administrator who provided your account to request deletion. No deletion request is submitted by opening this screen.',
        ),
        const SizedBox(height: 12),
        const OutlinedButton(
          onPressed: null,
          child: Text('Account deletion coming later'),
        ),
      ],
    ),
  );
}
