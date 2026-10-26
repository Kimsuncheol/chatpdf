import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:chatpdf_mobile/app/app.dart';

import 'support.dart';

const account =
    '{"id":"u-1","email":"reader@example.com","subscription_tier":"free"}';
Finder field(String key) => find.byKey(ValueKey(key));
Finder submit(String label) => find.widgetWithText(FilledButton, label);

Future<void> mount(
  WidgetTester tester,
  Harness h, {
  bool restore = true,
}) async {
  if (restore) await h.session.restore();
  await tester.pumpWidget(
    ChatPdfApp(session: h.session, documents: h.documents),
  );
  await tester.pumpAndSettle();
}

Future<void> unmount(WidgetTester tester, Harness h) async {
  await tester.pumpWidget(const SizedBox.shrink());
  h.dispose();
}

void main() {
  testWidgets(
    'create form validates confirmation, blocks duplicate submits, and shows API errors',
    (tester) async {
      final response = Completer<http.Response>();
      var requests = 0;
      final h = Harness((request) async {
        requests++;
        return response.future;
      });
      await mount(tester, h);
      await tester.tap(find.widgetWithText(TextButton, 'Create account'));
      await tester.pumpAndSettle();
      await tester.tap(submit('Create account'));
      await tester.pumpAndSettle();
      expect(find.text('Enter a valid email address.'), findsOneWidget);
      expect(find.text('Enter your password.'), findsOneWidget);
      expect(find.text('Confirm your password.'), findsOneWidget);
      expect(requests, 0);
      await tester.enterText(field('auth-email'), 'reader@example.com');
      await tester.enterText(field('auth-password'), 'password');
      await tester.enterText(field('auth-confirmation'), 'different');
      await tester.ensureVisible(submit('Create account'));
      await tester.tap(submit('Create account'));
      await tester.pumpAndSettle();
      expect(find.text('Passwords do not match.'), findsOneWidget);
      expect(requests, 0);
      await tester.enterText(field('auth-confirmation'), 'password');
      await tester.ensureVisible(submit('Create account'));
      await tester.tap(submit('Create account'));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      expect(
        tester.widget<TextFormField>(field('auth-email')).enabled,
        isFalse,
      );
      expect(
        tester.widget<TextFormField>(field('auth-password')).controller!.text,
        isEmpty,
      );
      expect(
        tester
            .widget<TextFormField>(field('auth-confirmation'))
            .controller!
            .text,
        isEmpty,
      );
      response.complete(http.Response('untrusted internal message', 409));
      await tester.pumpAndSettle();
      expect(requests, 1);
      expect(find.text('Enter your password.'), findsNothing);
      expect(find.text('Confirm your password.'), findsNothing);
      expect(
        find.text(
          'An account already uses this email. Sign in or reset your password.',
        ),
        findsOneWidget,
      );
      expect(find.text('untrusted internal message'), findsNothing);
      expect(
        tester.widget<FilledButton>(submit('Create account')).onPressed,
        isNotNull,
      );
      await tester.ensureVisible(find.text('Back to sign in'));
      await tester.tap(find.text('Back to sign in'));
      await tester.pumpAndSettle();
      expect(h.session.error, isNull);
      await unmount(tester, h);
    },
  );

  testWidgets(
    'reset validates email, shows progress and generic confirmation, and clears feedback on navigation',
    (tester) async {
      final response = Completer<http.Response>();
      final h = Harness((_) async => response.future);
      await mount(tester, h);
      await tester.tap(find.text('Forgot password?'));
      await tester.pumpAndSettle();
      await tester.tap(submit('Send reset instructions'));
      await tester.pumpAndSettle();
      expect(find.text('Enter a valid email address.'), findsOneWidget);
      await tester.enterText(field('auth-email'), 'reader@example.com');
      await tester.tap(submit('Send reset instructions'));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      response.complete(http.Response('', 204));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'If an account exists, reset instructions will be sent to that email address.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Back to sign in'));
      await tester.pumpAndSettle();
      expect(h.session.notice, isNull);
      expect(h.tokens.value, isNull);
      await unmount(tester, h);
    },
  );

  testWidgets(
    'sign-in failures retain email, clear password, and permit a successful retry',
    (tester) async {
      var attempts = 0;
      final h = Harness((request) async {
        if (request.url.path.endsWith('/login')) {
          return ++attempts == 1
              ? http.Response('', 401)
              : http.Response('{"access_token":"token"}', 200);
        }
        return request.url.path.endsWith('/me')
            ? http.Response(account, 200)
            : http.Response('{"items":[],"next_cursor":null}', 200);
      });
      await mount(tester, h);
      await tester.enterText(field('auth-email'), 'reader@example.com');
      await tester.enterText(field('auth-password'), 'wrong');
      await tester.tap(submit('Sign in'));
      await tester.pumpAndSettle();
      expect(find.text('The email or password is incorrect.'), findsOneWidget);
      expect(
        tester.widget<TextFormField>(field('auth-email')).controller!.text,
        'reader@example.com',
      );
      expect(
        tester.widget<TextFormField>(field('auth-password')).controller!.text,
        isEmpty,
      );
      await tester.enterText(field('auth-password'), 'password');
      await tester.tap(submit('Sign in'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'Document library'), findsOneWidget);
      await unmount(tester, h);
    },
  );

  testWidgets(
    'startup validates saved session; later 401 returns to sign-in with an expiry message',
    (tester) async {
      final me = Completer<http.Response>();
      var expired = false;
      final h = Harness((request) async {
        if (request.url.path.endsWith('/me')) return me.future;
        return expired
            ? http.Response('', 401)
            : http.Response('{"items":[],"next_cursor":null}', 200);
      }, token: 'saved');
      final restoring = h.session.restore();
      await tester.pumpWidget(
        ChatPdfApp(session: h.session, documents: h.documents),
      );
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.widgetWithText(AppBar, 'Document library'), findsNothing);
      me.complete(http.Response(account, 200));
      await restoring;
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'Document library'), findsOneWidget);
      expired = true;
      await tester.tap(find.byTooltip('Refresh library'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'Sign in'), findsOneWidget);
      expect(
        find.text('Your session expired. Please sign in again.'),
        findsOneWidget,
      );
      expect(h.tokens.value, isNull);
      await unmount(tester, h);
    },
  );
}
