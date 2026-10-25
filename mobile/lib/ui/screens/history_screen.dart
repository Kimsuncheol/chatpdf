import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/navigation/app_routes.dart';
import '../../data/models/conversation.dart';
import '../../data/repositories/document_repository.dart';
import '../../state/load_controller.dart';
import '../widgets/async_content.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key, required this.repository});
  final DocumentRepository repository;
  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  late final _controller = LoadController(widget.repository.conversations)
    ..refresh();
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Conversation history'),
      actions: [
        IconButton(
          onPressed: _controller.refresh,
          icon: const Icon(Icons.refresh),
          tooltip: 'Refresh history',
        ),
      ],
    ),
    body: AsyncContent<List<Conversation>>(
      controller: _controller,
      builder: (items) => items.isEmpty
          ? const Center(child: Text('Your conversations will appear here.'))
          : ListView.builder(
              itemCount: items.length,
              itemBuilder: (context, index) {
                final item = items[index];
                return ListTile(
                  leading: const Icon(Icons.chat_bubble_outline),
                  title: Text(item.title),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.push(
                    AppRoutes.chat(item.documentId, conversationId: item.id),
                  ),
                );
              },
            ),
    ),
  );
}
