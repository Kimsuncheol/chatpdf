import 'package:chatpdf_mobile/core/auth/token_store.dart';
import 'package:chatpdf_mobile/core/config/app_config.dart';
import 'package:chatpdf_mobile/core/network/api_client.dart';
import 'package:chatpdf_mobile/data/repositories/auth_repository.dart';
import 'package:chatpdf_mobile/data/repositories/document_repository.dart';
import 'package:chatpdf_mobile/state/session_controller.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class MemoryTokens implements TokenStore {
  MemoryTokens([this.value]);
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String token) async {
    value = token;
  }

  @override
  Future<void> clear() async {
    value = null;
  }
}

class Harness {
  Harness(
    Future<http.Response> Function(http.Request) handler, {
    String? token,
    MemoryTokens? tokenStore,
  }) {
    tokens = tokenStore ?? MemoryTokens(token);
    api = ApiClient(
      config: AppConfig(
        environment: 'development',
        apiBaseUrl: 'https://api.example.com/api/v1',
      ),
      client: MockClient(handler),
      tokens: tokens,
    );
    session = SessionController(AuthRepository(api), tokens);
    api.onUnauthorized = session.invalidate;
    documents = DocumentRepository(api);
  }
  late final MemoryTokens tokens;
  late final ApiClient api;
  late final SessionController session;
  late final DocumentRepository documents;
  void dispose() {
    api.close();
    session.dispose();
  }
}
