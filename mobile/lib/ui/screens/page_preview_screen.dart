import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../data/repositories/document_repository.dart';

class PagePreviewScreen extends StatefulWidget {
  const PagePreviewScreen({
    super.key,
    required this.repository,
    required this.documentId,
    required this.pageNumber,
    this.snippet = '',
  });
  final DocumentRepository repository;
  final String documentId;
  final int pageNumber;
  final String snippet;
  @override
  State<PagePreviewScreen> createState() => _PagePreviewScreenState();
}

class _PagePreviewScreenState extends State<PagePreviewScreen> {
  late Future<Uint8List> preview = _load();
  Future<Uint8List> _load() =>
      widget.repository.pagePreview(widget.documentId, widget.pageNumber);
  Widget _fallback() => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.image_not_supported_outlined, size: 40),
          const SizedBox(height: 12),
          const Text(
            'Page preview unavailable. The citation text is shown below.',
            textAlign: TextAlign.center,
          ),
          TextButton(
            onPressed: () => setState(() {
              preview = _load();
            }),
            child: const Text('Retry preview'),
          ),
        ],
      ),
    ),
  );
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text('Page ${widget.pageNumber}')),
    body: SafeArea(
      child: Column(
        children: [
          Expanded(
            child: FutureBuilder<Uint8List>(
              future: preview,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError || snapshot.data == null) {
                  return _fallback();
                }
                return InteractiveViewer(
                  minScale: 0.5,
                  maxScale: 5,
                  child: Center(
                    child: Image.memory(
                      snapshot.data!,
                      fit: BoxFit.contain,
                      semanticLabel: 'PDF page ${widget.pageNumber}',
                      errorBuilder: (_, _, _) => _fallback(),
                    ),
                  ),
                );
              },
            ),
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 220),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Cited page ${widget.pageNumber}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  SelectableText(
                    widget.snippet.isEmpty
                        ? 'No supporting snippet was saved with this citation.'
                        : widget.snippet,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
