import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract interface class TokenStore {
  Future<String?> read();
  Future<void> write(String token);
  Future<void> clear();
}

abstract interface class RememberMeStore {
  Future<bool> readRememberMe();
  Future<void> setRememberMe(bool enabled);
}

class SecureTokenStore implements TokenStore, RememberMeStore {
  SecureTokenStore({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.unlocked_this_device,
            ),
          );
  final FlutterSecureStorage _storage;
  static const _key = 'chatpdf.access_token';
  String? _sessionToken;
  static const _rememberKey = 'chatpdf.remember_me';
  @override
  Future<bool> readRememberMe() async =>
      await _storage.read(key: _rememberKey) == 'true';
  @override
  Future<void> setRememberMe(bool enabled) async {
    if (!enabled) await _storage.delete(key: _key);
    await _storage.write(key: _rememberKey, value: enabled.toString());
  }

  @override
  Future<String?> read() async =>
      _sessionToken ??
      (await readRememberMe() ? await _storage.read(key: _key) : null);
  @override
  Future<void> write(String token) async {
    if (await readRememberMe()) {
      await _storage.write(key: _key, value: token);
    } else {
      await _storage.delete(key: _key);
    }
    _sessionToken = token;
  }

  @override
  Future<void> clear() async {
    await _storage.delete(key: _key);
    _sessionToken = null;
  }
}
