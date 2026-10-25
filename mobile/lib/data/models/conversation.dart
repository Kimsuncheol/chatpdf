class Conversation {
  const Conversation({
    required this.id,
    required this.documentId,
    required this.title,
  });
  factory Conversation.fromJson(Map<String, dynamic> json) => Conversation(
    id: json['id'] as String,
    documentId: json['document_id'] as String,
    title: json['title'] as String,
  );
  final String id;
  final String documentId;
  final String title;
}

class Citation {
  const Citation({required this.pageNumber, required this.elementType});
  factory Citation.fromJson(Map<String, dynamic> json) => Citation(
    pageNumber: json['page_number'] as int,
    elementType: json['element_type'] as String,
  );
  final int pageNumber;
  final String elementType;
}

class ChatMessage {
  const ChatMessage({
    required this.role,
    required this.content,
    this.citations = const [],
  });
  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
    role: json['role'] as String,
    content: json['content'] as String,
    citations: (json['citations'] as List<dynamic>? ?? [])
        .map((item) => Citation.fromJson(item as Map<String, dynamic>))
        .toList(),
  );
  final String role;
  final String content;
  final List<Citation> citations;
}
