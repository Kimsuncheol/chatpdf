import 'package:flutter/foundation.dart';

import '../core/auth/token_store.dart';
import '../core/network/api_client.dart';
import '../data/models/user.dart';
import '../data/models/entitlements.dart';
import '../data/repositories/auth_repository.dart';

enum SessionStatus { restoring, signedOut, signedIn, unavailable }

enum AuthAction { restore, signIn, createAccount, resetPassword, signOut }

/// Owns session transitions and auth operations; screens only collect form data.
class SessionController extends ChangeNotifier {
  SessionController(this._repository, this._tokens);
  final AuthRepository _repository;
  final TokenStore _tokens;
  SessionStatus _status = SessionStatus.restoring;
  User? _user;
  String? _error;
  String? _notice;
  AuthAction? _action;
  int _operation = 0;
  bool _disposed = false;

  SessionStatus get status => _status;
  User? get user => _user;
  Future<AccountEntitlements> loadEntitlements() => _repository.entitlements();
  String? get error => _error;
  String? get notice => _notice;
  AuthAction? get action => _action;
  bool get busy => _action != null;

  int _begin(AuthAction action) {
    _action = action;
    _error = null;
    _notice = null;
    final operation = ++_operation;
    _notify();
    return operation;
  }

  bool _isCurrent(int operation) => !_disposed && operation == _operation;

  void _finish(int operation) {
    if (!_isCurrent(operation)) return;
    _action = null;
    _notify();
  }

  void clearFeedback() {
    if (busy) return;
    _error = null;
    _notice = null;
    _notify();
  }

  Future<void> restore() async {
    if (busy || _disposed) return;
    _status = SessionStatus.restoring;
    _user = null;
    final operation = _begin(AuthAction.restore);
    try {
      final token = await _tokens.read();
      if (!_isCurrent(operation)) return;
      if (token == null) {
        _status = SessionStatus.signedOut;
      } else {
        final restoredUser = await _repository.currentUser();
        if (!_isCurrent(operation)) return;
        _user = restoredUser;
        _status = SessionStatus.signedIn;
      }
    } catch (error) {
      if (!_isCurrent(operation)) return;
      if (error is ApiException && error.statusCode == 401) {
        await _clearCredentials();
        if (!_isCurrent(operation)) return;
        _status = SessionStatus.signedOut;
        _error = 'Your session expired. Please sign in again.';
      } else {
        // An outage is not proof that a saved token is invalid.
        _error =
            'Unable to restore your session. Check your connection and retry.';
        _status = SessionStatus.unavailable;
      }
    } finally {
      _finish(operation);
    }
  }

  Future<bool> authenticate(
    String email,
    String password, {
    bool create = false,
  }) async {
    if (busy || _disposed) return false;
    final operation = _begin(
      create ? AuthAction.createAccount : AuthAction.signIn,
    );
    try {
      final token = await _repository.authenticate(
        email.trim(),
        password,
        create: create,
      );
      if (!_isCurrent(operation)) return false;
      await _tokens.write(token);
      if (!_isCurrent(operation)) return false;
      final authenticatedUser = await _repository.currentUser();
      if (!_isCurrent(operation)) return false;
      _user = authenticatedUser;
      _status = SessionStatus.signedIn;
      return true;
    } catch (error) {
      if (!_isCurrent(operation)) return false;
      final cleared = await _clearCredentials();
      if (!_isCurrent(operation)) return false;
      _user = null;
      _status = SessionStatus.signedOut;
      _error = !cleared
          ? 'Secure storage is unavailable. Please try again.'
          : error is ApiException
          ? error.message
          : 'Unable to securely sign in. Please try again.';
      return false;
    } finally {
      _finish(operation);
    }
  }

  Future<bool> resetPassword(String email) async {
    if (busy || _disposed) return false;
    final operation = _begin(AuthAction.resetPassword);
    try {
      await _repository.resetPassword(email.trim());
      if (!_isCurrent(operation)) return false;
      _notice = 'If an account exists, reset instructions will be sent to that email address.';
      return true;
    } catch (error) {
      if (_isCurrent(operation)) {
        _error = error is ApiException
            ? error.message
            : 'Unable to request a password reset. Please try again.';
      }
      return false;
    } finally {
      _finish(operation);
    }
  }

  Future<void> invalidate(String? rejectedToken) async {
    if (_disposed || await _tokens.read() != rejectedToken) return;
    // Invalidate pending work before awaiting storage: late responses cannot
    // bring a rejected session back. Block new auth until cleanup completes.
    final operation = _begin(AuthAction.signOut);
    _user = null;
    _status = SessionStatus.signedOut;
    _error = 'Your session expired. Please sign in again.';
    _notify();
    await _clearCredentials();
    _finish(operation);
  }

  Future<bool> signOut() async {
    if (busy || _disposed) return false;
    final operation = _begin(AuthAction.signOut);
    try {
      await _tokens.clear();
      if (!_isCurrent(operation)) return false;
      _user = null;
      _status = SessionStatus.signedOut;
      return true;
    } catch (_) {
      if (_isCurrent(operation)) {
        _error = 'Unable to clear your secure session. Please try signing out again.';
      }
      return false;
    } finally {
      _finish(operation);
    }
  }

  Future<bool> _clearCredentials() async {
    try {
      await _tokens.clear();
      return true;
    } catch (_) {
      return false;
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _operation++;
    super.dispose();
  }
}
