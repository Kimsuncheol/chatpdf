import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:chatpdf_mobile/core/config/app_config.dart';
import 'package:chatpdf_mobile/core/network/api_client.dart';
import 'package:chatpdf_mobile/state/session_controller.dart';

import 'support.dart';

void main() {
  test('configuration requires HTTPS and preserves the API prefix', () {
    for (final value in [
      '',
      'http://localhost:5000',
      'https://user:secret@example.com',
      'https://example.com?token=x',
    ]) {
      expect(
        () => AppConfig(environment: 'production', apiBaseUrl: value),
        throwsFormatException,
      );
    }
    expect(
      AppConfig(
        environment: 'production',
        apiBaseUrl: 'https://example.com/api/v1',
      ).apiBaseUri.path,
      '/api/v1/',
    );
    expect(
      () =>
          AppConfig(environment: 'staging', apiBaseUrl: 'https://example.com'),
      throwsFormatException,
    );
  });
  test('sign in stores token then validates user; auth body carries no model or tier', () async {
    final h = Harness((request) async {
      expect(request.followRedirects, isFalse);
      if (request.url.path.endsWith('/login')) {
        expect(request.headers['Authorization'], isNull);
        expect(jsonDecode(request.body), {
          'email': 'reader@example.com',
          'password': 'password',
        });
        return http.Response('{"access_token":"server-token"}', 200);
      }
      expect(request.url.toString(), 'https://api.example.com/api/v1/auth/me');
      expect(request.headers['Authorization'], 'Bearer server-token');
      return http.Response(
        '{"id":"user-1","email":"reader@example.com","subscription_tier":"free"}',
        200,
      );
    });
    addTearDown(h.dispose);
    await h.session.authenticate('reader@example.com', 'password');
    expect(h.tokens.value, 'server-token');
    expect(h.session.status, SessionStatus.signedIn);
    expect(h.session.user?.subscription, 'free');
    await h.session.signOut();
    expect(h.tokens.value, isNull);
    expect(h.session.user, isNull);
  });
  test('401 invalidates saved credentials and session', () async {
    final h = Harness((_) async => http.Response('', 401), token: 'expired');
    addTearDown(h.dispose);
    await h.session.restore();
    expect(h.session.status, SessionStatus.signedOut);
    expect(h.tokens.value, isNull);
  });
  test(
    'server outage preserves saved credentials and exposes retry state',
    () async {
      final h = Harness((_) async => http.Response('', 503), token: 'saved');
      addTearDown(h.dispose);
      await h.session.restore();
      expect(h.session.status, SessionStatus.unavailable);
      expect(h.tokens.value, 'saved');
    },
  );
  test('stale unauthorized token cannot clear a new session', () async {
    final h = Harness((_) async => http.Response('', 200), token: 'new');
    addTearDown(h.dispose);
    await h.session.invalidate('old');
    expect(h.tokens.value, 'new');
  });
  test('rejects absolute URLs and unauthenticated document access before transport', () async {
    final h = Harness((_) async => fail('Request must not reach transport'));
    addTearDown(h.dispose);
    await expectLater(
      h.api.get('https://other.example.com'),
      throwsArgumentError,
    );
    await expectLater(h.api.get('../elsewhere'), throwsArgumentError);
    await expectLater(h.documents.list(), throwsA(isA<ApiException>()));
  });
  test(
    'chat scopes document and conversation, preserving citation page and type',
    () async {
      final h = Harness((request) async {
        expect(request.url.path, '/api/v1/documents/doc-1/chat');
        expect(jsonDecode(request.body), {
          'question': 'What does it say?',
          'conversation_id': 'conversation-1',
        });
        return http.Response(
          jsonEncode({
            'conversation_id': 'conversation-1',
            'message': {
              'role': 'assistant',
              'content': 'The document supports this answer.',
              'citations': [
                {'page_number': 12, 'element_type': 'table'},
              ],
            },
          }),
          200,
        );
      }, token: 'token');
      addTearDown(h.dispose);
      final result = await h.documents.ask(
        'doc-1',
        'What does it say?',
        conversationId: 'conversation-1',
      );
      expect(result.message.citations.single.pageNumber, 12);
      expect(result.message.citations.single.elementType, 'table');
    },
  );
}
