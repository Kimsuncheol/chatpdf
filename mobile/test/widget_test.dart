import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:chatpdf_mobile/app/app.dart';
import 'package:chatpdf_mobile/app/navigation/app_routes.dart';
import 'package:chatpdf_mobile/ui/screens/chat_screen.dart';

import 'support.dart';

void main() {
  testWidgets(
    'auth screens, protected route, all signed-in destinations, and logout',
    (tester) async {
      final h = Harness((request) async {
        if (request.url.path.endsWith('/login')) {
          return http.Response('{"access_token":"token"}', 200);
        }
        if (request.url.path.endsWith('/me')) {
          return http.Response(
            '{"id":"user-1","email":"reader@example.com","subscription_tier":"free"}',
            200,
          );
        }
        if (request.url.path.endsWith('/documents/doc-1')) {
          return http.Response(
            '{"id":"doc-1","name":"Example PDF","status":"processing","processed_pages":5,"total_pages":20}',
            200,
          );
        }
        if (request.url.path.endsWith('/conversations')) {
          return http.Response(
            '[{"id":"c-1","document_id":"doc-1","title":"Earlier question"}]',
            200,
          );
        }
        if (request.url.path.endsWith('/messages')) {
          return http.Response(
            '[{"role":"assistant","content":"Supported answer","citations":[{"page_number":3,"element_type":"paragraph"}]}]',
            200,
          );
        }
        return http.Response('[]', 200);
      });
      await h.session.restore();
      await tester.pumpWidget(
        ChatPdfApp(session: h.session, documents: h.documents),
      );
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'Sign in'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Create account'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'Create account'), findsOneWidget);
      await tester.tap(find.text('Back to sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Forgot password?'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'Reset password'), findsOneWidget);
      final router = GoRouter.of(tester.element(find.byType(Scaffold).first));
      router.go(AppRoutes.chat('doc-1'));
      await tester.pumpAndSettle();
      expect(find.byType(ChatScreen), findsNothing);
      await tester.enterText(
        find.byType(TextFormField).at(0),
        'reader@example.com',
      );
      await tester.enterText(find.byType(TextFormField).at(1), 'password');
      await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
      await tester.pumpAndSettle();
      expect(find.byType(ChatScreen), findsOneWidget);
      router.go(AppRoutes.library);
      await tester.pumpAndSettle();
      expect(
        find.text('Your library is empty. Upload a PDF to get started.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Upload').last);
      await tester.pumpAndSettle();
      expect(find.text('Choose PDF — coming next'), findsOneWidget);
      router.go(AppRoutes.processing('doc-1'));
      await tester.pumpAndSettle();
      expect(find.text('5 of 20 pages processed'), findsOneWidget);
      router.go(AppRoutes.history);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Earlier question'));
      await tester.pumpAndSettle();
      expect(find.text('Supported answer'), findsOneWidget);
      expect(find.text('Page 3 · paragraph'), findsOneWidget);
      router.go(AppRoutes.settings);
      await tester.pumpAndSettle();
      expect(find.text('free'), findsOneWidget);
      await tester.tap(find.text('Sign out'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'Sign in'), findsOneWidget);
      expect(h.tokens.value, isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      h.dispose();
    },
  );
}
