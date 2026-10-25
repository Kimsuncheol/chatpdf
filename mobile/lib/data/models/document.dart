class Document {
  const Document({
    required this.id,
    required this.name,
    required this.status,
    required this.processedPages,
    this.totalPages,
  });
  factory Document.fromJson(Map<String, dynamic> json) => Document(
    id: json['id'] as String,
    name: json['name'] as String,
    status: json['status'] as String,
    processedPages: json['processed_pages'] as int? ?? 0,
    totalPages: json['total_pages'] as int?,
  );
  final String id;
  final String name;
  final String status;
  final int processedPages;
  final int? totalPages;
  bool get isReady => status == 'ready';
}
