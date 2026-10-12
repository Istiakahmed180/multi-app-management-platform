import 'package:get/get.dart';

import '../services/workspace_service.dart';

/// Reads `:appId` from the route and keeps the sidebar app switcher in sync.
mixin AppScope on GetxController {
  late final String appId = Get.parameters['appId'] ?? '';

  @override
  void onInit() {
    super.onInit();
    Get.find<WorkspaceService>().selectApp(appId);
  }

  String get appName => Get.find<WorkspaceService>().apps.firstWhereOrNull((a) => a.id == appId)?.name ?? 'App';
}
