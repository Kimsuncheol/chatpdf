class Document {
  const Document({
    required this.id,
    required this.name,
    required this.status,
    required this.processedPages,
    this.totalPages,
    this.uploadedAt,
  });
  factory Document.fromJson(Map<String, dynamic> json) => Document(
    id: json['id'] as String,
    name: json['name'] as String,
    status: json['status'] as String,
    processedPages: json['processed_pages'] as int? ?? 0,
    totalPages: json['total_pages'] as int?,
    uploadedAt: json['uploaded_at'] == null
        ? null
        : DateTime.parse(json['uploaded_at'] as String),
  );
  final String id;
  final String name;
  final String status;
  final int processedPages;
  final int? totalPages;
  final DateTime? uploadedAt;
  bool get isReady => status == 'ready';
  bool get canOpen => status != 'deleting';
  String get statusLabel => switch (status) {
    'queued' => 'Queued',
    'processing' => 'Processing',
    'ready' => 'Ready',
    'failed' => 'Processing failed',
    'deleting' => 'Deletion pending',
    _ => 'Unknown status',
  };
}

class DocumentPage {
  const DocumentPage({required this.items, this.nextCursor});
  factory DocumentPage.fromJson(Map<String, dynamic> json) => DocumentPage(
    items: (json['items'] as List<dynamic>)
        .map((item) => Document.fromJson(item as Map<String, dynamic>))
        .toList(),
    nextCursor: json['next_cursor'] as String?,
  );
  final List<Document> items;
  final String? nextCursor;
}
