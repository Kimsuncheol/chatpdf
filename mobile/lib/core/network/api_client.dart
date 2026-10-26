import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../auth/token_store.dart';
import '../config/app_config.dart';

class ApiException implements Exception {
  const ApiException(this.message, {this.statusCode, this.code});
  final String message;
  final int? statusCode;
  final String? code;
  @override
  String toString() => message;
}

class ApiClient {
  ApiClient({
    required AppConfig config,
    required this._client,
    required this._tokens,
  }) : _base = config.apiBaseUri;
  final Uri _base;
  final http.Client _client;
  final TokenStore _tokens;
  Future<void> Function(String? token)? onUnauthorized;
  Future<dynamic> get(String path) => _request('GET', path);
  Future<void> delete(String path) async {
    await _request('DELETE', path);
  }

  Future<dynamic> post(
    String path,
    Map<String, dynamic> body, {
    bool authenticated = true,
  }) => _request('POST', path, body: body, authenticated: authenticated);
  Future<dynamic> _request(
    String method,
    String path, {
    Map<String, dynamic>? body,
    bool authenticated = true,
  }) async {
    // Keep credentials on the configured API origin and base path.
    final relative = Uri.parse(path);
    if (relative.hasScheme ||
        relative.hasAuthority ||
        path.startsWith('/') ||
        relative.pathSegments.any((segment) => segment == '..')) {
      throw ArgumentError('Expected a relative API path.');
    }
    final token = authenticated ? await _tokens.read() : null;
    if (authenticated && token == null) {
      await onUnauthorized?.call(null);
      throw const ApiException('Please sign in again.', statusCode: 401);
    }
    final request = http.Request(method, _base.resolveUri(relative))
      ..followRedirects = false
      ..headers['Accept'] = 'application/json';
    if (token != null) request.headers['Authorization'] = 'Bearer $token';
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    late http.Response response;
    try {
      response = await (() async => http.Response.fromStream(
        await _client.send(request),
      ))().timeout(const Duration(seconds: 30));
    } on TimeoutException {
      throw const ApiException('The server took too long. Please try again.');
    } on http.ClientException {
      throw const ApiException(
        'Unable to reach the server. Check your connection.',
      );
    }
    return _decode(response, token);
  }

  Future<dynamic> uploadPdf({
    required String name,
    required int length,
    required Stream<List<int>> bytes,
    required String uploadKey,
    required Future<void> cancelled,
    required void Function(int sent, int total) onProgress,
  }) async {
    final token = await _tokens.read();
    if (token == null) {
      await onUnauthorized?.call(null);
      throw const ApiException('Please sign in again.', statusCode: 401);
    }
    final request =
        _PdfRequest(
            _base.resolve('documents/upload'),
            bytes,
            length,
            cancelled,
            onProgress,
          )
          ..followRedirects = false
          ..headers.addAll({
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/pdf',
            'Accept': 'application/json',
            'Idempotency-Key': uploadKey,
            'X-Filename': Uri.encodeComponent(name),
          });
    try {
      final response = await Future.any([
        (() async => http.Response.fromStream(await _client.send(request)))(),
        cancelled.then<http.Response>((_) => throw const UploadCancelled()),
      ]).timeout(const Duration(minutes: 10));
      return await _decode(response, token);
    } on UploadCancelled {
      rethrow;
    } on http.RequestAbortedException {
      throw const UploadCancelled();
    } on TimeoutException {
      throw const ApiException(
        'Upload timed out. Retry the same file to check whether it was accepted.',
      );
    } on http.ClientException {
      throw const ApiException(
        'Upload interrupted. Check your connection and retry the same file.',
      );
    }
  }

  Future<dynamic> _decode(http.Response response, String? token) async {
    if (response.statusCode == 401 && token != null) {
      await onUnauthorized?.call(token);
    }
    dynamic json;
    try {
      if (response.body.isNotEmpty) json = jsonDecode(response.body);
    } on FormatException {
      if (response.statusCode >= 200 && response.statusCode < 300) {
        throw const ApiException('The server returned an invalid response.');
      }
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final value = json is Map<String, dynamic> ? json['error'] : null;
      final code = value is Map<String, dynamic> ? value['code'] : null;
      final message = switch (code) {
        'unsupported_pdf' =>
          'Choose a PDF file (.pdf). Other file types are not supported.',
        'corrupt_pdf' => 'This PDF is corrupt or cannot be read. Export a new copy and try again.',
        'encrypted_pdf' => 'Password-protected PDFs are not supported. Choose an unencrypted copy.',
        'oversized_pdf' => 'This PDF exceeds the server upload size limit. Choose a smaller PDF.',
        'too_many_pages' =>
          'This PDF exceeds the server page limit. Split it into smaller PDFs.',
        'validation_timeout' =>
          'This PDF took too long to validate. Choose a smaller PDF.',
        'not_retryable' => 'This PDF cannot be retried. Choose a new copy.',
        _ => switch (response.statusCode) {
          401 => 'Your session expired or the credentials are invalid.',
          403 => 'Your account does not have access to this resource.',
          404 => 'The requested resource is no longer available.',
          409 => 'This document is being changed. Please try again.',
          413 => 'This PDF exceeds the server upload size limit. Choose a smaller PDF.',
          429 => 'Too many requests. Please try again later.',
          _ => 'The request failed. Please try again.',
        },
      };
      throw ApiException(
        message,
        statusCode: response.statusCode,
        code: code is String && code.length <= 64 ? code : null,
      );
    }
    return json;
  }

  void close() => _client.close();
}

class UploadCancelled implements Exception {
  const UploadCancelled();
}

class _PdfRequest extends http.BaseRequest with http.Abortable {
  _PdfRequest(
    Uri url,
    this.bytes,
    int length,
    this.abortTrigger,
    this.onProgress,
  ) : super('POST', url) {
    contentLength = length;
  }
  final Stream<List<int>> bytes;
  final void Function(int sent, int total) onProgress;
  @override
  final Future<void> abortTrigger;
  @override
  http.ByteStream finalize() {
    super.finalize();
    var sent = 0;
    return http.ByteStream(
      bytes.map((chunk) {
        sent += chunk.length;
        if (sent > contentLength!) {
          throw const ApiException(
            'The selected file changed. Choose it again.',
          );
        }
        onProgress(sent, contentLength!);
        return chunk;
      }),
    );
  }
}
