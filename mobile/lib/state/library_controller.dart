import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/network/api_client.dart';
import '../data/models/document.dart';
import '../data/repositories/document_repository.dart';

class LibraryController extends ChangeNotifier {
  LibraryController(this._repository);
  final DocumentRepository _repository;
  final List<Document> _documents = [];
  final Set<String> _deleting = {};
  final Set<String> _deleted = {};
  Timer? _searchTimer;
  String _query = '';
  String? _nextCursor;
  String? _error;
  String? _deleteError;
  bool _loading = false;
  bool _loadingMore = false;
  bool _disposed = false;
  int _generation = 0;

  List<Document> get documents => List.unmodifiable(_documents);
  String get query => _query;
  bool get loading => _loading;
  bool get loadingMore => _loadingMore;
  bool get hasMore => _nextCursor != null;
  String? get error => _error;
  String? get deleteError => _deleteError;
  bool isDeleting(String id) => _deleting.contains(id);

  void search(String value) {
    final next = value.trim();
    if (_disposed || next == _query) return;
    _query = next;
    _documents.clear();
    _nextCursor = null;
    _error = null;
    _loading = true;
    _loadingMore = false;
    final generation = ++_generation;
    _searchTimer?.cancel();
    _searchTimer = Timer(
      const Duration(milliseconds: 300),
      () => _fetch(generation, reset: true),
    );
    notifyListeners();
  }

  Future<void> refresh() async {
    if (_disposed) return;
    _searchTimer?.cancel();
    _loading = true;
    _loadingMore = false;
    _error = null;
    final generation = ++_generation;
    notifyListeners();
    await _fetch(generation, reset: true);
  }

  Future<void> loadMore() async {
    if (_disposed || _loading || _loadingMore || !hasMore) return;
    _loadingMore = true;
    _error = null;
    notifyListeners();
    await _fetch(_generation, reset: false);
  }

  Future<void> _fetch(int generation, {required bool reset}) async {
    if (_disposed) return;
    try {
      final page = await _repository.list(
        query: _query,
        cursor: reset ? null : _nextCursor,
      );
      if (_disposed || generation != _generation) return;
      if (reset) _documents.clear();
      final ids = _documents.map((d) => d.id).toSet();
      _documents.addAll(
        page.items.where((d) => !_deleted.contains(d.id) && ids.add(d.id)),
      );
      _nextCursor = page.nextCursor;
    } catch (error) {
      if (!_disposed && generation == _generation) {
        _error = error is ApiException
            ? error.message
            : 'Unable to load documents. Please try again.';
      }
    } finally {
      if (!_disposed && generation == _generation) {
        _loading = false;
        _loadingMore = false;
        notifyListeners();
      }
    }
  }

  Future<bool> delete(Document document) async {
    if (_disposed || !_deleting.add(document.id)) return false;
    _deleteError = null;
    notifyListeners();
    try {
      try {
        await _repository.delete(document.id);
      } on ApiException catch (error) {
        // A stale list may contain an already-deleted document.
        if (error.statusCode != 404) rethrow;
      }
      if (_disposed) return false;
      _deleted.add(document.id);
      _documents.removeWhere((d) => d.id == document.id);
      return true;
    } catch (_) {
      if (!_disposed) {
        _deleteError = 'Deletion could not finish. Please try deleting the document again.';
        try {
          final current = await _repository.get(document.id);
          if (!_disposed) {
            final index = _documents.indexWhere((d) => d.id == document.id);
            if (index >= 0) _documents[index] = current;
          }
        } catch (_) {
          // Keep the visible item and retry action while the server is offline.
        }
      }
      return false;
    } finally {
      if (!_disposed) {
        _deleting.remove(document.id);
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _searchTimer?.cancel();
    super.dispose();
  }
}
