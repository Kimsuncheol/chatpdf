import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../app/navigation/app_routes.dart';
import '../../data/models/document.dart';
import '../../data/repositories/document_repository.dart';
import '../../state/library_controller.dart';
import '../widgets/auth_feedback.dart';
import '../widgets/document_card.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key, required this.repository});
  final DocumentRepository repository;
  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  late final _controller = LibraryController(widget.repository)..refresh();
  final _search = TextEditingController();

  Future<void> _open(Document document) async {
    await context.push(
      document.isReady
          ? AppRoutes.chat(document.id)
          : AppRoutes.processing(document.id),
    );
    if (mounted) await _controller.refresh();
  }

  Future<void> _delete(Document document) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete document?'),
        content: Text(
          'Delete “${document.name}”? This permanently removes the PDF, extracted content, indexes, and conversations. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete document'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    if (await _controller.delete(document) && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Document deleted.')));
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _search.dispose();
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
      icon: const Icon(Icons.upload_file),
      label: const Text('Upload PDF'),
    ),
    body: SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              key: const ValueKey('document-search'),
              controller: _search,
              onChanged: _controller.search,
              inputFormatters: [LengthLimitingTextInputFormatter(200)],
              decoration: InputDecoration(
                labelText: 'Search documents',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: IconButton(
                  tooltip: 'Clear search',
                  icon: const Icon(Icons.clear),
                  onPressed: () {
                    _search.clear();
                    _controller.search('');
                  },
                ),
              ),
            ),
          ),
          Expanded(
            child: ListenableBuilder(
              listenable: _controller,
              builder: (context, _) {
                final items = _controller.documents;
                if (_controller.loading && items.isEmpty) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (_controller.error != null && items.isEmpty) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(_controller.error!, textAlign: TextAlign.center),
                          TextButton(
                            onPressed: _controller.refresh,
                            child: const Text('Try again'),
                          ),
                        ],
                      ),
                    ),
                  );
                }
                return RefreshIndicator(
                  onRefresh: _controller.refresh,
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 100),
                    children: [
                      if (_controller.loading) const LinearProgressIndicator(),
                      if (_controller.deleteError != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: AuthFeedback(
                            message: _controller.deleteError!,
                          ),
                        ),
                      if (items.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 48),
                          child: Column(
                            children: [
                              const Icon(Icons.folder_open_outlined, size: 56),
                              const SizedBox(height: 16),
                              Text(
                                _controller.query.isNotEmpty
                                    ? 'No documents match your search.'
                                    : _controller.hasMore
                                    ? 'No documents on this page. Load more to continue.'
                                    : 'Your library is empty. Upload a PDF to get started.',
                                textAlign: TextAlign.center,
                              ),
                            ],
                          ),
                        ),
                      for (final document in items)
                        DocumentCard(
                          key: ValueKey(document.id),
                          document: document,
                          deleting: _controller.isDeleting(document.id),
                          onOpen: () => _open(document),
                          onDelete: () => _delete(document),
                        ),
                      if (_controller.error != null) ...[
                        AuthFeedback(message: _controller.error!),
                        TextButton(
                          onPressed: _controller.hasMore
                              ? _controller.loadMore
                              : _controller.refresh,
                          child: const Text('Try again'),
                        ),
                      ],
                      if (_controller.hasMore)
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: _controller.loadingMore
                              ? const Center(child: CircularProgressIndicator())
                              : OutlinedButton(
                                  onPressed: _controller.loading
                                      ? null
                                      : _controller.loadMore,
                                  child: const Text('Load more documents'),
                                ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    ),
  );
}
