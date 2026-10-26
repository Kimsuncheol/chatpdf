import '../../core/network/api_client.dart';
import '../models/conversation.dart';
import '../models/document.dart';
import '../models/ingestion_status.dart';
import '../../core/files/pdf_picker.dart';

class DocumentRepository {
  DocumentRepository(this._api);
  final ApiClient _api;
  String _segment(String value) => Uri.encodeComponent(value);
  Future<DocumentPage> list({
    String query = '',
    String? cursor,
    int limit = 20,
  }) async => DocumentPage.fromJson(
    await _api.get(
      Uri(
        path: 'documents',
        queryParameters: {
          'limit': '$limit',
          if (query.isNotEmpty) 'q': query,
          'cursor': ?cursor,
        },
      ).toString(),
    ) as Map<String, dynamic>,
  );

  Future<void> delete(String id) => _api.delete('documents/${_segment(id)}');

  Future<Document> get(String id) async => Document.fromJson(
    await _api.get('documents/${_segment(id)}') as Map<String, dynamic>,
  );
  Future<int> uploadLimit() async =>
      (await _api.get('uploads/limits') as Map<String, dynamic>)['max_bytes']
          as int;

  Future<IngestionStatus?> findUpload(String key) async {
    try {
      return IngestionStatus.fromJson(
        await _api.get('uploads/${_segment(key)}') as Map<String, dynamic>,
      );
    } on ApiException catch (error) {
      if (error.statusCode == 404) return null;
      rethrow;
    }
  }

  Future<IngestionStatus> upload(
    SelectedPdf file,
    String key,
    Future<void> cancelled,
    void Function(int, int) progress,
  ) async => IngestionStatus.fromJson(
    await _api.uploadPdf(
      name: file.name,
      length: file.size,
      bytes: file.openRead(),
      uploadKey: key,
      cancelled: cancelled,
      onProgress: progress,
    ) as Map<String, dynamic>,
  );

  Future<IngestionStatus> status(String id) async => IngestionStatus.fromJson(
    await _api.get('documents/${_segment(id)}/status') as Map<String, dynamic>,
  );

  Future<IngestionStatus> cancel(String id) async => IngestionStatus.fromJson(
    await _api.post('documents/${_segment(id)}/cancel', {})
        as Map<String, dynamic>,
  );

  Future<IngestionStatus> retry(String id) async => IngestionStatus.fromJson(
    await _api.post('documents/${_segment(id)}/retry', {})
        as Map<String, dynamic>,
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
