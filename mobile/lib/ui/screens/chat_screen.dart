import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../data/repositories/document_repository.dart';
import '../../state/chat_controller.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    required this.repository,
    required this.documentId,
    this.conversationId,
  });
  final DocumentRepository repository;
  final String documentId;
  final String? conversationId;
  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  late final _controller = ChatController(
    widget.repository,
    widget.documentId,
    widget.conversationId,
  )..load();
  final _question = TextEditingController();
  Future<void> _send() async {
    if (await _controller.send(_question.text) && mounted) _question.clear();
  }

  @override
  void dispose() {
    _controller.dispose();
    _question.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Document chat')),
    body: SafeArea(
      child: ListenableBuilder(
        listenable: _controller,
        builder: (context, _) => Column(
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Ask about this PDF. Supporting pages appear with each answer.',
              ),
            ),
            if (_controller.error != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    Text(_controller.error!),
                    if (widget.conversationId != null)
                      TextButton(
                        onPressed: _controller.load,
                        child: const Text('Retry loading'),
                      ),
                  ],
                ),
              ),
            Expanded(
              child: _controller.loading
                  ? const Center(child: CircularProgressIndicator())
                  : _controller.messages.isEmpty
                  ? const Center(
                      child: Text(
                        'Ask your first question about this document.',
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: _controller.messages.length,
                      itemBuilder: (context, index) {
                        final message = _controller.messages[index];
                        return Card(
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  message.role == 'user' ? 'You' : 'Answer',
                                  style: Theme.of(context).textTheme.labelLarge,
                                ),
                                const SizedBox(height: 8),
                                SelectableText(message.content),
                                if (message.citations.isNotEmpty) ...[
                                  const SizedBox(height: 8),
                                  Wrap(
                                    spacing: 8,
                                    children: [
                                      for (final citation in message.citations)
                                        ActionChip(
                                          onPressed: () => context.push(
                                            '/documents/${Uri.encodeComponent(widget.documentId)}/pages/${citation.pageNumber}',
                                            extra: citation.snippet.isEmpty
                                                ? 'Supporting snippet unavailable. Answer text:\n${message.content}'
                                                : citation.snippet,
                                          ),
                                          label: Text(
                                            'Page ${citation.pageNumber} · ${citation.elementType}',
                                          ),
                                        ),
                                    ],
                                  ),
                                ],
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _question,
                      minLines: 1,
                      maxLines: 4,
                      enabled: !_controller.sending && !_controller.loading,
                      decoration: const InputDecoration(
                        labelText: 'Ask about this PDF',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed:
                        _controller.sending ||
                            _controller.loading ||
                            (widget.conversationId != null &&
                                _controller.error != null)
                        ? null
                        : _send,
                    tooltip: 'Send question',
                    icon: _controller.sending
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
