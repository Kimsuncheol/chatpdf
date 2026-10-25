import 'package:flutter/material.dart';

import '../../state/load_controller.dart';

class AsyncContent<T> extends StatelessWidget {
  const AsyncContent({
    super.key,
    required this.controller,
    required this.builder,
  });
  final LoadController<T> controller;
  final Widget Function(T value) builder;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      if (controller.loading) {
        return const Center(child: CircularProgressIndicator());
      }
      if (controller.error != null) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(controller.error!, textAlign: TextAlign.center),
                TextButton(
                  onPressed: controller.refresh,
                  child: const Text('Try again'),
                ),
              ],
            ),
          ),
        );
      }
      final data = controller.data;
      if (data == null) return const SizedBox.shrink();
      return builder(data);
    },
  );
}
