import 'dart:async';
import 'dart:convert';

import 'package:chatpdf_mobile/app/app.dart';
import 'package:chatpdf_mobile/state/library_controller.dart';
import 'package:chatpdf_mobile/ui/widgets/document_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'support.dart';

Map<String, dynamic> document(
  String id,
  String name, {
  String status = 'ready',
}) => {
  'id': id,
  'name': name,
  'status': status,
  'uploaded_at': '2026-10-25T10:00:00Z',
  'processed_pages': 12,
  'total_pages': 12,
};
http.Response page(List<Map<String, dynamic>> items, {String? cursor}) =>
    http.Response(jsonEncode({'items': items, 'next_cursor': cursor}), 200);

void main() {
  test(
    'pagination and retry preserve items, search parameters, and bearer auth',
    () async {
      var failNext = true;
      final h = Harness((request) async {
        expect(request.headers['Authorization'], 'Bearer token');
        expect(request.url.queryParameters['limit'], '20');
        if (request.url.queryParameters['cursor'] == 'page-2') {
          if (failNext) {
            failNext = false;
            return http.Response('', 503);
          }
          return page([document('b', 'Second.pdf')]);
        }
        return page([document('a', 'First.pdf')], cursor: 'page-2');
      }, token: 'token');
      final controller = LibraryController(h.documents);
      addTearDown(() {
        controller.dispose();
        h.dispose();
      });
      await controller.refresh();
      await controller.loadMore();
      expect(controller.documents.single.id, 'a');
      expect(controller.hasMore, isTrue);
      expect(controller.error, isNotNull);
      await controller.loadMore();
      expect(controller.documents.map((d) => d.id), ['a', 'b']);
      expect(controller.hasMore, isFalse);
    },
  );

  testWidgets(
    'debounced search ignores an old response and resets pagination',
    (tester) async {
      final old = Completer<http.Response>();
      final queries = <String?>[];
      final h = Harness((request) async {
        final q = request.url.queryParameters['q'];
        queries.add(q);
        if (q == null) return old.future;
        expectSync(request.url.queryParameters['cursor'], isNull);
        return page([document('new', 'New match.pdf')]);
      }, token: 'token');
      final controller = LibraryController(h.documents);
      final pending = controller.refresh();
      await tester.pump();
      controller.search('match');
      await tester.pump(const Duration(milliseconds: 299));
      expect(queries, [null]);
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump();
      expect(queries, [null, 'match']);
      old.complete(
        page([document('stale', 'Stale.pdf')], cursor: 'stale-cursor'),
      );
      await pending;
      await tester.pumpAndSettle();
      expect(controller.error, isNull);
      expect(controller.documents.single.id, 'new');
      expect(controller.hasMore, isFalse);
      controller.dispose();
      h.dispose();
    },
  );

  test(
    'failed deletion retains the item, loads its tombstone, and supports retry',
    () async {
      var fail = true;
      final h = Harness((request) async {
        if (request.method == 'DELETE') {
          if (fail) {
            fail = false;
            return http.Response('', 503);
          }
          return http.Response('', 204);
        }
        if (request.url.path.endsWith('/a')) {
          return http.Response(
            jsonEncode(document('a', 'First.pdf', status: 'deleting')),
            200,
          );
        }
        return page([document('a', 'First.pdf')]);
      }, token: 'token');
      final controller = LibraryController(h.documents);
      addTearDown(() {
        controller.dispose();
        h.dispose();
      });
      await controller.refresh();
      expect(await controller.delete(controller.documents.single), isFalse);
      expect(controller.documents.single.canOpen, isFalse);
      expect(controller.deleteError, contains('try deleting'));
      expect(await controller.delete(controller.documents.single), isTrue);
      expect(controller.documents, isEmpty);
    },
  );

  test(
    'stale in-flight list cannot resurrect a successfully deleted item',
    () async {
      final response = Completer<http.Response>();
      var calls = 0;
      final h = Harness((request) async {
        if (request.method == 'DELETE') return http.Response('', 204);
        return ++calls == 1
            ? page([document('a', 'First.pdf')])
            : response.future;
      }, token: 'token');
      final controller = LibraryController(h.documents);
      addTearDown(() {
        controller.dispose();
        h.dispose();
      });
      await controller.refresh();
      final pending = controller.refresh();
      expect(await controller.delete(controller.documents.single), isTrue);
      response.complete(page([document('a', 'First.pdf')]));
      await pending;
      expect(controller.documents, isEmpty);
    },
  );

  testWidgets(
    'library metadata, search, pagination, confirmation, and delete progress',
    (tester) async {
      final deletion = Completer<http.Response>();
      final queries = <String?>[];
      var deleteCalls = 0;
      final h = Harness((request) async {
        if (request.url.path.endsWith('/me')) {
          return http.Response(
            '{"id":"u","email":"user@example.com","subscription_tier":"free"}',
            200,
          );
        }
        if (request.method == 'DELETE') {
          deleteCalls++;
          return deletion.future;
        }
        final query = request.url.queryParameters['q'];
        queries.add(query);
        if (query != null) return page([]);
        if (request.url.queryParameters['cursor'] != null) {
          return page([document('b', 'Second.pdf', status: 'processing')]);
        }
        return page([document('a', 'Research.pdf')], cursor: 'next');
      }, token: 'token');
      await h.session.restore();
      await tester.pumpWidget(
        ChatPdfApp(session: h.session, documents: h.documents),
      );
      await tester.pumpAndSettle();
      expect(find.text('Upload PDF'), findsOneWidget);
      expect(find.text('Research.pdf'), findsOneWidget);
      expect(find.text('Ready'), findsOneWidget);
      expect(find.text('12 pages'), findsOneWidget);
      expect(find.textContaining('Uploaded '), findsOneWidget);
      await tester.ensureVisible(find.text('Load more documents'));
      await tester.tap(find.text('Load more documents'));
      await tester.pumpAndSettle();
      expect(find.byType(DocumentCard), findsNWidgets(2));
      await tester.ensureVisible(find.byTooltip('Delete Research.pdf'));
      await tester.tap(find.byTooltip('Delete Research.pdf'));
      await tester.pumpAndSettle();
      expect(find.textContaining('cannot be undone'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(deleteCalls, 0);
      await tester.tap(find.byTooltip('Delete Research.pdf'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete document'));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Open document'),
            )
            .onPressed,
        isNull,
      );
      deletion.complete(http.Response('', 204));
      await tester.pumpAndSettle();
      expect(deleteCalls, 1);
      expect(find.text('Research.pdf'), findsNothing);
      await tester.enterText(
        find.byKey(const ValueKey('document-search')),
        'missing',
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(queries.last, 'missing');
      expect(find.text('No documents match your search.'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      h.dispose();
    },
  );

  testWidgets('initial loading and error state can retry to an empty library', (
    tester,
  ) async {
    final first = Completer<http.Response>();
    var requests = 0;
    final h = Harness((request) async {
      if (request.url.path.endsWith('/me')) {
        return http.Response(
          '{"id":"u","email":"user@example.com","subscription_tier":"free"}',
          200,
        );
      }
      return ++requests == 1 ? first.future : page([]);
    }, token: 'token');
    await h.session.restore();
    await tester.pumpWidget(
      ChatPdfApp(session: h.session, documents: h.documents),
    );
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    first.complete(http.Response('', 503));
    await tester.pumpAndSettle();
    expect(find.text('Try again'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(
      find.text('Your library is empty. Upload a PDF to get started.'),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    h.dispose();
  });
}
