import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
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

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    // Generic debug launches may omit Dart definitions. Use the explicit public
    // development configuration only in debug/development, never in release.
    final AppConfig config;
    if (kDebugMode &&
        const String.fromEnvironment('APP_ENV', defaultValue: 'development') ==
            'development' &&
        const String.fromEnvironment('API_BASE_URL').isEmpty) {
      final values = jsonDecode(
        await rootBundle.loadString('config/development.defaults.json'),
      ) as Map<String, dynamic>;
      config = AppConfig(
        environment: values['APP_ENV'] as String,
        apiBaseUrl: values['API_BASE_URL'] as String,
      );
    } else {
      config = AppConfig.fromEnvironment();
    }
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
