import 'package:flutter/material.dart';

import '../../data/models/document.dart';

class DocumentCard extends StatelessWidget {
  const DocumentCard({
    super.key,
    required this.document,
    required this.deleting,
    required this.onOpen,
    required this.onDelete,
  });
  final Document document;
  final bool deleting;
  final VoidCallback onOpen;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final uploaded = document.uploadedAt;
    final date = uploaded == null
        ? 'Upload date unavailable'
        : 'Uploaded ${MaterialLocalizations.of(context).formatCompactDate(uploaded.toLocal())}';
    final pages = document.totalPages;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.picture_as_pdf_outlined),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    document.name,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (deleting)
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                else
                  IconButton(
                    onPressed: onDelete,
                    tooltip: 'Delete ${document.name}',
                    icon: const Icon(Icons.delete_outline),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(date),
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Chip(label: Text(document.statusLabel)),
                if (pages != null)
                  Text('$pages ${pages == 1 ? "page" : "pages"}'),
                if (document.status == 'processing')
                  Text('${document.processedPages} pages processed'),
              ],
            ),
            const SizedBox(height: 8),
            if (document.canOpen)
              OutlinedButton.icon(
                onPressed: deleting ? null : onOpen,
                icon: const Icon(Icons.open_in_new),
                label: Text(
                  document.isReady ? 'Open document' : 'View processing status',
                ),
              )
            else
              TextButton(
                onPressed: deleting ? null : onDelete,
                child: const Text('Retry deletion'),
              ),
          ],
        ),
      ),
    );
  }
}
