import '../../ui/screens/page_preview_screen.dart';
import '../../ui/screens/subscription_screen.dart';
import '../../ui/screens/privacy_screen.dart';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../data/repositories/document_repository.dart';
import '../../state/session_controller.dart';
import '../../ui/screens/auth_screen.dart';
import '../../ui/screens/chat_screen.dart';
import '../../ui/screens/history_screen.dart';
import '../../ui/screens/library_screen.dart';
import '../../ui/screens/settings_screen.dart';
import '../../ui/screens/startup_screen.dart';
import '../../ui/screens/upload_screen.dart';
import '../../ui/widgets/app_scaffold.dart';
import 'app_routes.dart';

GoRouter createRouter(
  SessionController session,
  DocumentRepository documents,
) => GoRouter(
  initialLocation: AppRoutes.library,
  refreshListenable: session,
  redirect: (context, state) {
    final path = state.uri.path;
    final isAuth = {
      AppRoutes.signIn,
      AppRoutes.createAccount,
      AppRoutes.resetPassword,
    }.contains(path);
    final saved = state.uri.queryParameters['from'];
    final destination =
        saved != null &&
            saved.startsWith('/') &&
            !saved.startsWith('//') &&
            !{
              AppRoutes.startup,
              AppRoutes.signIn,
              AppRoutes.createAccount,
              AppRoutes.resetPassword,
            }.contains(Uri.tryParse(saved)?.path)
        ? saved
        : AppRoutes.library;
    if ({
      SessionStatus.restoring,
      SessionStatus.unavailable,
    }.contains(session.status)) {
      return path == AppRoutes.startup
          ? null
          : Uri(
              path: AppRoutes.startup,
              queryParameters: {'from': state.uri.toString()},
            ).toString();
    }
    if (session.status == SessionStatus.signedOut) {
      if (isAuth) return null;
      return Uri(
        path: AppRoutes.signIn,
        queryParameters: {
          'from': path == AppRoutes.startup
              ? destination
              : state.uri.toString(),
        },
      ).toString();
    }
    if (isAuth || path == AppRoutes.startup) return destination;
    return null;
  },
  errorBuilder: (context, state) => Scaffold(
    appBar: AppBar(title: const Text('Page not found')),
    body: Center(
      child: TextButton(
        onPressed: () => context.go(AppRoutes.library),
        child: const Text('Go to library'),
      ),
    ),
  ),
  routes: [
    GoRoute(
      path: AppRoutes.startup,
      builder: (_, _) => StartupScreen(session: session),
    ),
    for (final entry in {
      AppRoutes.signIn: AuthMode.signIn,
      AppRoutes.createAccount: AuthMode.createAccount,
      AppRoutes.resetPassword: AuthMode.resetPassword,
    }.entries)
      GoRoute(
        path: entry.key,
        builder: (_, _) => AuthScreen(
          key: ValueKey(entry.key),
          session: session,
          mode: entry.value,
        ),
      ),
    ShellRoute(
      builder: (context, state, child) =>
          AppScaffold(path: state.uri.path, child: child),
      routes: [
        GoRoute(
          path: AppRoutes.library,
          builder: (_, _) => LibraryScreen(repository: documents),
        ),
        GoRoute(
          path: AppRoutes.upload,
          builder: (_, state) => UploadScreen(
            repository: documents,
            documentId: state.uri.queryParameters['documentId'],
          ),
        ),
        GoRoute(
          path: '/documents/:documentId/chat',
          builder: (_, state) => ChatScreen(
            key: ValueKey(state.uri.toString()),
            repository: documents,
            documentId: state.pathParameters['documentId']!,
            conversationId: state.uri.queryParameters['conversationId'],
          ),
        ),
        GoRoute(
          path: '/documents/:documentId/pages/:pageNumber',
          builder: (_, state) => PagePreviewScreen(
            key: ValueKey(state.uri.toString()),
            repository: documents,
            documentId: state.pathParameters['documentId']!,
            pageNumber: int.tryParse(state.pathParameters['pageNumber']!) ?? 0,
            snippet: state.extra is String ? state.extra as String : '',
          ),
        ),
        GoRoute(
          path: AppRoutes.history,
          builder: (_, _) => HistoryScreen(repository: documents),
        ),
        GoRoute(
          path: AppRoutes.settings,
          routes: [
            GoRoute(
              path: 'subscription',
              builder: (_, _) => SubscriptionScreen(session: session),
            ),
            GoRoute(path: 'privacy', builder: (_, _) => const PrivacyScreen()),
          ],
          builder: (_, _) => SettingsScreen(session: session),
        ),
      ],
    ),
  ],
);
