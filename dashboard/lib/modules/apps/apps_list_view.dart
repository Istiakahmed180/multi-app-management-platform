import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../app/routes.dart';
import '../../core/api/api_client.dart';
import '../../core/controllers/paged_controller.dart';
import '../../core/models/models.dart';
import '../../core/services/session_service.dart';
import '../../core/services/workspace_service.dart';
import '../../widgets/app_shell.dart';
import '../../widgets/common.dart';
import '../../widgets/data_table_card.dart';

class AppsListController extends PagedController<AppInfo> {
  AppsListController(this.api, this.session);
  final ApiClient api;
  final SessionService session;

  @override
  void onInit() {
    super.onInit();
    filters['sort'] = 'name';
    Get.find<WorkspaceService>().selectApp(null);
  }

  @override
  Future<Paged<AppInfo>> fetch(Map<String, dynamic> query) =>
      api.getPaged('/apps', AppInfo.fromJson, query: {...query, 'orgId': session.currentOrg.value?.id});
}

class AppsListView extends StatelessWidget {
  const AppsListView({super.key});

  @override
  Widget build(BuildContext context) {
    final c = Get.put(AppsListController(Get.find(), Get.find()));
    final canCreate = c.session.can('apps:create');
    return AppShell(
      title: 'Apps',
      actions: [
        if (canCreate)
          FilledButton.icon(onPressed: () => Get.toNamed(Routes.newApp), icon: const Icon(Icons.add), label: const Text('Register app')),
      ],
      body: Obx(
        () => DataTableCard<AppInfo>(
          loading: c.loading.value,
          error: c.error.value,
          onRetry: c.load,
          rows: c.items.toList(),
          onRowTap: (a) => Get.toNamed(Routes.app(a.id)),
          searchHint: 'Search name, slug or package id',
          onSearch: c.setSearch,
          filters: [
            FilterDropdown(
              label: 'Status',
              value: c.filters['status'],
              options: const {'active': 'Active', 'inactive': 'Inactive', 'archived': 'Archived'},
              onChanged: (v) => c.setFilter('status', v),
            ),
            FilterDropdown(
              label: 'Platform',
              value: c.filters['platform'],
              options: const {'android': 'Android', 'ios': 'iOS'},
              onChanged: (v) => c.setFilter('platform', v),
            ),
            FilterDropdown(
              label: 'Environment',
              value: c.filters['environment'],
              options: const {'production': 'Production', 'staging': 'Staging', 'development': 'Development'},
              onChanged: (v) => c.setFilter('environment', v),
            ),
          ],
          page: c.page.value,
          totalPages: c.totalPages.value,
          total: c.total.value,
          onPage: c.goToPage,
          emptyTitle: 'No apps found',
          emptyMessage: canCreate
              ? 'Register a Flutter app to manage its configuration, users and notifications.'
              : 'Ask an organization owner to register an app.',
          columns: [
            TableColumn(
              'App',
              (a) => Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(a.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                  Text(a.slug, style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
            TableColumn(
              'Platforms',
              (a) => Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (a.platforms.contains('android')) const Tooltip(message: 'Android', child: Icon(Icons.android, size: 18)),
                  if (a.platforms.contains('ios')) const Tooltip(message: 'iOS', child: Icon(Icons.apple, size: 18)),
                ],
              ),
            ),
            TableColumn('Environment', (a) => Text(a.environment)),
            TableColumn('Status', (a) => StatusChip(a.status)),
            TableColumn('Config', (a) => Text(a.publishedConfigVersion == null ? 'Not published' : 'v${a.publishedConfigVersion}')),
            TableColumn('Updated', (a) => Text(formatDate(a.updatedAt))),
          ],
        ),
      ),
    );
  }
}
