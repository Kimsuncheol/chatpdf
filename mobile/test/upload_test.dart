import 'dart:async';
import 'dart:convert';

import 'package:chatpdf_mobile/core/files/pdf_picker.dart';
import 'package:chatpdf_mobile/core/network/api_client.dart';
import 'package:chatpdf_mobile/state/upload_controller.dart';
import 'package:chatpdf_mobile/ui/screens/upload_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'support.dart';

class FakePicker implements PdfPicker {
  FakePicker(this.file);
  SelectedPdf? file;
  @override
  Future<SelectedPdf?> pick() async => file;
}

SelectedPdf selected({String name = 'Research.pdf', int size = 10}) =>
    SelectedPdf(
      name: name,
      size: size,
      openRead: () => Stream.fromIterable([
        [1, 2, 3, 4, 5],
        [6, 7, 8, 9, 10],
      ]),
    );
Map<String, dynamic> statusJson({String state = 'queued', int pages = 0}) => {
  'document': {
    'id': 'doc-1',
    'name': 'Research.pdf',
    'status': state == 'completed'
        ? 'ready'
        : state == 'cancelled' || state == 'failed'
        ? 'failed'
        : 'processing',
    'processed_pages': pages,
    'total_pages': 6,
  },
  'job': {
    'id': 'job-1',
    'document_id': 'doc-1',
    'status': state,
    'stage': state == 'running' ? 'extracting' : state,
    'next_page': pages + 1,
    'retryable': state != 'completed',
    'error_code': state == 'failed' ? 'batch_timeout' : null,
  },
};
http.Response statusResponse({String state = 'queued', int pages = 0}) =>
    http.Response(jsonEncode(statusJson(state: state, pages: pages)), 200);

void main() {
  test(
    'client validation rejects unsupported, empty, and oversized selections',
    () async {
      final h = Harness(
        (_) async => http.Response('{"max_bytes":20,"max_pages":10}', 200),
        token: 'token',
      );
      final picker = FakePicker(selected(name: 'not-a-pdf.txt'));
      final controller = UploadController(h.documents, picker);
      addTearDown(() {
        controller.dispose();
        h.dispose();
      });
      await controller.choose();
      expect(controller.error, contains('Choose a PDF'));
      expect(controller.filename, isNull);
      picker.file = selected(size: 0);
      await controller.choose();
      expect(controller.error, contains('empty'));
      picker.file = selected(size: 21);
      await controller.choose();
      expect(controller.error, contains('too large'));
      picker.file = null;
      await controller.choose();
      expect(controller.busy, isFalse);
    },
  );

  test('upload streams bytes with authentication, reports progress, and gets a receipt', () async {
    final progress = <int>[];
    final h = Harness((request) async {
      expect(request.url.path, '/api/v1/documents/upload');
      expect(request.headers['Authorization'], 'Bearer token');
      expect(request.headers['Content-Type'], 'application/pdf');
      expect(request.headers['Idempotency-Key'], 'a-key');
      expect(
        Uri.decodeComponent(request.headers['X-Filename']!),
        'Research.pdf',
      );
      expect(request.bodyBytes, List.generate(10, (i) => i + 1));
      return statusResponse();
    }, token: 'token');
    addTearDown(h.dispose);
    final result = await h.documents.upload(
      selected(),
      'a-key',
      Completer<void>().future,
      (sent, total) {
        progress.add(sent);
        expect(total, 10);
      },
    );
    expect(progress, [5, 10]);
    expect(result.document.id, 'doc-1');
  });

  test('retry reconciles an accepted upload after a lost response without re-sending bytes', () async {
    var posts = 0, lookups = 0;
    final keys = <String>[];
    final h = Harness((request) async {
      if (request.url.path.endsWith('/limits')) {
        return http.Response('{"max_bytes":100}', 200);
      }
      if (request.url.path.contains('/uploads/')) {
        keys.add(request.url.path.split('/').last);
        return ++lookups == 1 ? http.Response('', 404) : statusResponse();
      }
      posts++;
      throw http.ClientException('Response was lost');
    }, token: 'token');
    final controller = UploadController(h.documents, FakePicker(selected()));
    addTearDown(() {
      controller.dispose();
      h.dispose();
    });
    await controller.choose();
    expect(await controller.upload(), isFalse);
    expect(controller.error, contains('interrupted'));
    expect(await controller.upload(), isTrue);
    expect(posts, 1);
    expect(keys[0], keys[1]);
    expect(controller.documentId, 'doc-1');
  });

  test(
    'stop transfer is responsive even while checking for an accepted upload',
    () async {
      final lookup = Completer<http.Response>();
      final h = Harness(
        (request) async => request.url.path.endsWith('/limits')
            ? http.Response('{"max_bytes":100}', 200)
            : lookup.future,
        token: 'token',
      );
      final controller = UploadController(h.documents, FakePicker(selected()));
      addTearDown(() {
        controller.dispose();
        h.dispose();
      });
      await controller.choose();
      final uploading = controller.upload();
      controller.stopTransfer();
      expect(await uploading, isFalse);
      expect(controller.notice, contains('Transfer stopped'));
      expect(controller.busy, isFalse);
      lookup.complete(http.Response('', 404));
    },
  );

  for (final code in [
    'unsupported_pdf',
    'corrupt_pdf',
    'encrypted_pdf',
    'oversized_pdf',
  ]) {
    test('API maps $code to a safe validation message', () async {
      final h = Harness(
        (_) async => http.Response(
          jsonEncode({
            'error': {'code': code, 'message': 'private diagnostic'},
          }),
          422,
        ),
        token: 'token',
      );
      addTearDown(h.dispose);
      await expectLater(
        h.documents.upload(
          selected(),
          'key',
          Completer<void>().future,
          (_, _) {},
        ),
        throwsA(
          isA<ApiException>()
              .having((error) => error.code, 'code', code)
              .having(
                (error) => error.message,
                'message',
                isNot(contains('private diagnostic')),
              ),
        ),
      );
    });
  }

  test(
    'cancel fences an older status response, and resume preserves progress',
    () async {
      final old = Completer<http.Response>();
      final h = Harness((request) async {
        if (request.url.path.endsWith('/cancel')) {
          return statusResponse(state: 'cancelled', pages: 3);
        }
        if (request.url.path.endsWith('/retry')) {
          return statusResponse(pages: 3);
        }
        return old.future;
      }, token: 'token');
      final controller = UploadController(
        h.documents,
        FakePicker(null),
        documentId: 'doc-1',
      );
      addTearDown(() {
        controller.dispose();
        h.dispose();
      });
      final polling = controller.refresh();
      await controller.cancelProcessing();
      old.complete(statusResponse(state: 'running'));
      await polling;
      expect(controller.status!.job!.status, 'cancelled');
      expect(controller.status!.document.processedPages, 3);
      await controller.resumeProcessing();
      expect(controller.status!.document.processedPages, 3);
      expect(controller.status!.active, isTrue);
    },
  );

  testWidgets('status polling reaches ready and stops on terminal state', (
    tester,
  ) async {
    var requests = 0;
    final h = Harness(
      (_) async => ++requests == 1
          ? statusResponse(state: 'running', pages: 3)
          : statusResponse(state: 'completed', pages: 6),
      token: 'token',
    );
    final controller = UploadController(
      h.documents,
      FakePicker(null),
      documentId: 'doc-1',
    );
    await controller.start();
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(controller.status!.document.isReady, isTrue);
    await tester.pump(const Duration(seconds: 10));
    expect(requests, 2);
    controller.dispose();
    h.dispose();
  });

  testWidgets(
    'file-selection UI reports validation errors and keeps selection usable',
    (tester) async {
      final h = Harness(
        (_) async => http.Response('{"max_bytes":100}', 200),
        token: 'token',
      );
      final picker = FakePicker(selected(size: 101));
      await tester.pumpWidget(
        MaterialApp(
          home: UploadScreen(repository: h.documents, picker: picker),
        ),
      );
      await tester.tap(find.text('Choose PDF'));
      await tester.pumpAndSettle();
      expect(find.textContaining('too large'), findsOneWidget);
      picker.file = selected();
      await tester.tap(find.text('Choose PDF'));
      await tester.pumpAndSettle();
      expect(find.text('Research.pdf'), findsOneWidget);
      expect(find.text('Upload / retry same PDF'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      h.dispose();
    },
  );
}
