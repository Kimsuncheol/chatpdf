import 'package:flutter/material.dart';

import '../../state/session_controller.dart';

class StartupScreen extends StatelessWidget {
  const StartupScreen({super.key, required this.session});
  final SessionController session;
  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: ListenableBuilder(
        listenable: session,
        builder: (_, _) => session.status == SessionStatus.unavailable
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(session.error ?? 'Unable to restore session.'),
                  TextButton(
                    onPressed: session.restore,
                    child: const Text('Retry'),
                  ),
                ],
              )
            : const CircularProgressIndicator(),
      ),
    ),
  );
}
