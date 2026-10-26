import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../core/files/pdf_picker.dart';
import '../core/network/api_client.dart';
import '../data/models/ingestion_status.dart';
import '../data/repositories/document_repository.dart';

class UploadController extends ChangeNotifier {
  UploadController(
    this._repository,
    this._picker, {
    this.documentId,
    this.pollInterval = const Duration(seconds: 2),
  });
  final DocumentRepository _repository;
  final PdfPicker _picker;
  final Duration pollInterval;
  String? documentId;
  SelectedPdf? _file;
  String? _uploadKey;
  Completer<void>? _abort;
  Timer? _timer;
  bool _disposed = false;
  bool _paused = false;
  bool _polling = false;
  bool _busy = false;
  bool _uploading = false;
  int _pollFailures = 0;
  int _revision = 0;
  bool _notFound = false;
  double _progress = 0;
  int? _limit;
  String? _error;
  String? _notice;
  IngestionStatus? _status;

  String? get filename => _file?.name;
  int? get size => _file?.size;
  bool get busy => _busy;
  bool get uploading => _uploading;
  bool get polling => _polling;
  double get progress => _progress;
  String? get error => _error;
  String? get notice => _notice;
  IngestionStatus? get status => _status;
  int? get maxBytes => _limit;

  Future<void> start() async {
    if (documentId != null) await refresh();
  }

  Future<void> choose() async {
    if (_busy || _disposed) return;
    _busy = true;
    _error = null;
    _notice = null;
    _notify();
    try {
      _limit = await _repository.uploadLimit();
      if (_disposed) return;
      final file = await _picker.pick();
      if (_disposed || file == null) return;
      _file = null;
      _uploadKey = null;
      if (!file.name.toLowerCase().endsWith('.pdf')) {
        _error =
            'Choose a PDF file (.pdf). Other file types are not supported.';
      } else if (file.size <= 0) {
        _error = 'This file is empty. Choose a valid PDF.';
      } else if (file.size > _limit!) {
        _error =
            'This PDF is too large. The server limit is ${(_limit! / (1024 * 1024)).toStringAsFixed(1)} MB.';
      } else {
        _file = file;
        _uploadKey = _newKey();
        _progress = 0;
      }
    } catch (_) {
      if (!_disposed) _error = 'Unable to select a PDF or read the upload limit. Please try again.';
    } finally {
      if (!_disposed) {
        _busy = false;
        _notify();
      }
    }
  }

  Future<bool> upload() async {
    final file = _file;
    final key = _uploadKey;
    if (_disposed || _busy || file == null || key == null) return false;
    _busy = true;
    _uploading = true;
    _progress = 0;
    _error = null;
    _notice = null;
    _abort = Completer<void>();
    _notify();
    try {
      // Reconcile a lost response before transferring the same file again.
      final existing = await Future.any<IngestionStatus?>([
        _repository.findUpload(key),
        _abort!.future.then<IngestionStatus?>(
          (_) => throw const UploadCancelled(),
        ),
      ]);
      if (_disposed || _abort!.isCompleted) throw const UploadCancelled();
      final result =
          existing ??
          await _repository.upload(file, key, _abort!.future, (sent, total) {
            if (!_disposed && _uploading) {
              _progress = (sent / total).clamp(0, 1);
              _notify();
            }
          });
      if (_disposed) return false;
      _status = result;
      documentId = result.document.id;
      return true;
    } on UploadCancelled {
      if (!_disposed) _notice = 'Transfer stopped. If the server already accepted the PDF, retry the same file to reconnect. Completed server work is preserved.';
      return false;
    } catch (error) {
      if (!_disposed) {
        if (error is ApiException &&
            {
              'unsupported_pdf',
              'corrupt_pdf',
              'encrypted_pdf',
              'oversized_pdf',
              'too_many_pages',
              'validation_timeout',
            }.contains(error.code)) {
          _file = null;
          _uploadKey = null;
        }
        _error = error is ApiException
            ? error.message
            : 'Unable to read or upload this file. Choose it again or retry.';
      }
      return false;
    } finally {
      if (_abort != null && !_abort!.isCompleted) _abort!.complete();
      if (!_disposed) {
        _busy = false;
        _uploading = false;
        _notify();
        _schedule();
      }
    }
  }

  void stopTransfer() {
    if (_abort != null && !_abort!.isCompleted) _abort!.complete();
  }

  Future<void> refresh() async {
    final id = documentId;
    if (_disposed || _polling || _busy || id == null) return;
    _timer?.cancel();
    _polling = true;
    final revision = _revision;
    _notFound = false;
    _notify();
    try {
      final result = await _repository.status(id);
      if (!_disposed && revision == _revision) {
        _status = result;
        _error = null;
        _pollFailures = 0;
      }
    } catch (error) {
      if (!_disposed && revision == _revision) {
        _notFound = error is ApiException && error.statusCode == 404;
        _pollFailures++;
        _error = error is ApiException
            ? error.message
            : 'Unable to refresh processing status. Please retry.';
      }
    } finally {
      if (!_disposed) {
        _polling = false;
        _notify();
        _schedule();
      }
    }
  }

  Future<void> cancelProcessing() => _update(resume: false);
  Future<void> resumeProcessing() => _update(resume: true);

  Future<void> _update({required bool resume}) async {
    final id = documentId;
    if (_disposed || _busy || id == null) return;
    _timer?.cancel();
    _revision++;
    _busy = true;
    _error = null;
    _notify();
    try {
      final result = resume
          ? await _repository.retry(id)
          : await _repository.cancel(id);
      if (!_disposed) _status = result;
    } catch (error) {
      if (!_disposed) {
        _error = error is ApiException
            ? error.message
            : 'Unable to update processing. Please refresh and retry.';
      }
    } finally {
      if (!_disposed) {
        _busy = false;
        _notify();
        _schedule();
      }
    }
  }

  void pausePolling() {
    _paused = true;
    _timer?.cancel();
  }

  void resumePolling() {
    _paused = false;
    if (documentId != null) refresh();
  }

  void _schedule() {
    _timer?.cancel();
    if (_disposed ||
        _paused ||
        documentId == null ||
        _status?.active == false ||
        _notFound) {
      return;
    }
    final multiplier = min(15, 1 << min(_pollFailures, 4));
    _timer = Timer(pollInterval * multiplier, refresh);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  String _newKey() {
    final random = Random.secure();
    final bytes = List.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    stopTransfer();
    super.dispose();
  }
}
