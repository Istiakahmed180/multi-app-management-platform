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
import '../config/config_utils.dart';

const _statuses = {
  'planned': 'Planned',
  'in_review': 'In review',
  'rolling_out': 'Rolling out',
  'released': 'Released',
  'halted': 'Halted',
};

class ReleasesController extends PagedController<Json> with AppScope {
  ReleasesController(this.api, this.session);
  final ApiClient api;
  final SessionService session;

  final summary = Rxn<Json>();
  bool get canWrite => session.can('releases:write');
  bool get canWriteConfig => session.can('config:write');

  @override
  Future<Paged<Json>> fetch(Map<String, dynamic> query) => api.getPaged('/apps/$appId/releases', (j) => j, query: query);

  @override
  Future<void> load() async {
    await super.load();
    try {
      summary.value = asJson(await api.get('/apps/$appId/releases/summary'));
    } on ApiException {
      summary.value = null;
    }
  }

  Future<void> edit([Json? release]) async {
    final result = await Get.dialog<Json>(_ReleaseDialog(release: release));
    if (result == null) return;
    try {
      if (release == null) {
        await api.post('/apps/$appId/releases', body: result);
        notifySuccess('Release recorded');
      } else {
        for (final k in ['platform', 'version', 'buildNumber']) {
          result.remove(k);
        }
        await api.patch('/apps/$appId/releases/${release['id']}', body: result);
        notifySuccess('Release updated');
      }
      await load();
    } on ApiException catch (e) {
      notifyError(e);
    }
  }

  Future<void> applyToDraft(Json r) async {
    final ok = await confirmAction(
      title: 'Use ${r['version']} in the update policy?',
      message:
          'Sets the ${r['platform']} latest version to ${r['version']}'
          '${r['isMandatory'] == true ? ' and the minimum supported version to ${r['version']} (force update)' : ''} in the config draft. '
          'Nothing changes for users until you publish the draft.',
      confirmLabel: 'Update draft',
    );
    if (!ok) return;
    try {
      await api.post('/apps/$appId/releases/${r['id']}/apply-to-draft');
      notifySuccess('Draft update policy changed — review and publish it in Remote config');
      await load();
    } on ApiException catch (e) {
      notifyError(e);
    }
  }
}

class _ReleaseDialog extends StatefulWidget {
  const _ReleaseDialog({this.release});
  final Json? release;

  @override
  State<_ReleaseDialog> createState() => _ReleaseDialogState();
}

class _ReleaseDialogState extends State<_ReleaseDialog> {
  final formKey = GlobalKey<FormState>();
  late String platform = '${widget.release?['platform'] ?? 'android'}';
  late final version = TextEditingController(text: '${widget.release?['version'] ?? ''}');
  late final buildNo = TextEditingController(text: '${widget.release?['buildNumber'] ?? ''}');
  late final notes = TextEditingController(text: '${widget.release?['releaseNotes'] ?? ''}');
  late final storeUrl = TextEditingController(text: '${widget.release?['storeUrl'] ?? ''}');
  late String status = '${widget.release?['status'] ?? 'planned'}';
  late double rollout = asInt(widget.release?['rolloutPercentage'], 100).toDouble();
  late bool mandatory = widget.release?['isMandatory'] == true;

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.release != null;
    return AlertDialog(
      title: Text(isEdit ? 'Edit release ${widget.release!['version']}' : 'Record release'),
      content: SizedBox(
        width: 480,
        child: Form(
          key: formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!isEdit) ...[
                  DropdownButtonFormField<String>(
                    initialValue: platform,
                    decoration: const InputDecoration(labelText: 'Platform'),
                    items: const [
                      DropdownMenuItem(value: 'android', child: Text('Android')),
                      DropdownMenuItem(value: 'ios', child: Text('iOS')),
                    ],
                    onChanged: (v) => setState(() => platform = v ?? 'android'),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: version,
                    decoration: const InputDecoration(labelText: 'Version *', hintText: '2.4.0'),
                    validator: (v) => (v != null && semverPattern.hasMatch(v)) ? null : 'Use x.y.z',
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: buildNo,
                    decoration: const InputDecoration(labelText: 'Build number *'),
                    validator: (v) => int.tryParse(v ?? '') == null ? 'Number' : null,
                  ),
                  const SizedBox(height: 12),
                ],
                DropdownButtonFormField<String>(
                  initialValue: status,
                  decoration: const InputDecoration(labelText: 'Status'),
                  items: [for (final e in _statuses.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
                  onChanged: (v) => setState(() => status = v ?? status),
                ),
                const SizedBox(height: 12),
                Text('Staged rollout (as configured in the store): ${rollout.round()}%'),
                Slider(
                  value: rollout,
                  max: 100,
                  divisions: 20,
                  label: '${rollout.round()}%',
                  onChanged: (v) => setState(() => rollout = v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Mandatory (force update)'),
                  subtitle: const Text('When applied to the update policy, older versions must update.'),
                  value: mandatory,
                  onChanged: (v) => setState(() => mandatory = v),
                ),
                TextFormField(
                  controller: storeUrl,
                  decoration: const InputDecoration(labelText: 'Store URL (https)'),
                  validator: validateOptionalHttps,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: notes,
                  maxLines: 4,
                  maxLength: 5000,
                  decoration: const InputDecoration(labelText: 'Release notes'),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: Get.back, child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            if (!formKey.currentState!.validate()) return;
            Get.back(
              result: <String, dynamic>{
                'platform': platform,
                'version': version.text.trim(),
                'buildNumber': int.tryParse(buildNo.text.trim()) ?? 0,
                'status': status,
                'rolloutPercentage': rollout.round(),
                'isMandatory': mandatory,
                'storeUrl': storeUrl.text.trim().isEmpty ? null : storeUrl.text.trim(),
                'releaseNotes': notes.text.trim(),
              },
            );
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class ReleasesView extends StatelessWidget {
  const ReleasesView({super.key});

  @override
  Widget build(BuildContext context) {
    final c = Get.put(ReleasesController(Get.find(), Get.find()));
    return AppShell(
      title: 'Releases',
      breadcrumbs: [const Crumb('Apps', Routes.apps), Crumb(c.appName, Routes.app(c.appId))],
      actions: [
        if (c.canWrite) FilledButton.icon(onPressed: () => c.edit(), icon: const Icon(Icons.add), label: const Text('Record release')),
      ],
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Obx(() {
            final s = c.summary.value;
            final published = asJson(s?['publishedPolicy']);
            final latest = asJson(s?['latestReleased']);
            return SectionCard(
              title: 'Live update policy',
              subtitle: 'Enforced by the app via the published remote config. This platform does not upload or distribute binaries.',
              trailing: TextButton(onPressed: () => Get.toNamed(Routes.config(c.appId)), child: const Text('Edit in Remote config')),
              child: s == null
                  ? const LinearProgressIndicator()
                  : ResponsiveGrid(
                      children: [
                        for (final p in ['android', 'ios'])
                          Card(
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(p == 'ios' ? 'iOS' : 'Android', style: Theme.of(context).textTheme.titleSmall),
                                  const SizedBox(height: 8),
                                  Text('Minimum: ${asJson(published[p])['minimumVersion'] ?? '—'}'),
                                  Text('Latest: ${asJson(published[p])['latestVersion'] ?? '—'}'),
                                  Text('Last released: ${asJson(latest[p])['version'] ?? '—'}'),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
            );
          }),
          const SizedBox(height: 20),
          Obx(
            () => DataTableCard<Json>(
              loading: c.loading.value,
              error: c.error.value,
              onRetry: c.load,
              rows: c.items.toList(),
              filters: [
                FilterDropdown(
                  label: 'Platform',
                  value: c.filters['platform'],
                  options: const {'android': 'Android', 'ios': 'iOS'},
                  onChanged: (v) => c.setFilter('platform', v),
                ),
                FilterDropdown(label: 'Status', value: c.filters['status'], options: _statuses, onChanged: (v) => c.setFilter('status', v)),
              ],
              page: c.page.value,
              totalPages: c.totalPages.value,
              total: c.total.value,
              onPage: c.goToPage,
              emptyTitle: 'No releases recorded',
              emptyMessage: 'Record store releases to keep a history and drive the update policy.',
              columns: [
                TableColumn(
                  'Version',
                  (r) => Text('${r['version']} (${r['buildNumber']})', style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
                TableColumn('Platform', (r) => Text('${r['platform']}')),
                TableColumn('Status', (r) => StatusChip('${r['status']}')),
                TableColumn('Rollout', (r) => Text('${r['rolloutPercentage']}%'), numeric: true),
                TableColumn('Mandatory', (r) => Icon(r['isMandatory'] == true ? Icons.priority_high : Icons.remove, size: 18)),
                TableColumn('Released', (r) => Text(formatDate(parseDate(r['releasedAt'])))),
                TableColumn(
                  '',
                  (r) => Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (c.canWrite) IconButton(tooltip: 'Edit', icon: const Icon(Icons.edit_outlined), onPressed: () => c.edit(r)),
                      if (c.canWrite && c.canWriteConfig)
                        TextButton(onPressed: () => c.applyToDraft(r), child: const Text('Use in policy')),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
