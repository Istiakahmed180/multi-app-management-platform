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
import '../../widgets/notify.dart';
import '../../widgets/states.dart';

final _androidRx = RegExp(r'^[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z][a-zA-Z0-9_]*)+$');
final _iosRx = RegExp(r'^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$');
final _slugRx = RegExp(r'^[a-z0-9]+(?:-[a-z0-9]+)*$');

String? validateAndroidPackage(String? v) =>
    v == null || v.isEmpty ? 'Required for Android' : (_androidRx.hasMatch(v) ? null : 'e.g. com.example.app');
String? validateIosBundle(String? v) => v == null || v.isEmpty ? 'Required for iOS' : (_iosRx.hasMatch(v) ? null : 'e.g. com.example.app');

class AppFormController extends GetxController {
  AppFormController(this.api, this.session, this.workspace);
  final ApiClient api;
  final SessionService session;
  final WorkspaceService workspace;

  final String? appId = Get.parameters['appId'];
  bool get isEdit => appId != null;

  final formKey = GlobalKey<FormState>();
  final name = TextEditingController();
  final slug = TextEditingController();
  final description = TextEditingController();
  final androidPackageId = TextEditingController();
  final iosBundleId = TextEditingController();
  final iconUrl = TextEditingController();
  final android = true.obs;
  final ios = true.obs;
  final environment = 'production'.obs;
  final loading = false.obs;
  final saving = false.obs;
  final error = RxnString();
  final serverErrors = <String, String>{}.obs;

  @override
  void onInit() {
    super.onInit();
    if (isEdit) {
      workspace.selectApp(appId);
      load();
    }
  }

  Future<void> load() async {
    loading.value = true;
    error.value = null;
    try {
      final a = AppInfo.fromJson(asJson(await api.get('/apps/$appId')));
      name.text = a.name;
      slug.text = a.slug;
      description.text = a.description;
      androidPackageId.text = a.androidPackageId ?? '';
      iosBundleId.text = a.iosBundleId ?? '';
      iconUrl.text = a.iconUrl ?? '';
      android.value = a.platforms.contains('android');
      ios.value = a.platforms.contains('ios');
      environment.value = a.environment;
    } on ApiException catch (e) {
      error.value = e.message;
    } finally {
      loading.value = false;
    }
  }

  Future<void> save() async {
    serverErrors.clear();
    if (!android.value && !ios.value) {
      notifyError(const ApiException(code: 'validation', message: 'Select at least one platform'));
      return;
    }
    if (!(formKey.currentState?.validate() ?? false)) return;
    saving.value = true;
    final body = {
      'name': name.text.trim(),
      if (slug.text.trim().isNotEmpty) 'slug': slug.text.trim(),
      'description': description.text.trim(),
      'platforms': [if (android.value) 'android', if (ios.value) 'ios'],
      'androidPackageId': android.value ? androidPackageId.text.trim() : null,
      'iosBundleId': ios.value ? iosBundleId.text.trim() : null,
      'environment': environment.value,
      'iconUrl': iconUrl.text.trim().isEmpty ? null : iconUrl.text.trim(),
    };
    try {
      final res = isEdit
          ? asJson(await api.patch('/apps/$appId', body: body))
          : asJson(await api.post('/apps', body: {...body, 'orgId': session.currentOrg.value!.id}));
      await workspace.loadApps();
      notifySuccess(isEdit ? 'App updated' : 'App registered');
      Get.offNamed(Routes.app('${res['id']}'));
    } on ApiException catch (e) {
      for (final f in e.fieldErrors) {
        serverErrors[f.path] = f.message;
      }
      notifyError(e);
    } finally {
      saving.value = false;
    }
  }

  @override
  void onClose() {
    for (final c in [name, slug, description, androidPackageId, iosBundleId, iconUrl]) {
      c.dispose();
    }
    super.onClose();
  }
}

class AppFormView extends StatelessWidget {
  const AppFormView({super.key});

  @override
  Widget build(BuildContext context) {
    final c = Get.put(AppFormController(Get.find(), Get.find(), Get.find()));
    return AppShell(
      title: c.isEdit ? 'Edit app' : 'Register app',
      breadcrumbs: const [Crumb('Apps', Routes.apps)],
      body: Obx(
        () => AsyncBody(
          loading: c.loading.value,
          error: c.error.value,
          onRetry: c.load,
          builder: (context) => Form(
            key: c.formKey,
            child: SectionCard(
              title: 'App details',
              subtitle: 'The app key is generated automatically and identifies the app to the SDK. It is not a secret.',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Row(
                    children: [
                      TextFormField(
                        controller: c.name,
                        decoration: InputDecoration(labelText: 'Name *', errorText: c.serverErrors['name']),
                        validator: (v) => (v == null || v.trim().length < 2) ? 'At least 2 characters' : null,
                      ),
                      TextFormField(
                        controller: c.slug,
                        decoration: InputDecoration(
                          labelText: 'Slug',
                          helperText: c.isEdit ? null : 'Generated from the name if empty',
                          errorText: c.serverErrors['slug'],
                        ),
                        validator: (v) => (v == null || v.isEmpty || _slugRx.hasMatch(v)) ? null : 'Lowercase letters, digits and hyphens',
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: c.description,
                    maxLines: 3,
                    maxLength: 1000,
                    decoration: const InputDecoration(labelText: 'Description'),
                  ),
                  const SizedBox(height: 8),
                  Text('Platforms', style: Theme.of(context).textTheme.titleSmall),
                  Wrap(
                    spacing: 12,
                    children: [
                      FilterChip(
                        label: const Text('Android'),
                        avatar: const Icon(Icons.android, size: 18),
                        selected: c.android.value,
                        onSelected: (v) => c.android.value = v,
                      ),
                      FilterChip(
                        label: const Text('iOS'),
                        avatar: const Icon(Icons.apple, size: 18),
                        selected: c.ios.value,
                        onSelected: (v) => c.ios.value = v,
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _Row(
                    children: [
                      if (c.android.value)
                        TextFormField(
                          controller: c.androidPackageId,
                          decoration: InputDecoration(labelText: 'Android package id *', errorText: c.serverErrors['androidPackageId']),
                          validator: validateAndroidPackage,
                        ),
                      if (c.ios.value)
                        TextFormField(
                          controller: c.iosBundleId,
                          decoration: InputDecoration(labelText: 'iOS bundle id *', errorText: c.serverErrors['iosBundleId']),
                          validator: validateIosBundle,
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _Row(
                    children: [
                      DropdownButtonFormField<String>(
                        initialValue: c.environment.value,
                        decoration: const InputDecoration(labelText: 'Environment'),
                        items: const [
                          DropdownMenuItem(value: 'production', child: Text('Production')),
                          DropdownMenuItem(value: 'staging', child: Text('Staging')),
                          DropdownMenuItem(value: 'development', child: Text('Development')),
                        ],
                        onChanged: (v) => c.environment.value = v ?? 'production',
                      ),
                      TextFormField(
                        controller: c.iconUrl,
                        decoration: InputDecoration(labelText: 'Icon URL (https)', errorText: c.serverErrors['iconUrl']),
                        validator: (v) => (v == null || v.isEmpty || v.startsWith('https://')) ? null : 'Must be an https URL',
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(onPressed: Get.back, child: const Text('Cancel')),
                      const SizedBox(width: 8),
                      FilledButton(onPressed: c.saving.value ? null : c.save, child: Text(c.isEdit ? 'Save changes' : 'Register app')),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 640 || children.length < 2) {
          return Column(
            children: [
              for (final (i, c) in children.indexed)
                Padding(
                  padding: EdgeInsets.only(top: i == 0 ? 0 : 16),
                  child: c,
                ),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final (i, c) in children.indexed) ...[if (i > 0) const SizedBox(width: 16), Expanded(child: c)],
          ],
        );
      },
    );
  }
}
