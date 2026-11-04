// Uses only Dart's standard library and the same validation as the application.
import 'dart:convert';
import 'dart:io';

import 'package:chatpdf_mobile/core/config/app_config.dart';

Future<void> main(List<String> arguments) async {
  final separator = arguments.indexOf('--');
  final options = separator < 0
      ? arguments
      : arguments.take(separator).toList();
  final flutterArguments = separator < 0
      ? <String>[]
      : arguments.skip(separator + 1).toList();
  if (options.contains('--help')) {
    stdout.writeln(
      'dart run tool/launch.dart [--production] [--configure | --check] '
      '[-- <flutter run arguments>]\n'
      '--configure saves API_BASE_URL from the shell environment to the local '
      'ignored config file. --check validates without launching.',
    );
    return;
  }
  try {
    if (options.any(
          (option) =>
              !{'--production', '--configure', '--check'}.contains(option),
        ) ||
        (options.contains('--configure') && options.contains('--check')) ||
        flutterArguments.any(
          (argument) => argument.startsWith('--dart-define'),
        )) {
      throw const FormatException('Invalid launch arguments. Use --help.');
    }
    final environment = options.contains('--production')
        ? 'production'
        : 'development';
    final mobile = File.fromUri(Platform.script).parent.parent;
    final file = File('${mobile.path}/config/$environment.json');
    if (options.contains('--configure')) {
      final config = AppConfig(
        environment: environment,
        apiBaseUrl: Platform.environment['API_BASE_URL'] ?? '',
      );
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert({'APP_ENV': environment, 'API_BASE_URL': config.apiBaseUri.toString()})}\n',
      );
      stdout.writeln(
        'Saved $environment API configuration. Restart the app with this launch profile.',
      );
      return;
    }
    if (!file.existsSync()) {
      throw FormatException(
        'No $environment API configuration exists. From mobile/, run:\n'
        'API_BASE_URL="https://<your-api-host>/api/v1/" '
        'dart run tool/launch.dart ${environment == 'production' ? '--production ' : ''}--configure\n'
        'Use the real Flask HTTPS address, then launch again.',
      );
    }
    final data = jsonDecode(file.readAsStringSync());
    if (data is! Map<String, dynamic> ||
        data['APP_ENV'] != environment ||
        data['API_BASE_URL'] is! String ||
        data.keys.any((key) => !{'APP_ENV', 'API_BASE_URL'}.contains(key))) {
      throw const FormatException(
        'Configuration must contain only APP_ENV and API_BASE_URL for the selected environment.',
      );
    }
    AppConfig(
      environment: environment,
      apiBaseUrl: data['API_BASE_URL'] as String,
    );
    if (options.contains('--check')) {
      stdout.writeln('$environment API configuration is valid.');
      return;
    }
    final process = await Process.start(
      'flutter',
      ['run', '--dart-define-from-file=${file.path}', ...flutterArguments],
      workingDirectory: mobile.path,
      mode: ProcessStartMode.inheritStdio,
    );
    exitCode = await process.exitCode;
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    exitCode = 64;
  } on FileSystemException {
    stderr.writeln(
      'Cannot read or save API configuration. Check local file permissions.',
    );
    exitCode = 74;
  } on ProcessException {
    stderr.writeln(
      'Cannot start Flutter. Check that the Flutter SDK is on your PATH.',
    );
    exitCode = 69;
  }
}
