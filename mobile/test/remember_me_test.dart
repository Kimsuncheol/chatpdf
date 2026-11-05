import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:chatpdf_mobile/core/auth/token_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('ordinary session does not survive a new store', () async {
    final store = SecureTokenStore();
    await store.write('temporary');
    expect(await store.read(), 'temporary');
    expect(await SecureTokenStore().read(), isNull);
  });

  test('remembered session survives restart until disabled', () async {
    final store = SecureTokenStore();
    await store.setRememberMe(true);
    await store.write('remember_token');
    final restarted = SecureTokenStore();
    expect(await restarted.readRememberMe(), isTrue);
    expect(await restarted.read(), 'remember_token');
    await restarted.setRememberMe(false);
    expect(await SecureTokenStore().readRememberMe(), isFalse);
    expect(await SecureTokenStore().read(), isNull);
  });

  test('sign out clears token while retaining checkbox preference', () async {
    final store = SecureTokenStore();
    await store.setRememberMe(true);
    await store.write('remember_token');
    await store.clear();
    expect(await store.read(), isNull);
    expect(await SecureTokenStore().read(), isNull);
    expect(await SecureTokenStore().readRememberMe(), isTrue);
  });
}
