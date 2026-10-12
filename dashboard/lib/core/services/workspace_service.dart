import 'package:get/get.dart';

import '../api/api_client.dart';
import '../api/api_exception.dart';
import '../models/models.dart';
import 'session_service.dart';

/// Apps of the current organization, used by the sidebar app switcher.
class WorkspaceService extends GetxService {
  WorkspaceService(this.api, this.session);

  final ApiClient api;
  final SessionService session;

  final apps = <AppInfo>[].obs;
  final loading = false.obs;
  final error = RxnString();
  final selectedAppId = RxnString();

  AppInfo? get selectedApp => apps.firstWhereOrNull((a) => a.id == selectedAppId.value);

  @override
  void onInit() {
    super.onInit();
    ever(session.currentOrg, (_) {
      selectedAppId.value = null;
      loadApps();
    });
  }

  Future<void> loadApps() async {
    final org = session.currentOrg.value;
    if (org == null) {
      apps.clear();
      return;
    }
    loading.value = true;
    error.value = null;
    try {
      final page = await api.getPaged('/apps', AppInfo.fromJson, query: {'orgId': org.id, 'pageSize': 100, 'sort': 'name'});
      apps.assignAll(page.items);
    } on ApiException catch (e) {
      error.value = e.message;
    } catch (_) {
      // Runs from an Rx worker, so nothing may escape; surface a generic error instead.
      error.value = 'Could not load apps';
    } finally {
      loading.value = false;
    }
  }

  void selectApp(String? appId) => selectedAppId.value = appId;
}
