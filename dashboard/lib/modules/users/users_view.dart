import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../app/routes.dart';
import '../../core/api/api_client.dart';
import '../../core/controllers/app_scope.dart';
import '../../core/controllers/paged_controller.dart';
import '../../core/models/models.dart';
import '../../widgets/app_shell.dart';
import '../../widgets/common.dart';
import '../../widgets/data_table_card.dart';

class UsersController extends PagedController<Json> with AppScope {
  UsersController(this.api);
  final ApiClient api;

  @override
  Future<Paged<Json>> fetch(Map<String, dynamic> query) => api.getPaged('/apps/$appId/users', (j) => j, query: query);
}

class UsersView extends StatelessWidget {
  const UsersView({super.key});

  @override
  Widget build(BuildContext context) {
    final c = Get.put(UsersController(Get.find()));
    return AppShell(
      title: 'Users',
      breadcrumbs: [const Crumb('Apps', Routes.apps), Crumb(c.appName, Routes.app(c.appId))],
      body: Obx(
        () => DataTableCard<Json>(
          loading: c.loading.value,
          error: c.error.value,
          onRetry: c.load,
          rows: c.items.toList(),
          onRowTap: (u) => Get.toNamed(Routes.user(c.appId, '${u['id']}')),
          searchHint: 'Email, name or user id (prefix)',
          onSearch: c.setSearch,
          filters: [
            FilterDropdown(
              label: 'Status',
              value: c.filters['status'],
              options: const {'active': 'Active', 'suspended': 'Suspended'},
              onChanged: (v) => c.setFilter('status', v),
            ),
            FilterDropdown(
              label: 'Platform',
              value: c.filters['platform'],
              options: const {'android': 'Android', 'ios': 'iOS'},
              onChanged: (v) => c.setFilter('platform', v),
            ),
            FilterDropdown(
              label: 'Sort',
              value: c.filters['sort'],
              options: const {'-createdAt': 'Newest', 'createdAt': 'Oldest', '-lastSeenAt': 'Recently seen', 'email': 'Email A-Z'},
              onChanged: (v) => c.setFilter('sort', v),
            ),
          ],
          page: c.page.value,
          totalPages: c.totalPages.value,
          total: c.total.value,
          onPage: c.goToPage,
          emptyTitle: 'No users in the registry',
          emptyMessage:
              'Users appear here once your app backend syncs them through the server ingest API (Integrations → Server API keys). '
              'This registry is separate from your app\'s own user database.',
          columns: [
            TableColumn(
              'User',
              (u) => Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${u['displayName'] ?? u['email'] ?? u['externalUserId']}', style: const TextStyle(fontWeight: FontWeight.w600)),
                  Text('${u['email'] ?? u['externalUserId']}', style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
            TableColumn('Status', (u) => StatusChip('${u['status']}')),
            TableColumn('Platform', (u) => Text('${u['platform'] ?? '—'}')),
            TableColumn('Version', (u) => Text('${u['appVersion'] ?? '—'}')),
            TableColumn('Push', (u) => Text(u['pushOptIn'] == true ? '${u['pushTokenCount']} token(s)' : 'Opted out')),
            TableColumn('Last seen', (u) => Text(timeAgo(parseDate(u['lastSeenAt'])))),
            TableColumn('Registered', (u) => Text(formatDate(parseDate(u['createdAt'])))),
          ],
        ),
      ),
    );
  }
}
