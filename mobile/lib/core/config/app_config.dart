class AppConfig {
  AppConfig({required this.environment, required String apiBaseUrl})
    : apiBaseUri = _validate(apiBaseUrl) {
    if (!{'development', 'production'}.contains(environment)) {
      throw const FormatException('APP_ENV must be development or production.');
    }
  }
  factory AppConfig.fromEnvironment() => AppConfig(
    environment: const String.fromEnvironment(
      'APP_ENV',
      defaultValue: 'development',
    ),
    apiBaseUrl: const String.fromEnvironment('API_BASE_URL'),
  );
  final String environment;
  final Uri apiBaseUri;
  static Uri _validate(String value) {
    if (value.trim().isEmpty) {
      throw const FormatException(
        'API_BASE_URL is missing. Configure the HTTPS Flask API and rebuild the app.',
      );
    }
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        value != value.trim()) {
      throw const FormatException(
        'Set API_BASE_URL to your Flask HTTPS URL using --dart-define or --dart-define-from-file.',
      );
    }
    if (uri.host.endsWith('.invalid') ||
        uri.host == 'your-development-api.example.com' ||
        uri.host == 'your-production-api.example.com') {
      throw const FormatException(
        'API_BASE_URL is an example address. Replace it with your real Flask HTTPS API and rebuild.',
      );
    }
    return uri.replace(
      path: uri.path.endsWith('/') ? uri.path : '${uri.path}/',
    );
  }
}
