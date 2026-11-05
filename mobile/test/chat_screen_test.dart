import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:chatpdf_mobile/ui/screens/chat_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:go_router/go_router.dart';

import 'support.dart';

Future<void> mountChat(
  WidgetTester tester,
  Harness h, {
  String? conversation,
  bool dark = false,
}) async {
  await tester.binding.setSurfaceSize(const Size(390, 844));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF246BFD),
          brightness: dark ? Brightness.dark : Brightness.light,
        ),
      ),
      home: RepaintBoundary(
        key: const ValueKey('chat-preview'),
        child: ChatScreen(
          repository: h.documents,
          documentId: 'doc-1',
          conversationId: conversation,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> unmountChat(WidgetTester tester, Harness h) async {
  await tester.pumpWidget(const SizedBox.shrink());
  h.dispose();
}

void main() {
  setUpAll(() async {
    // Optional readable screenshots; normal tests use Flutter's test fonts.
    for (final entry in {
      'Roboto': Platform.environment['CHAT_PREVIEW_FONT_PATH'],
      'MaterialIcons': Platform.environment['CHAT_PREVIEW_ICONS_PATH'],
    }.entries) {
      if (entry.value == null) continue;
      final loader = FontLoader(entry.key)
        ..addFont(
          File(entry.value!)
              .readAsBytes()
              .then((bytes) => ByteData.sublistView(bytes)),
        );
      await loader.load();
    }
  });
  testWidgets(
    'suggestion sends once, shows pending question, and renders answer citations',
    (tester) async {
      final response = Completer<http.Response>();
      var requests = 0;
      final h = Harness((request) async {
        requests++;
        expect(request.url.path, '/api/v1/documents/doc-1/chat');
        expect(
          jsonDecode(request.body)['question'],
          'Summarize the key ideas in this PDF.',
        );
        return response.future;
      }, token: 'token');
      await mountChat(tester, h);
      expect(find.text('Make sense of your PDF'), findsOneWidget);
      await tester.tap(find.text('Summarize the key ideas in this PDF.'));
      await tester.pump();
      expect(
        tester
            .widget<IconButton>(
              find.byWidgetPredicate(
                (widget) =>
                    widget is IconButton && widget.tooltip == 'Send question',
              ),
            )
            .onPressed,
        isNull,
      );
      expect(requests, 1);
      response.complete(
        http.Response(
          jsonEncode({
            'conversation_id': 'conversation-1',
            'message': {
              'role': 'assistant',
              'content': '## Key ideas\n\nThe document explains **three core principles**.\n\n- Understand the evidence\n- Connect the ideas\n- Review the sources',
              'citations': [
                {
                  'page_number': 3,
                  'element_type': 'paragraph',
                  'snippet': 'Supporting evidence.',
                },
              ],
            },
          }),
          200,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Page 3 · paragraph'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
      expect(requests, 1);
      final preview = Platform.environment['CHAT_PREVIEW_PATH'];
      if (preview != null) {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('chat-preview')),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 2);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(preview).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      expect(tester.takeException(), isNull);
      await unmountChat(tester, h);
    },
  );

  testWidgets(
    'failed send restores draft and allows a successful retry in dark mode',
    (tester) async {
      var requests = 0;
      final h = Harness(
        (_) async => ++requests == 1
            ? http.Response('', 503)
            : http.Response(
                '{"conversation_id":"c-1","message":{"role":"assistant","content":"Answer","citations":[]}}',
                200,
              ),
        token: 'token',
      );
      await mountChat(tester, h, dark: true);
      await tester.enterText(find.byType(TextField), 'Explain the conclusion.');
      await tester.tap(
        find.byWidgetPredicate(
          (widget) => widget is IconButton && widget.tooltip == 'Send question',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('chat-error')), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Explain the conclusion.',
      );
      expect(
        tester
            .widget<IconButton>(
              find.byWidgetPredicate(
                (widget) =>
                    widget is IconButton && widget.tooltip == 'Send question',
              ),
            )
            .onPressed,
        isNotNull,
      );
      await tester.tap(
        find.byWidgetPredicate(
          (widget) => widget is IconButton && widget.tooltip == 'Send question',
        ),
      );
      await tester.pumpAndSettle();
      expect(requests, 2);
      expect(find.byKey(const ValueKey('chat-error')), findsNothing);
      expect(tester.takeException(), isNull);
      await unmountChat(tester, h);
    },
  );

  testWidgets('citation opens its document page with the supporting snippet', (
    tester,
  ) async {
    final h = Harness(
      (_) async => http.Response(
        '[{"role":"assistant","content":"Supported answer","citations":[{"page_number":7,"element_type":"table","snippet":"Exact source passage"}]}]',
        200,
      ),
      token: 'token',
    );
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => ChatScreen(
            repository: h.documents,
            documentId: 'doc-1',
            conversationId: 'c-1',
          ),
        ),
        GoRoute(
          path: '/documents/:document/pages/:page',
          builder: (_, state) => Scaffold(
            body: Text(
              '${state.pathParameters['document']} / ${state.pathParameters['page']} / ${state.extra}',
            ),
          ),
        ),
      ],
    );
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Page 7 · table'));
    await tester.tap(find.text('Page 7 · table'));
    await tester.pumpAndSettle();
    expect(find.text('doc-1 / 7 / Exact source passage'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await unmountChat(tester, h);
    router.dispose();
  });

  testWidgets(
    'history failure blocks sending until retry loads existing messages',
    (tester) async {
      var requests = 0;
      final h = Harness((request) async {
        expect(
          request.url.path,
          '/api/v1/documents/doc-1/conversations/c-1/messages',
        );
        return ++requests == 1
            ? http.Response('', 503)
            : http.Response(
                '[{"role":"user","content":"Earlier question"},{"role":"assistant","content":"Earlier answer","citations":[{"page_number":2,"element_type":"table"}]}]',
                200,
              );
      }, token: 'token');
      await mountChat(tester, h, conversation: 'c-1');
      expect(find.text('Retry loading'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      await tester.tap(find.text('Retry loading'));
      await tester.pumpAndSettle();
      expect(find.text('Page 2 · table'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
      expect(requests, 2);
      expect(tester.takeException(), isNull);
      await unmountChat(tester, h);
    },
  );
}
