import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../data/repositories/document_repository.dart';
import '../state/session_controller.dart';
import 'navigation/app_router.dart';

class ChatPdfApp extends StatefulWidget {
  const ChatPdfApp({super.key, required this.session, required this.documents});
  final SessionController session;
  final DocumentRepository documents;
  @override
  State<ChatPdfApp> createState() => _ChatPdfAppState();
}

class _ChatPdfAppState extends State<ChatPdfApp> {
  late final GoRouter _router = createRouter(widget.session, widget.documents);
  @override
  void dispose() {
    _router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp.router(
    title: 'ChatPDF',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF275DAD)),
      useMaterial3: true,
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
      ),
    ),
    routerConfig: _router,
  );
}
