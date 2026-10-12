import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../app/routes.dart';
import '../../core/api/api_client.dart';
import '../../core/api/api_exception.dart';
import '../../core/controllers/app_scope.dart';
import '../../core/models/models.dart';
import '../../core/services/session_service.dart';
import '../../widgets/app_shell.dart';
import '../../widgets/common.dart';
import '../../widgets/confirm_dialog.dart';
import '../../widgets/data_table_card.dart';
import '../../widgets/notify.dart';
import '../config/config_utils.dart';

class FeaturesController extends GetxController with AppScope {
  FeaturesController(this.api, this.session);
  final ApiClient api;
  final SessionService session;

  final flags = <Json>[].obs;
  final loading = true.obs;
  final error = RxnString();
  final search = ''.obs;

  bool get canWrite => session.can('flags:write');

  List<Json> get visible => search.value.isEmpty
      ? flags
      : flags.where((f) => '${f['key']} ${f['description']}'.toLowerCase().contains(search.value.toLowerCase())).toList();

  @override
  void onReady() {
    super.onReady();
    load();
  }

  Future<void> load() async {
    loading.value = true;
    error.value = null;
    try {
      flags.assignAll(((await api.get('/apps/$appId/features')) as List).map(asJson));
    } on ApiException catch (e) {
      error.value = e.message;
    } finally {
      loading.value = false;
    }
  }

  Future<void> toggle(Json flag, bool enabled) async {
    final ok = await confirmAction(
      title: '${enabled ? 'Enable' : 'Disable'} "${flag['key']}"?',
      message: 'Flag changes are live immediately: apps see them on their next config refresh.',
      confirmLabel: enabled ? 'Enable' : 'Disable',
      destructive: !enabled,
    );
    if (!ok) return;
    await _patch('${flag['key']}', {'enabled': enabled});
  }

  Future<void> _patch(String key, Json body) async {
    try {
      await api.patch('/apps/$appId/features/$key', body: body);
      notifySuccess('Flag "$key" updated');
      await load();
    } on ApiException catch (e) {
      notifyError(e);
    }
  }

  Future<void> remove(Json flag) async {
    final ok = await confirmAction(
      title: 'Delete flag "${flag['key']}"?',
      message: 'Apps will treat this feature as disabled.',
      confirmLabel: 'Delete',
      destructive: true,
      typeToConfirm: '${flag['key']}',
    );
    if (!ok) return;
    try {
      await api.delete('/apps/$appId/features/${flag['key']}');
      notifySuccess('Flag deleted');
      await load();
    } on ApiException catch (e) {
      notifyError(e);
    }
  }

  Future<void> edit([Json? flag]) async {
    final result = await Get.dialog<Json>(_FlagDialog(flag: flag));
    if (result == null) return;
    if (flag == null) {
      try {
        await api.post('/apps/$appId/features', body: result);
        notifySuccess('Flag created');
        await load();
      } on ApiException catch (e) {
        notifyError(e);
      }
    } else {
      result.remove('key');
      await _patch('${flag['key']}', result);
    }
  }
}

class _FlagDialog extends StatefulWidget {
  const _FlagDialog({this.flag});
  final Json? flag;

  @override
  State<_FlagDialog> createState() => _FlagDialogState();
}

class _FlagDialogState extends State<_FlagDialog> {
  final formKey = GlobalKey<FormState>();
  late final key = TextEditingController(text: '${widget.flag?['key'] ?? ''}');
  late final description = TextEditingController(text: '${widget.flag?['description'] ?? ''}');
  late final minVersion = TextEditingController(text: '${widget.flag?['minAppVersion'] ?? ''}');
  late double rollout = asInt(widget.flag?['rolloutPercentage'], 100).toDouble();
  late bool enabled = widget.flag?['enabled'] == true;
  late final platforms = stringList(widget.flag?['platforms']).toSet();

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.flag != null;
    return AlertDialog(
      title: Text(isEdit ? 'Edit ${widget.flag!['key']}' : 'New feature flag'),
      content: SizedBox(
        width: 460,
        child: Form(
          key: formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!isEdit)
                  TextFormField(
                    controller: key,
                    autofocus: true,
                    decoration: const InputDecoration(labelText: 'Key', hintText: 'new_checkout'),
                    validator: (v) => (v != null && configKeyPattern.hasMatch(v)) ? null : 'lowercase letters, digits, _ . -',
                  ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: description,
                  decoration: const InputDecoration(labelText: 'Description'),
                ),
                const SizedBox(height: 12),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Enabled'),
                  value: enabled,
                  onChanged: (v) => setState(() => enabled = v),
                ),
                Text('Rollout: ${rollout.round()}% of installs'),
                Slider(
                  value: rollout,
                  min: 0,
                  max: 100,
                  divisions: 20,
                  label: '${rollout.round()}%',
                  onChanged: (v) => setState(() => rollout = v),
                ),
                const Text('Platforms (none selected = all)'),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final p in ['android', 'ios'])
                      FilterChip(
                        label: Text(p),
                        selected: platforms.contains(p),
                        onSelected: (v) => setState(() => v ? platforms.add(p) : platforms.remove(p)),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: minVersion,
                  decoration: const InputDecoration(labelText: 'Minimum app version (optional)', hintText: '2.1.0'),
                  validator: validateOptionalSemver,
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
                'key': key.text.trim(),
                'description': description.text.trim(),
                'enabled': enabled,
                'rolloutPercentage': rollout.round(),
                'platforms': platforms.toList(),
                'minAppVersion': minVersion.text.trim().isEmpty ? null : minVersion.text.trim(),
              },
            );
          },
          child: Text(isEdit ? 'Save' : 'Create'),
        ),
      ],
    );
  }
}

class FeaturesView extends StatelessWidget {
  const FeaturesView({super.key});

  @override
  Widget build(BuildContext context) {
    final c = Get.put(FeaturesController(Get.find(), Get.find()));
    return AppShell(
      title: 'Feature flags',
      breadcrumbs: [const Crumb('Apps', Routes.apps), Crumb(c.appName, Routes.app(c.appId))],
      actions: [if (c.canWrite) FilledButton.icon(onPressed: () => c.edit(), icon: const Icon(Icons.add), label: const Text('New flag'))],
      body: Obx(
        () => DataTableCard<Json>(
          loading: c.loading.value,
          error: c.error.value,
          onRetry: c.load,
          rows: c.visible,
          searchHint: 'Filter flags',
          onSearch: (v) => c.search.value = v,
          emptyTitle: 'No feature flags',
          emptyMessage:
              'Flags let you turn already-shipped features on or off, roll out gradually, or target a platform or minimum version.',
          columns: [
            TableColumn(
              'Key',
              (f) => Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${f['key']}',
                    style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.w600),
                  ),
                  if ('${f['description']}'.isNotEmpty) Text('${f['description']}', style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
            TableColumn('Enabled', (f) => Switch(value: f['enabled'] == true, onChanged: c.canWrite ? (v) => c.toggle(f, v) : null)),
            TableColumn('Rollout', (f) => Text('${f['rolloutPercentage']}%'), numeric: true),
            TableColumn('Platforms', (f) => Text(stringList(f['platforms']).isEmpty ? 'All' : stringList(f['platforms']).join(', '))),
            TableColumn('Min version', (f) => Text('${f['minAppVersion'] ?? '—'}')),
            TableColumn('Updated', (f) => Text(timeAgo(parseDate(f['updatedAt'])))),
            TableColumn(
              '',
              (f) => !c.canWrite
                  ? const SizedBox.shrink()
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(tooltip: 'Edit', icon: const Icon(Icons.edit_outlined), onPressed: () => c.edit(f)),
                        IconButton(tooltip: 'Delete', icon: const Icon(Icons.delete_outline), onPressed: () => c.remove(f)),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
