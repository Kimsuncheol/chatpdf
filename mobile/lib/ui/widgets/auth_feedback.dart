import 'package:flutter/material.dart';

class AuthFeedback extends StatelessWidget {
  const AuthFeedback({super.key, required this.message, this.isError = true});
  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isError ? colors.errorContainer : colors.secondaryContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          message,
          style: TextStyle(
            color: isError
                ? colors.onErrorContainer
                : colors.onSecondaryContainer,
          ),
        ),
      ),
    );
  }
}
