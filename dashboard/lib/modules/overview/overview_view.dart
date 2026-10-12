import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../app/routes.dart';
import '../../core/api/api_client.dart';
import '../../core/api/api_exception.dart';
import '../../core/models/models.dart';
import '../../core/services/session_service.dart';
import '../../core/services/workspace_service.dart';
import '../../widgets/app_shell.dart';
import '../../widgets/common.dart';
import '../../widgets/states.dart';

class OverviewController extends GetxController {
  OverviewController(this.api, this.session);
  final ApiClient api;
  final SessionService session;

  final data = Rxn<Json>();
  final loading = true.obs;
  final error = RxnString();

  @override
  void onReady() {
    super.onReady();
    Get.find<WorkspaceService>().selectApp(null);
    load();
  }

  Future<void> load() async {
    final org = session.currentOrg.value;
    if (org == null) {
      loading.value = false;
      return;
    }
    loading.value = true;
    error.value = null;
    try {
      data.value = asJson(await api.get('/overview', query: {'orgId': org.id}));
    } on ApiException catch (e) {
      error.value = e.message;
    } finally {
      loading.value = false;
    }
  }
}

class OverviewView extends StatelessWidget {
  const OverviewView({super.key});

  @override
  Widget build(BuildContext context) {
    final c = Get.put(OverviewController(Get.find(), Get.find()));
    return AppShell(
      title: 'Overview',
      actions: [IconButton(tooltip: 'Refresh', onPressed: c.load, icon: const Icon(Icons.refresh))],
      body: Obx(() {
        if (c.session.currentOrg.value == null) {
          return EmptyState(
            icon: Icons.domain_add_outlined,
            title: 'No organization yet',
            message: 'Create an organization to start registering apps.',
            action: FilledButton(onPressed: () => Get.toNamed(Routes.organizations), child: const Text('Go to organizations')),
          );
        }
        return AsyncBody(
          loading: c.loading.value && c.data.value == null,
          error: c.error.value,
          onRetry: c.load,
          builder: (_) => _OverviewBody(data: c.data.value ?? const {}),
        );
      }),
    );
  }
}

class _OverviewBody extends StatelessWidget {
  const _OverviewBody({required this.data});
  final Json data;

  @override
  Widget build(BuildContext context) {
    final apps = asJson(data['apps']);
    final users = asJson(data['users']);
    final activity = asJson(users['activity']);
    final api = asJson(data['api']);
    final campaigns = asJson(data['campaigns']);
    final health = (data['appHealth'] as List? ?? const []).map(asJson).toList();
    final recent = (data['recentActivity'] as List? ?? const []).map(asJson).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ResponsiveGrid(
          children: [
            StatCard(
              label: 'Registered apps',
              value: formatNumber(asInt(apps['total'])),
              icon: Icons.apps,
              hint: _statusHint(asJson(apps['byStatus'])),
            ),
            StatCard(
              label: 'Registered users',
              value: formatNumber(asInt(users['total'])),
              icon: Icons.people_alt_outlined,
              hint: 'From the app-user registry',
            ),
            StatCard(
              label: 'Active users (7d)',
              value: activity['available'] == true ? formatNumber(asInt(activity['active7d'])) : 'No data',
              icon: Icons.bolt_outlined,
              hint: activity['available'] == true ? 'Based on ingested activity' : 'Send activity events via the ingest API',
            ),
            StatCard(
              label: 'New registrations',
              value: formatNumber(asInt(users['new7d'])),
              icon: Icons.person_add_alt,
              hint: '${formatNumber(asInt(users['new30d']))} in the last 30 days',
            ),
            StatCard(
              label: 'API requests (24h)',
              value: api['available'] == true ? formatNumber(asInt(api['requests'])) : 'No traffic',
              icon: Icons.swap_vert,
              hint: api['available'] == true
                  ? 'Error rate ${formatPercent(api['errorRate'] as num?)} (5xx)'
                  : 'Recorded once apps call the API',
            ),
            StatCard(
              label: 'Notification campaigns',
              value: formatNumber(asInt(campaigns['total'])),
              icon: Icons.campaign_outlined,
              hint: '${formatNumber(asInt(campaigns['delivered']))} delivered · ${formatNumber(asInt(campaigns['failed']))} failed',
            ),
          ],
        ),
        const SizedBox(height: 20),
        LayoutBuilder(
          builder: (context, constraints) {
            final healthCard = SectionCard(
              title: 'App health & integrations',
              subtitle: 'Configuration, push and ingest status per app',
              child: health.isEmpty
                  ? EmptyState(
                      title: 'No apps registered',
                      message: 'Register your first Flutter app to see its status here.',
                      action: FilledButton.icon(
                        onPressed: () => Get.toNamed(Routes.newApp),
                        icon: const Icon(Icons.add),
                        label: const Text('Register app'),
                      ),
                    )
                  : Column(children: [for (final a in health) _HealthRow(app: a)]),
            );
            final activityCard = SectionCard(
              title: 'Recent admin activity',
              child: recent.isEmpty
                  ? const EmptyState(title: 'No activity yet', icon: Icons.history)
                  : Column(
                      children: [
                        for (final r in recent)
                          ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.circle, size: 8),
                            title: Text('${r['action']}'),
                            subtitle: Text('${r['actorEmail'] ?? r['actorType']} · ${timeAgo(parseDate(r['createdAt']))}'),
                          ),
                      ],
                    ),
            );
            if (constraints.maxWidth < 900) {
              return Column(children: [healthCard, const SizedBox(height: 20), activityCard]);
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 3, child: healthCard),
                const SizedBox(width: 20),
                Expanded(flex: 2, child: activityCard),
              ],
            );
          },
        ),
      ],
    );
  }

  String? _statusHint(Json byStatus) {
    if (byStatus.isEmpty) return null;
    return byStatus.entries.map((e) => '${e.value} ${e.key}').join(' · ');
  }
}

class _HealthRow extends StatelessWidget {
  const _HealthRow({required this.app});
  final Json app;

  @override
  Widget build(BuildContext context) {
    final integ = asJson(app['integrations']);
    final theme = Theme.of(context);
    Widget flag(String label, bool on) => Padding(
      padding: const EdgeInsets.only(right: 12),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(on ? Icons.check_circle : Icons.radio_button_unchecked, size: 15, color: on ? Colors.green : theme.colorScheme.outline),
          const SizedBox(width: 4),
          Text(label, style: theme.textTheme.bodySmall),
        ],
      ),
    );
    final version = app['publishedConfigVersion'];
    return InkWell(
      onTap: () => Get.toNamed(Routes.app('${app['id']}')),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text('${app['name']}', style: theme.textTheme.titleSmall, overflow: TextOverflow.ellipsis),
                      ),
                      const SizedBox(width: 8),
                      StatusChip('${app['status']}'),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    children: [
                      flag(version == null ? 'Config not published' : 'Config v$version', version != null),
                      flag('Push (FCM)', integ['fcm'] == true),
                      flag('Server API key', integ['apiKey'] == true),
                      flag('Webhook', integ['webhook'] == true),
                    ],
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('${formatNumber(asInt(app['requests24h']))} req/24h', style: theme.textTheme.bodySmall),
                Text('errors ${formatPercent(app['errorRate24h'] as num?)}', style: theme.textTheme.bodySmall),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
