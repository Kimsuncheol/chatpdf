import 'dart:convert';

import 'package:chatpdf_mobile/core/auth/token_store.dart';
import 'package:chatpdf_mobile/core/config/app_config.dart';
import 'package:chatpdf_mobile/core/network/api_client.dart';
import 'package:chatpdf_mobile/data/repositories/auth_repository.dart';
import 'package:chatpdf_mobile/state/session_controller.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  for (final remember in [false, true]) {
    test('secure store login, restart, logout: remember=$remember', () async {
      var revoked = false;
      final token = remember ? 'remember_test' : 'jwt-test';
      SessionController makeSession() {
        final store = SecureTokenStore();
        final api = ApiClient(
          config: AppConfig(
            environment: 'development',
            apiBaseUrl: 'https://api.example.com/api/v1/',
          ),
          tokens: store,
          client: MockClient((request) async {
            if (request.url.path.endsWith('/login')) {
              final body = jsonDecode(request.body) as Map<String, dynamic>;
              expect(body['email'], 'reader@example.com');
              expect(body['password'], ' password with spaces ');
              expect(body['remember_me'] ?? false, remember);
              expect(request.headers['Authorization'], isNull);
              return http.Response(jsonEncode({'access_token': token}), 200);
            }
            expect(request.headers['Authorization'], 'Bearer $token');
            if (request.url.path.endsWith('/logout')) {
              revoked = true;
              return http.Response('', 204);
            }
            return revoked
                ? http.Response('', 401)
                : http.Response(
                    '{"id":"reader","email":"reader@example.com","subscription_tier":"free"}',
                    200,
                  );
          }),
        );
        addTearDown(api.close);
        final session = SessionController(AuthRepository(api), store);
        api.onUnauthorized = session.invalidate;
        addTearDown(session.dispose);
        return session;
      }

      final session = makeSession();
      await session.restore();
      await session.setRememberMe(remember);
      expect(
        await session.authenticate(
          ' reader@example.com ',
          ' password with spaces ',
        ),
        isTrue,
      );
      expect(session.status, SessionStatus.signedIn);
      final restarted = makeSession();
      await restarted.restore();
      expect(restarted.rememberMe, remember);
      expect(
        restarted.status,
        remember ? SessionStatus.signedIn : SessionStatus.signedOut,
      );
      expect(await session.signOut(), isTrue);
      expect(revoked, remember);
      final afterSignOut = makeSession();
      await afterSignOut.restore();
      expect(afterSignOut.status, SessionStatus.signedOut);
      expect(afterSignOut.rememberMe, remember);
    });
  }
}
