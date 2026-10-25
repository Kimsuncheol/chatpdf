import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/navigation/app_routes.dart';

class AppScaffold extends StatelessWidget {
  const AppScaffold({super.key, required this.path, required this.child});
  final String path;
  final Widget child;
  @override
  Widget build(BuildContext context) => Scaffold(
    body: child,
    bottomNavigationBar: NavigationBar(
      selectedIndex: switch (path) {
        AppRoutes.upload => 1,
        AppRoutes.history => 2,
        AppRoutes.settings => 3,
        _ => 0,
      },
      onDestinationSelected: (index) => context.go(
        [
          AppRoutes.library,
          AppRoutes.upload,
          AppRoutes.history,
          AppRoutes.settings,
        ][index],
      ),
      destinations: const [
        NavigationDestination(
          icon: Icon(Icons.folder_outlined),
          label: 'Library',
        ),
        NavigationDestination(icon: Icon(Icons.upload_file), label: 'Upload'),
        NavigationDestination(icon: Icon(Icons.history), label: 'History'),
        NavigationDestination(
          icon: Icon(Icons.settings_outlined),
          label: 'Settings',
        ),
      ],
    ),
  );
}
