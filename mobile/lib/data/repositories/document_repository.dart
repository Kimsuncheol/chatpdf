import '../../core/network/api_client.dart';
import '../models/conversation.dart';
import '../models/document.dart';

class DocumentRepository {
  DocumentRepository(this._api);
  final ApiClient _api;
  String _segment(String value) => Uri.encodeComponent(value);
  Future<List<Document>> list() async =>
      (await _api.get('documents') as List<dynamic>)
          .map((item) => Document.fromJson(item as Map<String, dynamic>))
          .toList();
  Future<Document> get(String id) async => Document.fromJson(
    await _api.get('documents/${_segment(id)}') as Map<String, dynamic>,
  );
  Future<List<Conversation>> conversations() async =>
      (await _api.get('conversations') as List<dynamic>)
          .map((item) => Conversation.fromJson(item as Map<String, dynamic>))
          .toList();
  Future<List<ChatMessage>> messages(
    String documentId,
    String conversationId,
  ) async =>
      (await _api.get(
            'documents/${_segment(documentId)}/conversations/${_segment(conversationId)}/messages',
          ) as List<dynamic>)
          .map((item) => ChatMessage.fromJson(item as Map<String, dynamic>))
          .toList();
  Future<({String conversationId, ChatMessage message})> ask(
    String documentId,
    String question, {
    String? conversationId,
  }) async {
    final json = await _api.post('documents/${_segment(documentId)}/chat', {
      'question': question,
      'conversation_id': ?conversationId,
    }) as Map<String, dynamic>;
    return (
      conversationId: json['conversation_id'] as String,
      message: ChatMessage.fromJson(json['message'] as Map<String, dynamic>),
    );
  }
}
