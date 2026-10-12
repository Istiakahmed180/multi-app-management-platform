import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../core/api/api_client.dart';
import '../../core/api/api_exception.dart';
import '../../core/controllers/paged_controller.dart';
import '../../core/models/models.dart';
import '../../core/services/session_service.dart';
import '../../widgets/app_shell.dart';
import '../../widgets/common.dart';
import '../../widgets/data_table_card.dart';
import '../../widgets/notify.dart';

class OrganizationsController extends PagedController<Json> {
  OrganizationsController(this.api, this.session);
  final ApiClient api;
  final SessionService session;

  @override
  Future<Paged<Json>> fetch(Map<String, dynamic> query) => api.getPaged('/organizations', (j) => j, query: query);

  Future<void> create(String name) async {
    try {
      final org = asJson(await api.post('/organizations', body: {'name': name}));
      await session.reloadProfile();
      await session.selectOrg('${org['id']}');
      notifySuccess('Organization "${org['name']}" created');
      await load();
    } on ApiException catch (e) {
      notifyError(e);
    }
  }

  Future<void> rename(String id, String name) async {
    try {
      await api.patch('/organizations/$id', body: {'name': name});
      await session.reloadProfile();
      notifySuccess('Organization renamed');
      await load();
    } on ApiException catch (e) {
      notifyError(e);
    }
  }
}

Future<String?> _nameDialog({required String title, String initial = '', required String action}) {
  final controller = TextEditingController(text: initial);
  final formKey = GlobalKey<FormState>();
  return Get.dialog<String>(
    AlertDialog(
      title: Text(title),
      content: Form(
        key: formKey,
        child: SizedBox(
          width: 380,
          child: TextFormField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Organization name'),
            validator: (v) => (v == null || v.trim().length < 2) ? 'At least 2 characters' : null,
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: Get.back, child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            if (formKey.currentState!.validate()) Get.back(result: controller.text.trim());
          },
          child: Text(action),
        ),
      ],
    ),
  );
}

class OrganizationsView extends StatelessWidget {
  const OrganizationsView({super.key});

  @override
  Widget build(BuildContext context) {
    final c = Get.put(OrganizationsController(Get.find(), Get.find()));
    return AppShell(
      title: 'Organizations',
      actions: [
        FilledButton.icon(
          onPressed: () async {
            final name = await _nameDialog(title: 'New organization', action: 'Create');
            if (name != null) await c.create(name);
          },
          icon: const Icon(Icons.add),
          label: const Text('New organization'),
        ),
      ],
      body: Obx(
        () => DataTableCard<Json>(
          loading: c.loading.value,
          error: c.error.value,
          onRetry: c.load,
          rows: c.items.toList(),
          searchHint: 'Search organizations',
          onSearch: c.setSearch,
          page: c.page.value,
          totalPages: c.totalPages.value,
          total: c.total.value,
          onPage: c.goToPage,
          emptyTitle: 'No organizations',
          emptyMessage: 'Create an organization to group apps and members.',
          columns: [
            TableColumn('Name', (o) => Text('${o['name']}', style: const TextStyle(fontWeight: FontWeight.w600))),
            TableColumn('Slug', (o) => Text('${o['slug']}')),
            TableColumn('Your role', (o) => Text(roleLabel('${o['role']}'))),
            TableColumn('Apps', (o) => Text(formatNumber(asInt(o['appCount']))), numeric: true),
            TableColumn('Created', (o) => Text(formatDate(parseDate(o['createdAt'])))),
            TableColumn('', (o) {
              final perms = stringList(o['permissions']);
              final isCurrent = c.session.currentOrg.value?.id == o['id'];
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (isCurrent)
                    const Chip(label: Text('Current'))
                  else
                    TextButton(onPressed: () => c.session.selectOrg('${o['id']}'), child: const Text('Switch to')),
                  if (perms.contains('org:manage'))
                    IconButton(
                      tooltip: 'Rename',
                      icon: const Icon(Icons.edit_outlined),
                      onPressed: () async {
                        final name = await _nameDialog(title: 'Rename organization', initial: '${o['name']}', action: 'Save');
                        if (name != null) await c.rename('${o['id']}', name);
                      },
                    ),
                ],
              );
            }),
          ],
        ),
      ),
    );
  }
}
