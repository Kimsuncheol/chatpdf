import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/navigation/app_routes.dart';
import '../../data/models/document.dart';
import '../../data/repositories/document_repository.dart';
import '../../state/load_controller.dart';
import '../widgets/async_content.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key, required this.repository});
  final DocumentRepository repository;
  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  late final _controller = LoadController(widget.repository.list)..refresh();
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Document library'),
      actions: [
        IconButton(
          onPressed: _controller.refresh,
          icon: const Icon(Icons.refresh),
          tooltip: 'Refresh library',
        ),
      ],
    ),
    floatingActionButton: FloatingActionButton.extended(
      onPressed: () => context.go(AppRoutes.upload),
      icon: const Icon(Icons.add),
      label: const Text('Upload PDF'),
    ),
    body: AsyncContent<List<Document>>(
      controller: _controller,
      builder: (documents) => documents.isEmpty
          ? const Center(
              child: Text(
                'Your library is empty. Upload a PDF to get started.',
              ),
            )
          : ListView.builder(
              itemCount: documents.length,
              itemBuilder: (context, index) {
                final document = documents[index];
                return ListTile(
                  leading: const Icon(Icons.picture_as_pdf_outlined),
                  title: Text(document.name),
                  subtitle: Text(document.status),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.push(
                    document.isReady
                        ? AppRoutes.chat(document.id)
                        : AppRoutes.processing(document.id),
                  ),
                );
              },
            ),
    ),
  );
}
