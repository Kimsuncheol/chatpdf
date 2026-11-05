import 'package:flutter/material.dart';
import 'package:flutter_gen_ai_chat_ui/flutter_gen_ai_chat_ui.dart' as ai;
import 'package:go_router/go_router.dart';

import '../../data/models/conversation.dart';
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
  static const _blue = Color(0xFF246BFD);
  static const _violet = Color(0xFF783BEE);
  static const _you = ai.ChatUser(id: 'user', name: 'You');
  static const _assistant = ai.ChatUser(id: 'assistant', name: 'ChatPDF');
  final _messages = ai.ChatMessagesController();
  final _question = TextEditingController();
  // API history has no timestamps. Stable local ordering avoids message jumps
  // and duplicate IDs when several historical messages arrive together.
  final _epoch = DateTime.now();
  late final ChatController _controller;
  String? _pending;

  @override
  void initState() {
    super.initState();
    _controller = ChatController(
      widget.repository,
      widget.documentId,
      widget.conversationId,
    );
    _controller.addListener(_sync);
    _controller.load();
  }

  void _sync() {
    if (!mounted) return;
    final history = _controller.messages;
    _messages.setMessages([
      for (var i = 0; i < history.length; i++)
        ai.ChatMessage(
          text: history[i].content,
          user: history[i].role == 'user' ? _you : _assistant,
          createdAt: _epoch.add(Duration(milliseconds: i)),
          isMarkdown: history[i].role != 'user',
          customProperties: {
            'id': 'message-$i',
            'citations': history[i].citations,
          },
        ),
      if (_controller.sending && _pending != null)
        ai.ChatMessage(
          text: _pending!,
          user: _you,
          createdAt: _epoch.add(Duration(milliseconds: history.length)),
          customProperties: const {'id': 'pending-question'},
        ),
    ]);
    setState(() {});
  }

  Future<void> _send(ai.ChatMessage message) async {
    if (_controller.sending || _controller.loading || _controller.loadFailed) {
      return;
    }
    final question = message.text.trim();
    if (question.isEmpty) return;
    _pending = question;
    final sent = await _controller.send(question);
    if (!mounted) return;
    _pending = null;
    if (!sent) {
      _question.value = TextEditingValue(
        text: question,
        selection: TextSelection.collapsed(offset: question.length),
      );
    }
  }

  Widget? _citations(
    BuildContext context,
    ai.ChatMessage message,
    bool isUser,
  ) {
    final citations = message.customProperties?['citations'] as List<Citation>?;
    if (isUser || citations == null || citations.isEmpty) return null;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          for (final citation in citations)
            ActionChip(
              avatar: const Icon(Icons.find_in_page_outlined, size: 16),
              label: Text(
                'Page ${citation.pageNumber} · ${citation.elementType}',
              ),
              onPressed: () => context.push(
                '/documents/${Uri.encodeComponent(widget.documentId)}/pages/${citation.pageNumber}',
                extra: citation.snippet.isEmpty
                    ? 'Supporting snippet unavailable. Answer text:\n${message.text}'
                    : citation.snippet,
              ),
            ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _controller.removeListener(_sync);
    _controller.dispose();
    _messages.dispose();
    _question.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final blocked = _controller.loading || _controller.loadFailed;
    return Scaffold(
      appBar: AppBar(
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Document chat'),
            Text(
              'CHATPDF ASSISTANT',
              style: TextStyle(
                fontSize: 10,
                letterSpacing: 1.8,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        actions: const [
          Padding(
            padding: EdgeInsets.only(right: 20),
            child: Icon(Icons.auto_awesome, color: _violet),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    _blue.withValues(alpha: .08),
                    _violet.withValues(alpha: .08),
                  ],
                ),
                border: Border(
                  bottom: BorderSide(
                    color: colors.outlineVariant.withValues(alpha: .4),
                  ),
                ),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.description_outlined,
                    color: _blue,
                    size: 18,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Answers from your PDF, with supporting pages.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
            if (_controller.error != null)
              Container(
                key: const ValueKey('chat-error'),
                width: double.infinity,
                margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colors.errorContainer,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.error_outline,
                      color: colors.onErrorContainer,
                      size: 20,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _controller.error!,
                        style: TextStyle(color: colors.onErrorContainer),
                      ),
                    ),
                    if (_controller.loadFailed)
                      TextButton(
                        onPressed: _controller.loading
                            ? null
                            : _controller.load,
                        child: const Text('Retry loading'),
                      ),
                  ],
                ),
              ),
            Expanded(
              child: _controller.loading
                  ? const Center(child: CircularProgressIndicator())
                  : ai.AiChatWidget(
                      currentUser: _you,
                      aiUser: _assistant,
                      controller: _messages,
                      onSendMessage: _send,
                      maxWidth: 900,
                      readOnly: blocked,
                      enableMarkdownStreaming: false,
                      loadingConfig: ai.LoadingConfig(
                        isLoading: _controller.sending,
                        typingIndicatorColor: _violet,
                      ),
                      welcomeMessageConfig: ai.WelcomeMessageConfig(
                        centerVertically: true,
                        title: 'Make sense of your PDF',
                        subtitle: 'Explore the details, connect ideas, and find the pages behind every answer.',
                        titleStyle: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          letterSpacing: -.7,
                        ),
                        containerDecoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              _blue.withValues(alpha: .07),
                              _violet.withValues(alpha: .07),
                            ],
                          ),
                          borderRadius: BorderRadius.circular(28),
                          border: Border.all(
                            color: _blue.withValues(alpha: .12),
                          ),
                        ),
                      ),
                      exampleQuestions: blocked
                          ? const []
                          : const [
                              ai.ExampleQuestion(
                                question:
                                    'Summarize the key ideas in this PDF.',
                              ),
                              ai.ExampleQuestion(
                                question:
                                    'What are the most important takeaways?',
                              ),
                            ],
                      inputOptions: ai.InputOptions(
                        textController: _question,
                        readOnly: _controller.sending || blocked,
                        autofocus: false,
                        minLines: 1,
                        maxLines: 5,
                        sendButtonColor: _blue,
                        sendButtonTooltip: 'Send question',
                        sendButtonBuilder: (onSend) => IconButton.filled(
                          onPressed: _controller.sending || blocked
                              ? null
                              : onSend,
                          tooltip: 'Send question',
                          style: IconButton.styleFrom(
                            backgroundColor: _blue,
                            foregroundColor: Colors.white,
                          ),
                          icon: const Icon(Icons.arrow_upward_rounded),
                        ),
                        decoration: const InputDecoration(
                          hintText: 'Ask about this PDF…',
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 14,
                          ),
                        ),
                        containerDecoration: BoxDecoration(
                          color: colors.surface,
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(color: colors.outlineVariant),
                        ),
                        margin: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                      ),
                      messageOptions: ai.MessageOptions(
                        showTime: false,
                        showUserName: true,
                        showCopyButton: true,
                        bubbleBuilder: (context, message, isUser, bubble) {
                          final sources = _citations(context, message, isUser);
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              bubble,
                              if (sources != null)
                                Align(
                                  alignment: Alignment.center,
                                  child: ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxWidth: 760,
                                    ),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 16,
                                      ),
                                      child: sources,
                                    ),
                                  ),
                                ),
                            ],
                          );
                        },
                        bubbleStyle: ai.BubbleStyle(
                          userBubbleColor: _blue,
                          aiBubbleColor: colors.surfaceContainerLow,
                          enableShadow: false,
                        ),
                        userTextColor: Colors.white,
                        aiTextColor: colors.onSurface,
                        padding: const EdgeInsets.all(16),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
