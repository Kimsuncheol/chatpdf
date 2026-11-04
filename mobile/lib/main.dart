import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'app/app.dart';
import 'core/auth/token_store.dart';
import 'core/config/app_config.dart';
import 'core/network/api_client.dart';
import 'data/repositories/auth_repository.dart';
import 'data/repositories/document_repository.dart';
import 'state/session_controller.dart';
import 'ui/screens/configuration_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final config = AppConfig.fromEnvironment();
    final tokens = SecureTokenStore();
    final api = ApiClient(
      config: config,
      client: http.Client(),
      tokens: tokens,
    );
    final session = SessionController(AuthRepository(api), tokens);
    api.onUnauthorized = session.invalidate;
    runApp(ChatPdfApp(session: session, documents: DocumentRepository(api)));
    session.restore();
  } on FormatException catch (error) {
    runApp(ConfigurationScreen(diagnostic: error.message));
  }
}
