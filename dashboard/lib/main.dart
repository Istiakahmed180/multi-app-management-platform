import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app/pages.dart';
import 'app/routes.dart';
import 'app/theme.dart';
import 'core/api/api_client.dart';
import 'core/env.dart';
import 'core/services/session_service.dart';
import 'core/services/theme_service.dart';
import 'core/services/workspace_service.dart';
import 'widgets/states.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = SharedPreferencesAsync();
  final api = ApiClient();
  final session = Get.put(SessionService(api, prefs: prefs), permanent: true);
  final theme = await Get.put(ThemeService(prefs: prefs), permanent: true).load();
  final workspace = Get.put(WorkspaceService(api, session), permanent: true);
  Get.put(api, permanent: true);

  api.onSessionExpired = () {
    if (!session.isAuthenticated) return;
    session.handleSessionExpired();
    Get.offAllNamed(Routes.login);
  };

  await session.bootstrap();
  if (session.isAuthenticated) await workspace.loadApps();
  runApp(DashboardApp(themeMode: theme.mode.value));
}

class DashboardApp extends StatelessWidget {
  const DashboardApp({super.key, required this.themeMode, this.initialRoute});

  final ThemeMode themeMode;
  final String? initialRoute;

  @override
  Widget build(BuildContext context) {
    return GetMaterialApp(
      title: Env.appName,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: themeMode,
      initialRoute: initialRoute ?? Routes.overview,
      getPages: appPages,
      unknownRoute: GetPage<dynamic>(
        name: '/not-found',
        page: () => Scaffold(
          body: EmptyState(
            icon: Icons.search_off,
            title: 'Page not found',
            action: FilledButton(onPressed: () => Get.offAllNamed(Routes.overview), child: const Text('Go to overview')),
          ),
        ),
      ),
    );
  }
}
