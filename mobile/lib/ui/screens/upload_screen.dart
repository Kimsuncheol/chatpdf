import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/navigation/app_routes.dart';
import '../../data/models/document.dart';
import '../../data/repositories/document_repository.dart';
import '../../state/load_controller.dart';
import '../widgets/async_content.dart';

class UploadScreen extends StatefulWidget {
  const UploadScreen({super.key, required this.repository, this.documentId});
  final DocumentRepository repository;
  final String? documentId;
  @override
  State<UploadScreen> createState() => _UploadScreenState();
}

class _UploadScreenState extends State<UploadScreen> {
  LoadController<Document>? _controller;
  void _load() {
    final id = widget.documentId;
    if (id != null) {
      _controller = LoadController(() => widget.repository.get(id))..refresh();
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant UploadScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.documentId != widget.documentId) {
      _controller?.dispose();
      _controller = null;
      _load();
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('PDF upload and processing')),
    body: _controller == null
        ? const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.upload_file, size: 64),
                  SizedBox(height: 16),
                  Text('Upload a PDF', style: TextStyle(fontSize: 24)),
                  SizedBox(height: 8),
                  Text(
                    'File selection and transfer will be connected in the upload implementation.',
                    textAlign: TextAlign.center,
                  ),
                  SizedBox(height: 16),
                  FilledButton(
                    onPressed: null,
                    child: Text('Choose PDF — coming next'),
                  ),
                ],
              ),
            ),
          )
        : AsyncContent<Document>(
            controller: _controller!,
            builder: (document) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      document.name,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 16),
                    Text('Status: ${document.status}'),
                    Text(
                      '${document.processedPages} of ${document.totalPages ?? "?"} pages processed',
                    ),
                    const SizedBox(height: 16),
                    TextButton(
                      onPressed: _controller!.refresh,
                      child: const Text('Refresh status'),
                    ),
                    if (document.isReady)
                      FilledButton(
                        onPressed: () =>
                            context.push(AppRoutes.chat(document.id)),
                        child: const Text('Open document chat'),
                      ),
                  ],
                ),
              ),
            ),
          ),
  );
}
