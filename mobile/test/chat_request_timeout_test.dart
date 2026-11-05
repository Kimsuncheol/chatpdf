import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'support.dart';

void main() {
  testWidgets(
    'local-model chat can finish after the ordinary 30-second request limit',
    (tester) async {
      final response = Completer<http.Response>();
      final h = Harness((_) => response.future, token: 'token');
      addTearDown(h.dispose);
      var completed = false;
      final request = h.documents.ask('doc-1', 'Summarize this PDF');
      request.then(
        (_) => completed = true,
        onError: (Object _) => completed = true,
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 31));
      expect(completed, isFalse);
      response.complete(
        http.Response(
          '{"conversation_id":"c-1","message":{"role":"assistant","content":"Verified answer","citations":[]}}',
          200,
        ),
      );
      await tester.pump();
      expect((await request).message.content, 'Verified answer');
      // Drain the HTTP client's timeout timer before leaving the test zone.
      await tester.pump(const Duration(minutes: 3));
    },
  );

  testWidgets('ordinary requests retain the shorter timeout', (tester) async {
    final response = Completer<http.Response>();
    final h = Harness((_) => response.future, token: 'token');
    addTearDown(h.dispose);
    Object? failure;
    final request = h.api.get('auth/me').catchError((Object error) {
      failure = error;
      return null;
    });
    await tester.pump();
    await tester.pump(const Duration(seconds: 31));
    await request;
    expect(failure.toString(), contains('server took too long'));
    response.complete(http.Response('{}', 200));
    await tester.pump();
  });

  test('model validation failure is shown as a retryable AI error', () async {
    final h = Harness(
      (_) async =>
          http.Response('{"error":{"code":"model_response_invalid"}}', 503),
      token: 'token',
    );
    addTearDown(h.dispose);
    await expectLater(
      h.documents.ask('doc-1', 'Summarize'),
      throwsA(
        predicate(
          (Object error) => error.toString().contains('verified answer'),
        ),
      ),
    );
  });
}
