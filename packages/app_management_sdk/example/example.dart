import 'dart:io';

import 'package:app_management_sdk/io.dart';

Future<void> main() async {
  final client = AppManagementClient(
    baseUrl: 'https://config.example.com',
    appKey: 'app_xxx',
    platform: AppPlatform.android,
    appVersion: '1.3.0',
    // Generate once (e.g. a UUID) and persist it; used only for rollouts.
    installationId: 'b6f1c0de-0000-4000-8000-000000000001',
    store: FileConfigStore.inDirectory(Directory.systemTemp.path),
  );

  client.changes.listen((snapshot) {
    print('Config v${snapshot.configVersion} applied');
  });

  final snapshot = await client.initialize();
  if (snapshot == null) {
    print('No configuration available yet; using built-in defaults.');
  } else {
    print('Title: ${snapshot.config.branding.appTitle}');
    print('Maintenance: ${client.isInMaintenance}');
    print('Update: ${client.updateStatus().level.name}');
    print('New checkout: ${client.isFeatureEnabled('new_checkout')}');
    print('Banners: ${client.activeBanners().map((b) => b.id).toList()}');
  }

  switch (await client.refresh()) {
    case RefreshUpdated(:final snapshot):
      print('Updated to v${snapshot.configVersion}');
    case RefreshNotModified():
      print('Already up to date');
    case RefreshFailed(:final error):
      print('Refresh failed: $error');
  }

  await client.dispose();
}
