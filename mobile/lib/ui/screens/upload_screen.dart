import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/navigation/app_routes.dart';
import '../../core/files/pdf_picker.dart';
import '../../data/repositories/document_repository.dart';
import '../../state/upload_controller.dart';
import '../widgets/auth_feedback.dart';

class UploadScreen extends StatefulWidget {
  const UploadScreen({
    super.key,
    required this.repository,
    this.documentId,
    this.picker,
  });
  final DocumentRepository repository;
  final String? documentId;
  final PdfPicker? picker;
  @override
  State<UploadScreen> createState() => _UploadScreenState();
}

class _UploadScreenState extends State<UploadScreen>
    with WidgetsBindingObserver {
  late UploadController _controller;
  void _create() {
    _controller = UploadController(
      widget.repository,
      widget.picker ?? PlatformPdfPicker(),
      documentId: widget.documentId,
    )..start();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _create();
  }

  @override
  void didUpdateWidget(covariant UploadScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.documentId != widget.documentId) {
      _controller.dispose();
      _create();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _controller.resumePolling();
    } else {
      _controller.pausePolling();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  Future<void> _upload() async {
    if (await _controller.upload() && mounted) {
      context.go(AppRoutes.processing(_controller.documentId!));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('PDF upload and processing')),
    body: SafeArea(
      child: ListenableBuilder(
        listenable: _controller,
        builder: (context, _) {
          final controller = _controller;
          final status = controller.status;
          return SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (controller.error != null) ...[
                      AuthFeedback(message: controller.error!),
                      const SizedBox(height: 16),
                    ],
                    if (controller.notice != null) ...[
                      AuthFeedback(message: controller.notice!, isError: false),
                      const SizedBox(height: 16),
                    ],
                    if (controller.documentId == null) ...[
                      const Icon(Icons.upload_file, size: 64),
                      const SizedBox(height: 16),
                      Text(
                        'Upload a PDF',
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Choose an unencrypted PDF. The server checks its contents and processes it in small page batches.',
                      ),
                      const SizedBox(height: 16),
                      if (controller.filename != null) ...[
                        Text(
                          controller.filename!,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        Text(
                          '${(controller.size! / (1024 * 1024)).toStringAsFixed(1)} MB',
                        ),
                        const SizedBox(height: 16),
                      ],
                      if (controller.uploading) ...[
                        LinearProgressIndicator(value: controller.progress),
                        const SizedBox(height: 8),
                        Text(
                          controller.progress >= 1
                              ? 'Validating PDF on server…'
                              : 'Uploading ${(controller.progress * 100).round()}%',
                        ),
                        TextButton(
                          onPressed: controller.stopTransfer,
                          child: const Text('Stop transfer'),
                        ),
                      ] else ...[
                        FilledButton.icon(
                          onPressed: controller.busy ? null : controller.choose,
                          icon: const Icon(Icons.attach_file),
                          label: const Text('Choose PDF'),
                        ),
                        if (controller.filename != null)
                          OutlinedButton(
                            onPressed: controller.busy ? null : _upload,
                            child: const Text('Upload / retry same PDF'),
                          ),
                        if (controller.busy)
                          const Padding(
                            padding: EdgeInsets.all(16),
                            child: Center(child: CircularProgressIndicator()),
                          ),
                      ],
                    ] else if (status == null) ...[
                      if (controller.polling)
                        const Center(child: CircularProgressIndicator()),
                      TextButton(
                        onPressed: controller.polling
                            ? null
                            : controller.refresh,
                        child: const Text('Retry status'),
                      ),
                    ] else ...[
                      Text(
                        status.document.name,
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 16),
                      Semantics(
                        liveRegion: true,
                        child: Text(status.stageLabel),
                      ),
                      const SizedBox(height: 16),
                      if (status.active)
                        LinearProgressIndicator(
                          value:
                              status.document.totalPages == null ||
                                  status.document.totalPages == 0
                              ? null
                              : status.document.processedPages /
                                    status.document.totalPages!,
                        ),
                      const SizedBox(height: 8),
                      Text(
                        '${status.document.processedPages} of ${status.document.totalPages ?? "?"} pages processed',
                      ),
                      if (status.job?.status == 'running')
                        Text(
                          'Current batch starts at page ${status.job!.nextPage}.',
                        ),
                      if (status.job?.status == 'failed')
                        Padding(
                          padding: const EdgeInsets.only(top: 16),
                          child: AuthFeedback(
                            message: status.job!.errorMessage,
                          ),
                        ),
                      if (controller.busy)
                        const Padding(
                          padding: EdgeInsets.all(16),
                          child: Center(child: CircularProgressIndicator()),
                        ),
                      if (status.active)
                        TextButton(
                          onPressed: controller.busy
                              ? null
                              : controller.cancelProcessing,
                          child: const Text('Cancel processing'),
                        ),
                      if (status.canResume)
                        FilledButton(
                          onPressed: controller.busy
                              ? null
                              : controller.resumeProcessing,
                          child: Text(
                            status.job?.status == 'cancelled'
                                ? 'Resume processing'
                                : 'Retry processing',
                          ),
                        ),
                      if (status.job?.status == 'cancelled')
                        const Text(
                          'Completed pages are saved. Resume to continue from the next unfinished batch.',
                        ),
                      TextButton(
                        onPressed: controller.busy || controller.polling
                            ? null
                            : controller.refresh,
                        child: const Text('Refresh status'),
                      ),
                      if (status.document.isReady)
                        FilledButton(
                          onPressed: () =>
                              context.push(AppRoutes.chat(status.document.id)),
                          child: const Text('Open document chat'),
                        ),
                      if (!status.active)
                        TextButton(
                          onPressed: () => context.go(AppRoutes.upload),
                          child: const Text('Choose another PDF'),
                        ),
                    ],
                  ],
                ),
              ),
            ),
          );
        },
      ),
    ),
  );
}
