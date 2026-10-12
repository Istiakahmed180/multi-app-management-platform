import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../app/routes.dart';
import '../../core/api/api_client.dart';
import '../../core/api/api_exception.dart';
import '../../core/controllers/app_scope.dart';
import '../../core/controllers/paged_controller.dart';
import '../../core/models/models.dart';
import '../../core/services/session_service.dart';
import '../../widgets/app_shell.dart';
import '../../widgets/common.dart';
import '../../widgets/confirm_dialog.dart';
import '../../widgets/data_table_card.dart';
import '../../widgets/notify.dart';
import 'config_utils.dart';

class ConfigHistoryController extends PagedController<Json> with AppScope {
  ConfigHistoryController(this.api, this.session);
  final ApiClient api;
  final SessionService session;

  final currentVersion = RxnInt();

  @override
  Future<Paged<Json>> fetch(Map<String, dynamic> query) async {
    final body = await api.getEnvelope('/apps/$appId/configs', query: {'page': query['page'], 'pageSize': query['pageSize']});
    final data = asJson(body['data']);
    final meta = asJson(body['meta']);
    currentVersion.value = (asJson(data['current'])['version'] as num?)?.toInt();
    return Paged(
      items: (data['versions'] as List).map(asJson).toList(),
      page: asInt(meta['page'], 1),
      pageSize: asInt(meta['pageSize'], 20),
      total: asInt(meta['total']),
      totalPages: asInt(meta['totalPages'], 1),
    );
  }

  Future<void> view(Json v) async {
    try {
      final version = asInt(v['version']);
      final selected = asJson(asJson(await api.get('/apps/$appId/configs/versions/$version'))['content']);
      final current = currentVersion.value != null && currentVersion.value != version
          ? asJson(asJson(await api.get('/apps/$appId/configs/versions/${currentVersion.value}'))['content'])
          : null;
      final changes = current == null ? <ConfigChange>[] : diffConfigs(current, selected);
      await Get.dialog<void>(
        AlertDialog(
          title: Text('Version $version'),
          content: SizedBox(
            width: 720,
            height: 520,
            child: DefaultTabController(
              length: current == null ? 1 : 2,
              child: Column(
                children: [
                  TabBar(
                    tabs: [
                      if (current != null) Tab(text: 'Changes vs live (${changes.length})'),
                      const Tab(text: 'Full JSON'),
                    ],
                  ),
                  Expanded(
                    child: TabBarView(
                      children: [
                        if (current != null)
                          changes.isEmpty
                              ? const Center(child: Text('Identical to the live version'))
                              : ListView(
                                  children: [
                                    for (final ch in changes)
                                      ListTile(
                                        dense: true,
                                        title: Text(ch.path, style: const TextStyle(fontFamily: 'monospace')),
                                        subtitle: Text('live: ${ch.before ?? '∅'}\nv$version: ${ch.after ?? '∅'}'),
                                      ),
                                  ],
                                ),
                        SingleChildScrollView(
                          padding: const EdgeInsets.all(8),
                          child: SelectableText(
                            const JsonEncoder.withIndent('  ').convert(selected),
                            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [TextButton(onPressed: Get.back, child: const Text('Close'))],
        ),
      );
    } on ApiException catch (e) {
      notifyError(e);
    }
  }

  Future<void> rollback(Json v) async {
    final version = asInt(v['version']);
    final ok = await confirmAction(
      title: 'Roll back to version $version?',
      message:
          'This publishes a new version with the content of version $version and resets the draft to it. Apps receive it on their next refresh.',
      confirmLabel: 'Roll back',
      destructive: true,
    );
    if (!ok) return;
    try {
      final res = asJson(await api.post('/apps/$appId/configs/rollback', body: {'version': version}));
      notifySuccess('Published version ${res['version']} (rollback of v$version)');
      await load();
    } on ApiException catch (e) {
      notifyError(e);
    }
  }
}

class ConfigHistoryView extends StatelessWidget {
  const ConfigHistoryView({super.key});

  @override
  Widget build(BuildContext context) {
    final c = Get.put(ConfigHistoryController(Get.find(), Get.find()));
    final canPublish = c.session.can('config:publish');
    return AppShell(
      title: 'Configuration history',
      breadcrumbs: [
        const Crumb('Apps', Routes.apps),
        Crumb(c.appName, Routes.app(c.appId)),
        Crumb('Remote config', Routes.config(c.appId)),
      ],
      body: Obx(
        () => DataTableCard<Json>(
          loading: c.loading.value,
          error: c.error.value,
          onRetry: c.load,
          rows: c.items.toList(),
          onRowTap: c.view,
          page: c.page.value,
          totalPages: c.totalPages.value,
          total: c.total.value,
          onPage: c.goToPage,
          emptyTitle: 'No published versions',
          emptyMessage: 'Publish the draft to create version 1.',
          columns: [
            TableColumn(
              'Version',
              (v) => Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('v${v['version']}', style: const TextStyle(fontWeight: FontWeight.w600)),
                  if (v['isCurrent'] == true) ...[const SizedBox(width: 8), const StatusChip('active')],
                ],
              ),
            ),
            TableColumn('Published', (v) => Text(formatDateTime(parseDate(v['publishedAt'])))),
            TableColumn('By', (v) => Text('${asJson(v['publishedBy'])['email'] ?? '—'}')),
            TableColumn(
              'Note',
              (v) => SizedBox(
                width: 280,
                child: Text(
                  v['rollbackOfVersion'] != null
                      ? 'Rollback to v${v['rollbackOfVersion']}${'${v['changeNote']}'.isEmpty ? '' : ' · ${v['changeNote']}'}'
                      : '${v['changeNote'] ?? ''}',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            TableColumn(
              '',
              (v) => Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton(onPressed: () => c.view(v), child: const Text('View')),
                  if (canPublish && v['isCurrent'] != true) TextButton(onPressed: () => c.rollback(v), child: const Text('Roll back')),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
