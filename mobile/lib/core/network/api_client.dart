import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../auth/token_store.dart';
import '../config/app_config.dart';

class ApiException implements Exception {
  const ApiException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;
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
    if (response.statusCode == 401 && token != null) {
      await onUnauthorized?.call(token);
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      // Never display arbitrary server diagnostics.
      throw ApiException(switch (response.statusCode) {
        401 => 'Your session expired or the credentials are invalid.',
        403 => 'Your account does not have access to this resource.',
        429 => 'Too many requests. Please try again later.',
        _ => 'The request failed. Please try again.',
      }, statusCode: response.statusCode);
    }
    if (response.body.isEmpty) return null;
    try {
      return jsonDecode(response.body);
    } on FormatException {
      throw const ApiException('The server returned an invalid response.');
    }
  }

  void close() => _client.close();
}
