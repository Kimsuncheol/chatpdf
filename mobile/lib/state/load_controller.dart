import 'package:flutter/foundation.dart';

import '../core/network/api_client.dart';

class LoadController<T> extends ChangeNotifier {
  LoadController(this._load);
  final Future<T> Function() _load;
  T? data;
  String? error;
  bool loading = false;
  bool _disposed = false;
  Future<void> refresh() async {
    if (loading || _disposed) return;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final result = await _load();
      if (!_disposed) data = result;
    } catch (e) {
      if (!_disposed) {
        error = e is ApiException
            ? e.message
            : 'Unable to load data. Please try again.';
      }
    } finally {
      if (!_disposed) {
        loading = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
