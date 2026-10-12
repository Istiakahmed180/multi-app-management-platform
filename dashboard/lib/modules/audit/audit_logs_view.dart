import 'dart:convert';

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

/// Organization-wide audit log, or a single app's when the route has `:appId`.
class AuditLogsController extends PagedController<Json> {
  AuditLogsController(this.api, this.session);
  final ApiClient api;
  final SessionService session;

  final String? appId = Get.parameters['appId'];

  @override
  void onInit() {
    super.onInit();
    Get.find<WorkspaceService>().selectApp(appId);
  }

  String get _path => appId != null ? '/apps/$appId/audit-logs' : '/organizations/${session.currentOrg.value?.id}/audit-logs';

  @override
  Future<Paged<Json>> fetch(Map<String, dynamic> query) {
    final q = Map<String, dynamic>.from(query);
    final search = q.remove('search');
    if (search is String && search.isNotEmpty) {
      q[search.contains('@') ? 'actorEmail' : 'action'] = search;
    }
    return api.getPaged(_path, (j) => j, query: q);
  }

  void details(Json log) {
    Get.dialog<void>(
      AlertDialog(
        title: Text('${log['action']}'),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                InfoRow('When', formatDateTime(parseDate(log['createdAt']))),
                InfoRow('Actor', '${log['actorEmail'] ?? log['actorType']}'),
                InfoRow('Target', '${log['targetType'] ?? '—'} ${log['targetId'] ?? ''}'),
                InfoRow('IP', '${log['ip'] ?? '—'}'),
                InfoRow('Request id', '${log['requestId'] ?? '—'}'),
                InfoRow('Metadata', const JsonEncoder.withIndent('  ').convert(log['metadata'] ?? {})),
              ],
            ),
          ),
        ),
        actions: [TextButton(onPressed: Get.back, child: const Text('Close'))],
      ),
    );
  }
}

class AuditLogsView extends StatelessWidget {
  const AuditLogsView({super.key});

  @override
  Widget build(BuildContext context) {
    final c = Get.put(AuditLogsController(Get.find(), Get.find()));
    final appName = Get.find<WorkspaceService>().selectedApp?.name ?? 'App';
    return AppShell(
      title: c.appId == null ? 'Audit logs' : 'App audit log',
      breadcrumbs: c.appId == null ? const [] : [const Crumb('Apps', Routes.apps), Crumb(appName, Routes.app(c.appId!))],
      body: Obx(
        () => DataTableCard<Json>(
          loading: c.loading.value,
          error: c.error.value,
          onRetry: c.load,
          rows: c.items.toList(),
          onRowTap: c.details,
          searchHint: 'Action prefix (e.g. config.) or actor email',
          onSearch: c.setSearch,
          filters: [
            FilterDropdown(
              label: 'Target',
              value: c.filters['targetType'],
              options: const {
                'app': 'App',
                'config': 'Config',
                'feature_flag': 'Feature flag',
                'campaign': 'Campaign',
                'app_user': 'App user',
                'membership': 'Membership',
                'integration': 'Integration',
                'release': 'Release',
              },
              onChanged: (v) => c.setFilter('targetType', v),
            ),
          ],
          page: c.page.value,
          totalPages: c.totalPages.value,
          total: c.total.value,
          onPage: c.goToPage,
          emptyTitle: 'No audit entries',
          columns: [
            TableColumn('When', (l) => Text(formatDateTime(parseDate(l['createdAt'])))),
            TableColumn('Action', (l) => Text('${l['action']}', style: const TextStyle(fontFamily: 'monospace'))),
            TableColumn('Actor', (l) => Text('${l['actorEmail'] ?? l['actorType']}')),
            TableColumn('Target', (l) => Text('${l['targetType'] ?? '—'}')),
            TableColumn('IP', (l) => Text('${l['ip'] ?? '—'}')),
          ],
        ),
      ),
    );
  }
}
