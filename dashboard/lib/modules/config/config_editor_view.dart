import 'dart:convert';

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
import '../../widgets/notify.dart';
import '../../widgets/states.dart';
import 'config_utils.dart';

class ConfigEditorController extends GetxController with AppScope {
  ConfigEditorController(this.api, this.session);
  final ApiClient api;
  final SessionService session;

  final loading = true.obs;
  final saving = false.obs;
  final error = RxnString();
  final content = Rxn<Json>();
  final dirty = false.obs;
  final formVersion = 0.obs;
  final fieldErrors = <String, String>{}.obs;
  final currentVersion = RxnInt();
  final hasUnpublished = false.obs;
  final updatedAt = RxnString();
  final updatedBy = RxnString();
  final jsonMode = false.obs;
  final jsonText = TextEditingController();
  final jsonError = RxnString();

  bool get canWrite => session.can('config:write');
  bool get canPublish => session.can('config:publish');

  @override
  void onReady() {
    super.onReady();
    load();
  }

  Future<void> load() async {
    loading.value = true;
    error.value = null;
    try {
      final data = asJson(await api.get('/apps/$appId/configs', query: {'pageSize': 1}));
      final draft = asJson(data['draft']);
      content.value = asJson(draft['content']);
      updatedAt.value = draft['updatedAt'] as String?;
      updatedBy.value = asJson(draft['updatedBy'])['email'] as String?;
      hasUnpublished.value = draft['hasUnpublishedChanges'] == true;
      currentVersion.value = (asJson(data['current'])['version'] as num?)?.toInt();
      dirty.value = false;
      fieldErrors.clear();
      formVersion.value++;
      jsonText.text = const JsonEncoder.withIndent('  ').convert(content.value);
    } on ApiException catch (e) {
      error.value = e.message;
    } finally {
      loading.value = false;
    }
  }

  Object? read(String path) => content.value == null ? null : getPath(content.value!, path);

  void write(String path, Object? value) {
    setPath(content.value!, path, value);
    dirty.value = true;
    fieldErrors.remove(path);
  }

  /// Structural edits (adding/removing list items) need the form to rebuild.
  void mutate(void Function(Json c) change) {
    change(content.value!);
    dirty.value = true;
    formVersion.value++;
  }

  String? err(String path) => fieldErrors[path];

  bool _syncFromJson() {
    if (!jsonMode.value) return true;
    try {
      final parsed = jsonDecode(jsonText.text);
      if (parsed is! Map) throw const FormatException('Top level must be an object');
      content.value = asJson(parsed);
      jsonError.value = null;
      return true;
    } on FormatException catch (e) {
      jsonError.value = 'Invalid JSON: ${e.message}';
      return false;
    }
  }

  void toggleJson(bool on) {
    if (on) {
      jsonText.text = const JsonEncoder.withIndent('  ').convert(content.value);
      jsonError.value = null;
      jsonMode.value = true;
    } else {
      if (!_syncFromJson()) return;
      jsonMode.value = false;
      dirty.value = true;
      formVersion.value++;
    }
  }

  Future<bool> save({bool quiet = false}) async {
    if (!_syncFromJson()) return false;
    saving.value = true;
    fieldErrors.clear();
    try {
      final res = asJson(
        await api.put(
          '/apps/$appId/configs/draft',
          body: {'content': content.value, if (updatedAt.value != null) 'expectedUpdatedAt': updatedAt.value},
        ),
      );
      updatedAt.value = res['updatedAt'] as String?;
      dirty.value = false;
      hasUnpublished.value = true;
      if (!quiet) notifySuccess('Draft saved');
      return true;
    } on ApiException catch (e) {
      for (final f in e.fieldErrors) {
        fieldErrors[f.path.replaceFirst('content.', '')] = f.message;
      }
      if (e.isConflict) {
        error.value = null;
        notifyError(
          const ApiException(
            code: 'conflict',
            message: 'Someone else changed the draft. Reload to see their changes; your edits are kept until you reload.',
          ),
        );
      } else {
        notifyError(e);
      }
      return false;
    } finally {
      saving.value = false;
    }
  }

  Future<void> publish() async {
    final note = TextEditingController();
    final ok = await Get.dialog<bool>(
      AlertDialog(
        title: const Text('Publish configuration'),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'This creates version ${(currentVersion.value ?? 0) + 1}. Installed apps pick it up on their next refresh, without a new release, for features the app already implements.',
              ),
              const SizedBox(height: 12),
              TextField(
                controller: note,
                maxLength: 500,
                decoration: const InputDecoration(labelText: 'Change note (optional)'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Get.back(result: false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Get.back(result: true), child: const Text('Publish')),
        ],
      ),
    );
    if (ok != true) return;
    if (dirty.value && !await save(quiet: true)) return;
    saving.value = true;
    try {
      final res = asJson(await api.post('/apps/$appId/configs/publish', body: {'changeNote': note.text.trim()}));
      notifySuccess('Published version ${res['version']}');
      await load();
    } on ApiException catch (e) {
      for (final f in e.fieldErrors) {
        fieldErrors[f.path.replaceFirst('content.', '')] = f.message;
      }
      notifyError(e);
    } finally {
      saving.value = false;
    }
  }

  Future<void> discard() async {
    if (dirty.value &&
        !await confirmAction(
          title: 'Discard changes?',
          message: 'Unsaved edits will be lost.',
          confirmLabel: 'Discard',
          destructive: true,
        )) {
      return;
    }
    await load();
  }

  @override
  void onClose() {
    jsonText.dispose();
    super.onClose();
  }
}

class ConfigEditorView extends StatelessWidget {
  const ConfigEditorView({super.key});

  @override
  Widget build(BuildContext context) {
    final c = Get.put(ConfigEditorController(Get.find(), Get.find()));
    return Obx(
      () => AppShell(
        title: 'Remote configuration',
        breadcrumbs: [const Crumb('Apps', Routes.apps), Crumb(c.appName, Routes.app(c.appId))],
        actions: [
          OutlinedButton.icon(
            onPressed: () => Get.toNamed(Routes.configHistory(c.appId)),
            icon: const Icon(Icons.history),
            label: const Text('History'),
          ),
          if (c.canWrite) ...[
            OutlinedButton(onPressed: c.saving.value ? null : c.discard, child: const Text('Discard')),
            OutlinedButton.icon(
              onPressed: c.saving.value || !c.dirty.value ? null : () => c.save(),
              icon: const Icon(Icons.save_outlined),
              label: const Text('Save draft'),
            ),
          ],
          if (c.canPublish)
            FilledButton.icon(
              onPressed: c.saving.value || (!c.dirty.value && !c.hasUnpublished.value) ? null : c.publish,
              icon: const Icon(Icons.publish),
              label: const Text('Publish'),
            ),
        ],
        body: AsyncBody(
          loading: c.loading.value && c.content.value == null,
          error: c.error.value,
          onRetry: c.load,
          builder: (context) => _EditorBody(c: c),
        ),
      ),
    );
  }
}

class _EditorBody extends StatelessWidget {
  const _EditorBody({required this.c});
  final ConfigEditorController c;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final readOnly = !c.canWrite;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Wrap(
              spacing: 16,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(c.currentVersion.value == null ? 'Nothing published yet' : 'Live: version ${c.currentVersion.value}'),
                if (c.dirty.value) const StatusChip('unsaved changes') else if (c.hasUnpublished.value) const StatusChip('draft'),
                Text(
                  'Draft saved ${timeAgo(parseDate(c.updatedAt.value))}${c.updatedBy.value != null ? ' by ${c.updatedBy.value}' : ''}',
                  style: theme.textTheme.bodySmall,
                ),
                if (readOnly) const Chip(avatar: Icon(Icons.lock_outline, size: 16), label: Text('Read-only')),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('JSON'),
                    Switch(value: c.jsonMode.value, onChanged: c.toggleJson),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        if (c.fieldErrors.isNotEmpty)
          Card(
            color: theme.colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Fix these fields before saving:',
                    style: TextStyle(color: theme.colorScheme.onErrorContainer, fontWeight: FontWeight.w600),
                  ),
                  for (final e in c.fieldErrors.entries)
                    Text('• ${e.key}: ${e.value}', style: TextStyle(color: theme.colorScheme.onErrorContainer)),
                ],
              ),
            ),
          ),
        const SizedBox(height: 8),
        Text(
          'Remote configuration only changes behaviour that the app already implements (branding, theme, banners, maintenance mode, update prompts). New native functionality still requires an app release.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 16),
        if (c.jsonMode.value)
          SectionCard(
            title: 'Raw JSON',
            subtitle: 'Validated on save. Unknown fields are rejected.',
            child: TextField(
              controller: c.jsonText,
              readOnly: readOnly,
              maxLines: 30,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              decoration: InputDecoration(errorText: c.jsonError.value),
              onChanged: (_) => c.dirty.value = true,
            ),
          )
        else
          KeyedSubtree(
            key: ValueKey(c.formVersion.value),
            child: _Sections(c: c, readOnly: readOnly),
          ),
      ],
    );
  }
}

class _Sections extends StatelessWidget {
  const _Sections({required this.c, required this.readOnly});
  final ConfigEditorController c;
  final bool readOnly;

  Widget _text(String path, String label, {String? Function(String?)? validator, int maxLines = 1, String? helper, bool nullable = false}) {
    return _ValidatedField(
      initial: (c.read(path) ?? '').toString(),
      label: label,
      helper: helper,
      maxLines: maxLines,
      readOnly: readOnly,
      serverError: c.err(path),
      validator: validator,
      onChanged: (v) => c.write(path, nullable && v.trim().isEmpty ? null : v),
    );
  }

  Widget _switch(String path, String label, {String? subtitle}) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(label),
      subtitle: subtitle == null ? null : Text(subtitle),
      value: c.read(path) == true,
      onChanged: readOnly ? null : (v) => c.mutate((_) => c.write(path, v)),
    );
  }

  Widget _color(String path, String label) {
    return _ColorField(
      initial: '${c.read(path) ?? ''}',
      label: label,
      readOnly: readOnly,
      serverError: c.err(path),
      onChanged: (v) => c.write(path, v),
    );
  }

  Widget _grid(List<Widget> children, {double min = 220}) => ResponsiveGrid(minItemWidth: min, children: children);

  @override
  Widget build(BuildContext context) {
    final banners = (c.read('banners') as List? ?? const []);
    final pages = (c.read('onboarding.pages') as List? ?? const []);
    final strings = asJson(c.read('strings'));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionCard(
          title: 'Branding',
          child: _grid([
            _text('branding.appTitle', 'App title', validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null),
            _text('branding.logoUrl', 'Logo URL (https)', validator: validateOptionalHttps, nullable: true),
          ], min: 300),
        ),
        const SizedBox(height: 16),
        SectionCard(
          title: 'Theme',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _grid([
                DropdownButtonFormField<String>(
                  initialValue: '${c.read('theme.defaultMode')}',
                  decoration: const InputDecoration(labelText: 'Default mode'),
                  items: const [
                    DropdownMenuItem(value: 'system', child: Text('Follow system')),
                    DropdownMenuItem(value: 'light', child: Text('Light')),
                    DropdownMenuItem(value: 'dark', child: Text('Dark')),
                  ],
                  onChanged: readOnly ? null : (v) => c.write('theme.defaultMode', v),
                ),
                _switch('theme.darkModeEnabled', 'Dark mode available'),
              ], min: 300),
              const SizedBox(height: 16),
              Text('Light palette', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              _grid([
                for (final k in ['primary', 'secondary', 'background', 'surface', 'error']) _color('theme.light.$k', k),
              ], min: 160),
              const SizedBox(height: 16),
              Text('Dark palette', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              _grid([
                for (final k in ['primary', 'secondary', 'background', 'surface', 'error']) _color('theme.dark.$k', k),
              ], min: 160),
            ],
          ),
        ),
        const SizedBox(height: 16),
        SectionCard(
          title: 'Maintenance mode',
          subtitle: 'Apps show a maintenance screen while enabled.',
          child: Column(
            children: [
              _switch('maintenance.enabled', 'Enable maintenance mode'),
              _grid([
                _text('maintenance.title', 'Title'),
                _text(
                  'maintenance.estimatedEndAt',
                  'Estimated end (ISO 8601, optional)',
                  nullable: true,
                  validator: (v) => (v == null || v.isEmpty || DateTime.tryParse(v) != null) ? null : 'e.g. 2026-10-12T18:00:00Z',
                ),
              ], min: 300),
              const SizedBox(height: 12),
              _text('maintenance.message', 'Message', maxLines: 3),
            ],
          ),
        ),
        const SizedBox(height: 16),
        SectionCard(
          title: 'Update policy',
          subtitle: 'Below the minimum version the app must force an update; below the latest it may recommend one. Enforcement happens in the app.',
          child: Column(
            children: [
              for (final p in ['android', 'ios']) ...[
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(p == 'ios' ? 'iOS' : 'Android', style: Theme.of(context).textTheme.titleSmall),
                ),
                const SizedBox(height: 8),
                _grid([
                  _text('updatePolicy.$p.minimumVersion', 'Minimum supported', validator: validateOptionalSemver, nullable: true),
                  _text('updatePolicy.$p.latestVersion', 'Latest recommended', validator: validateOptionalSemver, nullable: true),
                  _text('updatePolicy.$p.updateUrl', 'Store URL (https)', validator: validateOptionalHttps, nullable: true),
                ]),
                const SizedBox(height: 16),
              ],
              _text('updatePolicy.message', 'Update message', maxLines: 2),
            ],
          ),
        ),
        const SizedBox(height: 16),
        SectionCard(
          title: 'Home banners',
          trailing: readOnly
              ? null
              : TextButton.icon(
                  onPressed: () => c.mutate(
                    (cfg) => (cfg['banners'] as List).add({
                      'id': 'banner_${DateTime.now().millisecondsSinceEpoch % 100000}',
                      'title': 'New banner',
                      'subtitle': null,
                      'imageUrl': null,
                      'actionUrl': null,
                      'active': true,
                      'priority': 0,
                      'startsAt': null,
                      'endsAt': null,
                    }),
                  ),
                  icon: const Icon(Icons.add),
                  label: const Text('Add banner'),
                ),
          child: banners.isEmpty
              ? const EmptyState(title: 'No banners', icon: Icons.view_carousel_outlined)
              : Column(
                  children: [
                    for (var i = 0; i < banners.length; i++)
                      _ListItemCard(
                        title: 'Banner ${i + 1}',
                        onRemove: readOnly ? null : () => c.mutate((cfg) => (cfg['banners'] as List).removeAt(i)),
                        child: Column(
                          children: [
                            _grid([
                              _text(
                                'banners.$i.id',
                                'Id',
                                validator: (v) => (v != null && configKeyPattern.hasMatch(v)) ? null : 'lowercase, digits, _ . -',
                              ),
                              _text('banners.$i.title', 'Title', validator: (v) => (v == null || v.isEmpty) ? 'Required' : null),
                              _text('banners.$i.subtitle', 'Subtitle', nullable: true),
                              _text('banners.$i.imageUrl', 'Image URL (https)', validator: validateOptionalHttps, nullable: true),
                              _text('banners.$i.actionUrl', 'Action URL / deep link', nullable: true),
                              _ValidatedField(
                                initial: '${c.read('banners.$i.priority') ?? 0}',
                                label: 'Priority (0-1000)',
                                readOnly: readOnly,
                                serverError: c.err('banners.$i.priority'),
                                validator: (v) => (int.tryParse(v ?? '') ?? -1) >= 0 ? null : 'Number 0-1000',
                                onChanged: (v) => c.write('banners.$i.priority', int.tryParse(v) ?? 0),
                              ),
                              _text('banners.$i.startsAt', 'Starts at (ISO, optional)', nullable: true),
                              _text('banners.$i.endsAt', 'Ends at (ISO, optional)', nullable: true),
                            ]),
                            _switch('banners.$i.active', 'Active'),
                          ],
                        ),
                      ),
                  ],
                ),
        ),
        const SizedBox(height: 16),
        SectionCard(
          title: 'Onboarding',
          trailing: readOnly
              ? null
              : TextButton.icon(
                  onPressed: () => c.mutate(
                    (cfg) => (asJson(cfg['onboarding'])['pages'] as List).add({'title': 'Welcome', 'body': '', 'imageUrl': null}),
                  ),
                  icon: const Icon(Icons.add),
                  label: const Text('Add page'),
                ),
          child: Column(
            children: [
              _switch('onboarding.enabled', 'Show onboarding to new users'),
              for (var i = 0; i < pages.length; i++)
                _ListItemCard(
                  title: 'Page ${i + 1}',
                  onRemove: readOnly ? null : () => c.mutate((cfg) => (asJson(cfg['onboarding'])['pages'] as List).removeAt(i)),
                  child: Column(
                    children: [
                      _grid([
                        _text('onboarding.pages.$i.title', 'Title', validator: (v) => (v == null || v.isEmpty) ? 'Required' : null),
                        _text('onboarding.pages.$i.imageUrl', 'Image URL (https)', validator: validateOptionalHttps, nullable: true),
                      ], min: 300),
                      const SizedBox(height: 12),
                      _text('onboarding.pages.$i.body', 'Body', maxLines: 3),
                    ],
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        SectionCard(
          title: 'Content strings',
          subtitle: 'Copy for screens the app already renders, keyed like "home.welcome".',
          trailing: readOnly
              ? null
              : TextButton.icon(
                  onPressed: () async {
                    final key = await _askKey();
                    if (key != null) c.mutate((cfg) => asJson(cfg['strings'])[key] = '');
                  },
                  icon: const Icon(Icons.add),
                  label: const Text('Add string'),
                ),
          child: strings.isEmpty
              ? const EmptyState(title: 'No strings', icon: Icons.translate)
              : Column(
                  children: [
                    for (final key in strings.keys.toList()..sort())
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 200,
                              child: Text(key, style: const TextStyle(fontFamily: 'monospace')),
                            ),
                            Expanded(child: _text('strings.$key', 'Value')),
                            if (!readOnly)
                              IconButton(
                                tooltip: 'Remove',
                                icon: const Icon(Icons.delete_outline),
                                onPressed: () => c.mutate((cfg) => asJson(cfg['strings']).remove(key)),
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
        ),
        const SizedBox(height: 16),
        SectionCard(
          title: 'Internal notes',
          subtitle: 'Visible to admins only. Never sent to apps.',
          child: _text('internalNotes', 'Notes', maxLines: 4),
        ),
      ],
    );
  }

  Future<String?> _askKey() {
    final ctrl = TextEditingController();
    final formKey = GlobalKey<FormState>();
    return Get.dialog<String>(
      AlertDialog(
        title: const Text('New string key'),
        content: Form(
          key: formKey,
          child: TextFormField(
            controller: ctrl,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Key', hintText: 'home.welcome'),
            validator: (v) => (v != null && configKeyPattern.hasMatch(v)) ? null : 'lowercase letters, digits, _ . -',
          ),
        ),
        actions: [
          TextButton(onPressed: Get.back, child: const Text('Cancel')),
          FilledButton(
            onPressed: () => formKey.currentState!.validate() ? Get.back(result: ctrl.text.trim()) : null,
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }
}

class _ListItemCard extends StatelessWidget {
  const _ListItemCard({required this.title, required this.child, this.onRemove});
  final String title;
  final Widget child;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerTheme.color ?? Colors.grey),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text(title, style: Theme.of(context).textTheme.titleSmall)),
              if (onRemove != null) IconButton(tooltip: 'Remove', onPressed: onRemove, icon: const Icon(Icons.delete_outline)),
            ],
          ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}

class _ValidatedField extends StatelessWidget {
  const _ValidatedField({
    required this.initial,
    required this.label,
    required this.onChanged,
    this.validator,
    this.helper,
    this.serverError,
    this.maxLines = 1,
    this.readOnly = false,
  });

  final String initial;
  final String label;
  final ValueChanged<String> onChanged;
  final String? Function(String?)? validator;
  final String? helper;
  final String? serverError;
  final int maxLines;
  final bool readOnly;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      initialValue: initial,
      readOnly: readOnly,
      maxLines: maxLines,
      autovalidateMode: AutovalidateMode.onUserInteraction,
      validator: validator,
      decoration: InputDecoration(labelText: label, helperText: helper, errorText: serverError),
      onChanged: onChanged,
    );
  }
}

class _ColorField extends StatefulWidget {
  const _ColorField({required this.initial, required this.label, required this.onChanged, this.readOnly = false, this.serverError});
  final String initial;
  final String label;
  final ValueChanged<String> onChanged;
  final bool readOnly;
  final String? serverError;

  @override
  State<_ColorField> createState() => _ColorFieldState();
}

class _ColorFieldState extends State<_ColorField> {
  late String value = widget.initial;

  @override
  Widget build(BuildContext context) {
    final argb = parseHexColor(value);
    return TextFormField(
      initialValue: widget.initial,
      readOnly: widget.readOnly,
      autovalidateMode: AutovalidateMode.onUserInteraction,
      validator: validateHex,
      decoration: InputDecoration(
        labelText: widget.label,
        errorText: widget.serverError,
        prefixIcon: Padding(
          padding: const EdgeInsets.all(10),
          child: Semantics(
            label: 'Color preview',
            child: Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                color: argb == null ? Colors.transparent : Color(argb),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: Theme.of(context).colorScheme.outline),
              ),
            ),
          ),
        ),
      ),
      onChanged: (v) {
        setState(() => value = v);
        widget.onChanged(v);
      },
    );
  }
}
