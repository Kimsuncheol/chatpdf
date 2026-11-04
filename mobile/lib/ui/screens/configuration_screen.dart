import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Shown before creating network/auth services when the build is unconfigured.
class ConfigurationScreen extends StatelessWidget {
  const ConfigurationScreen({super.key, required this.diagnostic});

  final String diagnostic;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'ChatPDF',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF275DAD)),
      useMaterial3: true,
    ),
    home: Scaffold(
      appBar: AppBar(title: const Text('ChatPDF')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.settings_outlined, size: 48),
                  const SizedBox(height: 20),
                  Text(
                    'App setup is incomplete',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'This build is not connected to the ChatPDF service. '
                    'Contact the app administrator for a configured build.',
                    textAlign: TextAlign.center,
                  ),
                  if (kDebugMode) ...[
                    const SizedBox(height: 24),
                    ExpansionTile(
                      title: const Text('Developer setup'),
                      childrenPadding: const EdgeInsets.all(16),
                      children: [
                        SelectableText(
                          '$diagnostic\n\n'
                          'From mobile/, configure the actual HTTPS API:\n\n'
                          'API_BASE_URL="https://<your-api-host>/api/v1/" '
                          'dart run tool/launch.dart --configure\n\n'
                          'Then run dart run tool/launch.dart or the ChatPDF '
                          'editor launch profile. Fully stop and rebuild; '
                          'hot reload cannot change build configuration.',
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
