import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:chatpdf_mobile/state/session_controller.dart';

import 'support.dart';

const account =
    '{"id":"u-1","email":"reader@example.com","subscription_tier":"free"}';

class FailingTokens extends MemoryTokens {
  FailingTokens(super.value);
  bool failWrite = false;
  bool failClear = false;
  @override
  Future<void> write(String token) async {
    if (failWrite) throw StateError('Storage unavailable');
    await super.write(token);
  }

  @override
  Future<void> clear() async {
    if (failClear) throw StateError('Storage unavailable');
    await super.clear();
  }
}

void main() {
  test('registration uses public endpoint, validates account, and never sends confirmation', () async {
    final requests = <http.Request>[];
    final h = Harness((request) async {
      requests.add(request);
      if (request.url.path.endsWith('/register')) {
        expect(request.headers['Authorization'], isNull);
        expect(
          request.body,
          '{"email":"reader@example.com","password":"password"}',
        );
        return http.Response('{"access_token":"registered"}', 201);
      }
      expect(request.headers['Authorization'], 'Bearer registered');
      return http.Response(account, 200);
    });
    addTearDown(h.dispose);
    expect(
      await h.session.authenticate(
        ' reader@example.com ',
        'password',
        create: true,
      ),
      isTrue,
    );
    expect(requests.map((r) => r.url.path), [
      '/api/v1/auth/register',
      '/api/v1/auth/me',
    ]);
    expect(h.session.status, SessionStatus.signedIn);
    expect(h.session.busy, isFalse);
  });

  test(
    'credentials and account conflicts have safe action-specific errors',
    () async {
      final login = Harness(
        (_) async => http.Response('private diagnostics', 401),
      );
      final register = Harness(
        (_) async => http.Response('private diagnostics', 409),
      );
      addTearDown(login.dispose);
      addTearDown(register.dispose);
      expect(
        await login.session.authenticate('reader@example.com', 'incorrect'),
        isFalse,
      );
      expect(login.session.error, 'The email or password is incorrect.');
      expect(
        await register.session.authenticate(
          'reader@example.com',
          'password',
          create: true,
        ),
        isFalse,
      );
      expect(register.session.error, contains('already uses this email'));
      expect(register.tokens.value, isNull);
      register.session.clearFeedback();
      expect(register.session.error, isNull);
    },
  );

  for (final response in [
    '{}',
    '{"access_token":123}',
    '{"access_token":" "}',
  ]) {
    test('malformed token response fails safely: $response', () async {
      final h = Harness((_) async => http.Response(response, 200));
      addTearDown(h.dispose);
      expect(
        await h.session.authenticate('reader@example.com', 'password'),
        isFalse,
      );
      expect(h.session.status, SessionStatus.signedOut);
      expect(h.tokens.value, isNull);
      expect(h.session.error, contains('invalid sign-in response'));
      expect(h.session.busy, isFalse);
    });
  }

  test('duplicate login is blocked while waiting for a response', () async {
    final response = Completer<http.Response>();
    var requests = 0;
    final h = Harness((request) async {
      requests++;
      return request.url.path.endsWith('/login')
          ? response.future
          : http.Response(account, 200);
    });
    addTearDown(h.dispose);
    final pending = h.session.authenticate('reader@example.com', 'password');
    expect(h.session.action, AuthAction.signIn);
    expect(
      await h.session.authenticate('reader@example.com', 'password'),
      isFalse,
    );
    await Future<void>.delayed(Duration.zero);
    expect(requests, 1);
    response.complete(http.Response('{"access_token":"token"}', 200));
    expect(await pending, isTrue);
    expect(h.session.busy, isFalse);
  });

  test(
    'reset has controller-owned loading and generic success without a token',
    () async {
      final response = Completer<http.Response>();
      final h = Harness((request) async {
        expect(request.url.path, '/api/v1/auth/reset-password');
        expect(request.headers['Authorization'], isNull);
        expect(request.body, '{"email":"reader@example.com"}');
        return response.future;
      });
      addTearDown(h.dispose);
      final pending = h.session.resetPassword(' reader@example.com ');
      expect(h.session.action, AuthAction.resetPassword);
      expect(await h.session.resetPassword('reader@example.com'), isFalse);
      response.complete(http.Response('', 204));
      expect(await pending, isTrue);
      expect(h.session.notice, startsWith('If an account exists'));
      expect(h.tokens.value, isNull);
      expect(h.session.busy, isFalse);
    },
  );

  test(
    'reset failure is retryable and does not claim instructions were sent',
    () async {
      final h = Harness((_) async => http.Response('', 429));
      addTearDown(h.dispose);
      expect(await h.session.resetPassword('reader@example.com'), isFalse);
      expect(h.session.error, contains('Too many requests'));
      expect(h.session.notice, isNull);
      expect(h.session.busy, isFalse);
    },
  );

  test(
    'secure storage write failure prevents an authenticated session',
    () async {
      final tokens = FailingTokens(null)..failWrite = true;
      final h = Harness(
        (_) async => http.Response('{"access_token":"token"}', 200),
        tokenStore: tokens,
      );
      addTearDown(h.dispose);
      expect(
        await h.session.authenticate('reader@example.com', 'password'),
        isFalse,
      );
      expect(h.session.status, SessionStatus.signedOut);
      expect(h.session.user, isNull);
      expect(h.tokens.value, isNull);
      expect(h.session.error, contains('securely sign in'));
    },
  );

  test('sign out reports secure storage failure and permits retry', () async {
    final tokens = FailingTokens('token');
    final h = Harness(
      (_) async => http.Response(account, 200),
      tokenStore: tokens,
    );
    addTearDown(h.dispose);
    await h.session.restore();
    tokens.failClear = true;
    expect(await h.session.signOut(), isFalse);
    expect(h.session.status, SessionStatus.signedIn);
    expect(h.session.error, contains('Please try signing out again'));
    expect(h.session.busy, isFalse);
    tokens.failClear = false;
    expect(await h.session.signOut(), isTrue);
    expect(h.session.user, isNull);
    expect(h.tokens.value, isNull);
  });

  test('expiration defeats a late successful restore response', () async {
    final response = Completer<http.Response>();
    final started = Completer<void>();
    final h = Harness((_) async {
      started.complete();
      return response.future;
    }, token: 'old');
    addTearDown(h.dispose);
    final restore = h.session.restore();
    await started.future;
    await h.session.invalidate('old');
    response.complete(http.Response(account, 200));
    await restore;
    expect(h.session.status, SessionStatus.signedOut);
    expect(h.session.user, isNull);
    expect(h.tokens.value, isNull);
    expect(h.session.error, contains('session expired'));
  });

  test(
    'missing stored token invalidates a previously restored session',
    () async {
      final h = Harness(
        (_) async => http.Response(account, 200),
        token: 'token',
      );
      addTearDown(h.dispose);
      await h.session.restore();
      await h.tokens.clear();
      await expectLater(h.documents.list(), throwsException);
      expect(h.session.status, SessionStatus.signedOut);
    },
  );
}
