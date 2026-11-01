import 'document.dart';

class IngestionJob {
  IngestionJob.fromJson(Map<String, dynamic> json)
    : id = json['id'] as String,
      status = json['status'] as String,
      stage = json['stage'] as String,
      nextPage = json['next_page'] as int,
      retryable = json['retryable'] == true || json['retryable'] == 1,
      errorCode = json['error_code'] as String?;
  final String id;
  final String status;
  final String stage;
  final int nextPage;
  final bool retryable;
  final String? errorCode;

  String get errorMessage => switch (errorCode) {
    'no_readable_content' =>
      'No readable text was found. Image-only PDFs need an OCR-enabled server.',
    'embedding_failed' => 'The embedding provider could not process this batch. Saved progress is preserved; retry after the server is available.',
    'reindex_required' => 'The parser or index configuration changed. The server needs to reindex this PDF.',
    'chunk_too_large' => 'An intact table row or heading exceeds the configured chunk limit. Adjust server settings or upload a smaller PDF.',
    'source_missing' => 'The stored PDF is missing. Upload the PDF again.',
    'encrypted_pdf' => 'Choose an unencrypted PDF.',
    'batch_content_limit' =>
      'A page batch contains too much content. Split the PDF and upload again.',
    'worker_configuration' => 'The processing worker needs server configuration. Try again after it is available.',
    'parse_failed' => 'A PDF page could not be read. Retry this batch, or export a fresh copy if it fails again.',
    'batch_timeout' => 'Processing this page batch took too long. Retry to resume from saved progress.',
    _ => 'Processing stopped. Saved page batches are preserved.',
  };
}

class IngestionStatus {
  IngestionStatus.fromJson(Map<String, dynamic> json)
    : document = Document.fromJson(json['document'] as Map<String, dynamic>),
      job = json['job'] == null
          ? null
          : IngestionJob.fromJson(json['job'] as Map<String, dynamic>);
  final Document document;
  final IngestionJob? job;
  bool get active =>
      document.status != 'deleting' &&
      (job == null
          ? {'queued', 'processing'}.contains(document.status)
          : {'queued', 'running'}.contains(job!.status));
  bool get canResume =>
      document.status != 'deleting' &&
      job != null &&
      job!.retryable &&
      {'failed', 'cancelled'}.contains(job!.status);
  String get stageLabel => switch (job?.stage) {
    'queued' => 'Queued — waiting for a worker',
    'extracting' => 'Extracting page batches',
    'embedding' => 'Generating retrieval embeddings',
    'saving' => 'Saving extracted content and index',
    'completed' => 'Ready',
    'failed' => 'Processing failed',
    'cancelled' => 'Processing cancelled — progress saved',
    _ => document.statusLabel,
  };
}
