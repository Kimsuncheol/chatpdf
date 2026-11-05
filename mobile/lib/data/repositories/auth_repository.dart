import '../../core/network/api_client.dart';
import '../models/user.dart';
import '../models/entitlements.dart';

class AuthRepository {
  AuthRepository(this._api);
  final ApiClient _api;

  Future<String> authenticate(
    String email,
    String password, {
    bool create = false,
  }) async {
    try {
      final json = await _api.post(create ? 'auth/register' : 'auth/login', {
        'email': email,
        'password': password,
      }, authenticated: false);
      if (json is! Map<String, dynamic> ||
          json['access_token'] is! String ||
          (json['access_token'] as String).trim().isEmpty) {
        throw const ApiException(
          'The server returned an invalid sign-in response. Please try again.',
        );
      }
      return json['access_token'] as String;
    } on ApiException catch (error) {
      // Map status codes to safe, action-specific messages. Never show raw
      // server errors, which can expose diagnostics or untrusted content.
      final message = switch (error.statusCode) {
        401 when !create => 'The email or password is incorrect.',
        403 => 'Sign-in is not allowed for this account. Contact support.',
        409 when create =>
          'An account already uses this email. Sign in or reset your password.',
        400 || 422 =>
          create
              ? 'Enter a valid email and a password of 8–1024 characters.'
              : 'Check your email and password and try again.',
        _ => error.message,
      };
      throw ApiException(message, statusCode: error.statusCode);
    }
  }

  Future<User> currentUser() async {
    final json = await _api.get('auth/me');
    if (json is! Map<String, dynamic> ||
        json['id'] is! String ||
        (json['id'] as String).isEmpty ||
        json['email'] is! String ||
        (json['email'] as String).isEmpty ||
        (json['subscription_tier'] != null &&
            json['subscription_tier'] is! String)) {
      throw const ApiException(
        'The server returned an invalid account response. Please try again.',
      );
    }
    return User.fromJson(json);
  }

  Future<AccountEntitlements> entitlements() async {
    final json = await _api.get('auth/entitlements');
    try {
      return AccountEntitlements.fromJson(json as Map<String, dynamic>);
    } catch (_) {
      throw const ApiException(
        'Unable to read subscription details. Please retry.',
      );
    }
  }

  Future<void> resetPassword(String email) async {
    try {
      await _api.post('auth/reset-password', {
        'email': email,
      }, authenticated: false);
    } on ApiException catch (error) {
      throw ApiException(switch (error.statusCode) {
        404 || 501 => 'Email password reset is not configured on this server. No reset instructions were sent. Contact your account administrator.',
        400 || 422 => 'Enter a valid email address and try again.',
        _ => error.message,
      }, statusCode: error.statusCode);
    }
  }
}
