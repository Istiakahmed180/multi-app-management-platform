import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../../app/routes.dart';
import '../../core/api/api_client.dart';
import '../../core/api/api_exception.dart';
import '../../core/controllers/app_scope.dart';
import '../../core/env.dart';
import '../../core/models/models.dart';
import '../../core/services/workspace_service.dart';
import '../../widgets/app_shell.dart';
import '../../widgets/common.dart';
import '../../widgets/confirm_dialog.dart';
import '../../widgets/notify.dart';
import '../../widgets/states.dart';

class AppDetailController extends GetxController with AppScope {
  AppDetailController(this.api);
  final ApiClient api;

  final app = Rxn<AppInfo>();
  final loading = true.obs;
  final error = RxnString();

  @override
  void onReady() {
    super.onReady();
    load();
  }

  Future<void> load() async {
    loading.value = true;
    error.value = null;
    try {
      app.value = AppInfo.fromJson(asJson(await api.get('/apps/$appId')));
    } on ApiException catch (e) {
      error.value = e.message;
    } finally {
      loading.value = false;
    }
  }

  Future<void> setStatus(String status) async {
    final a = app.value!;
    final destructive = status != 'active';
    final ok = await confirmAction(
      title: 'Change status to $status?',
      message: switch (status) {
        'inactive' => 'Inactive apps stop serving remote configuration. Installed apps fall back to their cached config.',
        'archived' => 'Archived apps are hidden, stop serving configuration and reject ingest calls. You can reactivate later.',
        _ => 'The app will serve its published configuration again.',
      },
      confirmLabel: 'Set $status',
      destructive: destructive,
      typeToConfirm: status == 'archived' ? a.slug : null,
    );
    if (!ok) return;
    try {
      await api.patch('/apps/$appId/status', body: {'status': status});
      notifySuccess('Status updated');
      await Get.find<WorkspaceService>().loadApps();
      await load();
    } on ApiException catch (e) {
      notifyError(e);
    }
  }
}

class AppDetailView extends StatelessWidget {
  const AppDetailView({super.key});

  @override
  Widget build(BuildContext context) {
    final c = Get.put(AppDetailController(Get.find()));
    return Obx(() {
      final a = c.app.value;
      final can = a?.permissions ?? const <String>{};
      return AppShell(
        title: a?.name ?? 'App',
        breadcrumbs: const [Crumb('Apps', Routes.apps)],
        actions: [
          if (a != null && can.contains('apps:write')) ...[
            OutlinedButton.icon(
              onPressed: () => Get.toNamed(Routes.editApp(a.id)),
              icon: const Icon(Icons.edit_outlined),
              label: const Text('Edit'),
            ),
            PopupMenuButton<String>(
              tooltip: 'Change status',
              onSelected: c.setStatus,
              itemBuilder: (_) => [
                for (final s in ['active', 'inactive', 'archived'])
                  if (s != a.status) PopupMenuItem(value: s, child: Text('Set $s')),
              ],
              child: const Padding(padding: EdgeInsets.all(8), child: Icon(Icons.more_vert)),
            ),
          ],
        ],
        body: AsyncBody(
          loading: c.loading.value && a == null,
          error: c.error.value,
          onRetry: c.load,
          builder: (context) => _Body(app: a!),
        ),
      );
    });
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.app});
  final AppInfo app;

  @override
  Widget build(BuildContext context) {
    final s = app.summary;
    final integ = asJson(s['integrations']);
    final configUrl = '${Env.apiBaseUrl}/public/apps/${app.appKey}/config';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ResponsiveGrid(
          children: [
            StatCard(label: 'Status', value: app.status, icon: Icons.toggle_on_outlined),
            StatCard(label: 'Registered users', value: formatNumber(asInt(s['userCount'])), icon: Icons.people_outline),
            StatCard(
              label: 'Published config',
              value: app.publishedConfigVersion == null ? 'None' : 'v${app.publishedConfigVersion}',
              icon: Icons.tune,
            ),
            StatCard(label: 'Feature flags', value: formatNumber(asInt(s['flagCount'])), icon: Icons.flag_outlined),
          ],
        ),
        const SizedBox(height: 20),
        SectionCard(
          title: 'Identity',
          child: Column(
            children: [
              InfoRow(
                'App key',
                null,
                child: Row(
                  children: [
                    Flexible(
                      child: SelectableText(app.appKey, style: const TextStyle(fontFamily: 'monospace')),
                    ),
                    IconButton(
                      tooltip: 'Copy app key',
                      icon: const Icon(Icons.copy, size: 18),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: app.appKey));
                        notifySuccess('App key copied');
                      },
                    ),
                  ],
                ),
              ),
              InfoRow('Public config endpoint', configUrl),
              InfoRow('Slug', app.slug),
              InfoRow('Environment', app.environment),
              InfoRow('Platforms', app.platforms.join(', ')),
              if (app.androidPackageId != null) InfoRow('Android package', app.androidPackageId),
              if (app.iosBundleId != null) InfoRow('iOS bundle id', app.iosBundleId),
              InfoRow('Description', app.description.isEmpty ? '—' : app.description),
              InfoRow('Created', formatDateTime(app.createdAt)),
            ],
          ),
        ),
        const SizedBox(height: 20),
        SectionCard(
          title: 'Integrations',
          trailing: app.permissions.contains('integrations:read')
              ? TextButton(onPressed: () => Get.toNamed(Routes.integrations(app.id)), child: const Text('Manage'))
              : null,
          child: Column(
            children: [
              _IntegrationRow('Firebase Cloud Messaging', integ['fcm'] == true, 'Required to send push notifications'),
              _IntegrationRow('Server API key', integ['serverApiKey'] == true, 'Lets your app backend sync users and activity'),
              _IntegrationRow('Webhook', integ['webhook'] == true, 'Notifies your backend about user suspensions'),
            ],
          ),
        ),
      ],
    );
  }
}

class _IntegrationRow extends StatelessWidget {
  const _IntegrationRow(this.label, this.on, this.hint);
  final String label;
  final bool on;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(on ? Icons.check_circle : Icons.cancel_outlined, color: on ? Colors.green : Theme.of(context).colorScheme.outline),
      title: Text(label),
      subtitle: Text(hint),
      trailing: StatusChip(on ? 'enabled' : 'disabled'),
    );
  }
}
