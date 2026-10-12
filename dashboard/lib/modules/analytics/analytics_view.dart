import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../app/routes.dart';
import '../../core/api/api_client.dart';
import '../../core/api/api_exception.dart';
import '../../core/controllers/app_scope.dart';
import '../../core/models/models.dart';
import '../../widgets/app_shell.dart';
import '../../widgets/common.dart';
import '../../widgets/states.dart';

class AnalyticsController extends GetxController with AppScope {
  AnalyticsController(this.api);
  final ApiClient api;

  final days = 30.obs;
  final data = Rxn<Json>();
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
      data.value = asJson(await api.get('/apps/$appId/analytics', query: {'days': days.value}));
    } on ApiException catch (e) {
      error.value = e.message;
    } finally {
      loading.value = false;
    }
  }

  void setDays(int d) {
    days.value = d;
    load();
  }
}

class AnalyticsView extends StatelessWidget {
  const AnalyticsView({super.key});

  @override
  Widget build(BuildContext context) {
    final c = Get.put(AnalyticsController(Get.find()));
    return AppShell(
      title: 'Analytics',
      breadcrumbs: [const Crumb('Apps', Routes.apps), Crumb(c.appName, Routes.app(c.appId))],
      actions: [
        Obx(
          () => SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 7, label: Text('7d')),
              ButtonSegment(value: 30, label: Text('30d')),
              ButtonSegment(value: 90, label: Text('90d')),
            ],
            selected: {c.days.value},
            onSelectionChanged: (s) => c.setDays(s.first),
          ),
        ),
      ],
      body: Obx(
        () => AsyncBody(
          loading: c.loading.value && c.data.value == null,
          error: c.error.value,
          onRetry: c.load,
          builder: (context) => _Body(d: c.data.value!),
        ),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.d});
  final Json d;

  Widget _series(List<Json> rows, String key, String label) {
    if (rows.isEmpty) return const SizedBox.shrink();
    return BarSeriesChart(
      labels: [for (final r in rows) '${r['date']}'],
      values: [for (final r in rows) (r[key] as num?) ?? 0],
      semanticLabel: label,
    );
  }

  @override
  Widget build(BuildContext context) {
    final users = asJson(d['users']);
    final activity = asJson(d['activity']);
    final versions = asJson(d['versions']);
    final api = asJson(d['api']);
    final campaigns = asJson(d['campaigns']);
    final newByDay = (users['newByDay'] as List? ?? const []).map(asJson).toList();
    final activeByDay = (activity['activeByDay'] as List? ?? const []).map(asJson).toList();
    final apiByDay = (api['byDay'] as List? ?? const []).map(asJson).toList();
    final hasActivity = activity['available'] == true;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ResponsiveGrid(
          children: [
            StatCard(label: 'Registered users', value: formatNumber(asInt(users['total']))),
            StatCard(label: 'New in range', value: formatNumber(asInt(users['newInRange']))),
            StatCard(
              label: 'DAU / WAU / MAU',
              value: hasActivity
                  ? '${formatNumber(asInt(activity['dau']))} / ${formatNumber(asInt(activity['wau']))} / ${formatNumber(asInt(activity['mau']))}'
                  : 'No data',
              hint: hasActivity ? 'From last-seen timestamps' : 'Requires ingested activity',
            ),
            StatCard(
              label: 'API requests',
              value: api['available'] == true ? formatNumber(asInt(api['requests'])) : 'No traffic',
              hint: api['available'] == true ? '5xx rate ${formatPercent(api['errorRate'] as num?)} · avg ${api['avgLatencyMs']} ms' : null,
            ),
            StatCard(
              label: 'Push delivered / failed',
              value: '${formatNumber(asInt(campaigns['delivered']))} / ${formatNumber(asInt(campaigns['failed']))}',
            ),
          ],
        ),
        const SizedBox(height: 20),
        SectionCard(
          title: 'New registrations per day',
          child: asInt(users['newInRange']) == 0
              ? const EmptyState(title: 'No registrations in this range', icon: Icons.person_add_disabled_outlined)
              : _series(newByDay, 'count', 'New registrations per day'),
        ),
        const SizedBox(height: 20),
        SectionCard(
          title: 'Active users per day',
          child: hasActivity && activeByDay.any((r) => asInt(r['count']) > 0)
              ? _series(activeByDay, 'count', 'Active users per day')
              : const EmptyState(
                  icon: Icons.insights_outlined,
                  title: 'No activity data collected',
                  message: 'Send activity events from your app backend through the ingest API to see active users. Nothing is estimated.',
                ),
        ),
        const SizedBox(height: 20),
        LayoutBuilder(
          builder: (context, constraints) {
            final versionCard = SectionCard(
              title: 'App version distribution',
              child: versions['available'] == true
                  ? BreakdownList(
                      items: [
                        for (final v in (versions['distribution'] as List).map(asJson))
                          ('${v['platform']} ${v['appVersion']}', asInt(v['count'])),
                      ],
                    )
                  : const EmptyState(title: 'No version data', message: 'Versions are reported via the ingest API.', icon: Icons.numbers),
            );
            final platformCard = SectionCard(
              title: 'Platforms',
              child: (users['byPlatform'] as List? ?? const []).isEmpty
                  ? const EmptyState(title: 'No users yet', icon: Icons.devices)
                  : BreakdownList(
                      items: [for (final p in (users['byPlatform'] as List).map(asJson)) ('${p['platform']}', asInt(p['count']))],
                    ),
            );
            if (constraints.maxWidth < 900) return Column(children: [versionCard, const SizedBox(height: 20), platformCard]);
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: versionCard),
                const SizedBox(width: 20),
                Expanded(child: platformCard),
              ],
            );
          },
        ),
        const SizedBox(height: 20),
        SectionCard(
          title: 'API traffic',
          subtitle: 'Requests attributed to this app (public config and ingest), recorded by the API itself.',
          child: api['available'] != true
              ? const EmptyState(title: 'No API traffic recorded', icon: Icons.swap_vert)
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _series(apiByDay, 'requests', 'API requests per day'),
                    const SizedBox(height: 12),
                    for (final r in (api['topRoutes'] as List? ?? const []).map(asJson))
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text('${r['method']} ${r['route']}', style: const TextStyle(fontFamily: 'monospace')),
                        trailing: Text('${formatNumber(asInt(r['requests']))} req · ${formatNumber(asInt(r['errors']))} 5xx'),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}
