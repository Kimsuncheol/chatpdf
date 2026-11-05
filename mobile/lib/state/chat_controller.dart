import 'package:flutter/foundation.dart';

import '../core/network/api_client.dart';
import '../data/models/conversation.dart';
import '../data/repositories/document_repository.dart';

class ChatController extends ChangeNotifier {
  ChatController(this._repository, this.documentId, this.conversationId);
  final DocumentRepository _repository;
  final String documentId;
  String? conversationId;
  final List<ChatMessage> messages = [];
  bool loading = false;
  bool loadFailed = false;
  bool sending = false;
  bool _disposed = false;
  String? error;
  Future<void> load() async {
    if (conversationId == null || loading) return;
    loading = true;
    loadFailed = false;
    error = null;
    notifyListeners();
    try {
      final result = await _repository.messages(documentId, conversationId!);
      if (!_disposed) {
        messages.clear();
        messages.addAll(result);
      }
    } catch (e) {
      if (!_disposed) {
        loadFailed = true;
        error = _message(e);
      }
    } finally {
      if (!_disposed) {
        loading = false;
        notifyListeners();
      }
    }
  }

  Future<bool> send(String question) async {
    if (sending ||
        loading ||
        loadFailed ||
        question.trim().isEmpty ||
        _disposed) {
      return false;
    }
    sending = true;
    error = null;
    notifyListeners();
    try {
      final result = await _repository.ask(
        documentId,
        question.trim(),
        conversationId: conversationId,
      );
      if (_disposed) return false;
      conversationId = result.conversationId;
      messages.addAll([
        ChatMessage(role: 'user', content: question.trim()),
        result.message,
      ]);
      return true;
    } catch (e) {
      if (!_disposed) error = _message(e);
      return false;
    } finally {
      if (!_disposed) {
        sending = false;
        notifyListeners();
      }
    }
  }

  String _message(Object e) => e is ApiException
      ? e.message
      : 'Unable to load this conversation. Please try again.';
  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
