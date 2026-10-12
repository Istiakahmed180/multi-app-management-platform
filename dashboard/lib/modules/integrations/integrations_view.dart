import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

class IntegrationsController extends GetxController with AppScope {
  IntegrationsController(this.api, this.session);
  final ApiClient api;
  final SessionService session;

  final data = Rxn<Json>();
  final loading = true.obs;
  final error = RxnString();
  final busy = false.obs;

  bool get canWrite => session.can('integrations:write');

  @override
  void onReady() {
    super.onReady();
    load();
  }

  Future<void> load() async {
    loading.value = true;
    error.value = null;
    try {
      data.value = asJson(await api.get('/apps/$appId/integrations'));
    } on ApiException catch (e) {
      error.value = e.message;
    } finally {
      loading.value = false;
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    busy.value = true;
    try {
      await action();
      await load();
    } on ApiException catch (e) {
      notifyError(e);
    } finally {
      busy.value = false;
    }
  }

  Future<void> configureFcm() async {
    final ctrl = TextEditingController();
    final json = await Get.dialog<String>(
      AlertDialog(
        title: const Text('Firebase service account'),
        content: SizedBox(
          width: 560,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Paste the service-account key JSON from Firebase console → Project settings → Service accounts. '
                'It is encrypted at rest on the server and never shown again or sent to apps.',
              ),
              const SizedBox(height: 12),
              TextField(
                controller: ctrl,
                maxLines: 10,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                decoration: const InputDecoration(hintText: '{ "type": "service_account", ... }'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: Get.back, child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Get.back(result: ctrl.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (json == null || json.isEmpty) return;
    await _run(() async {
      await api.put('/apps/$appId/integrations/fcm', body: {'serviceAccountJson': json});
      notifySuccess('Firebase Cloud Messaging configured');
    });
  }

  Future<void> testFcm() => _run(() async {
    await api.post('/apps/$appId/integrations/fcm/test');
    notifySuccess('Firebase accepted the credentials');
  });

  Future<void> removeFcm() async {
    if (!await confirmAction(
      title: 'Remove FCM credentials?',
      message: 'Scheduled campaigns will fail until new credentials are added.',
      confirmLabel: 'Remove',
      destructive: true,
    )) {
      return;
    }
    await _run(() async {
      await api.delete('/apps/$appId/integrations/fcm');
      notifySuccess('Credentials removed');
    });
  }

  Future<void> _showSecret(String title, String secret, String help) => Get.dialog<void>(
    AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(help),
            const SizedBox(height: 12),
            SelectableText(secret, style: const TextStyle(fontFamily: 'monospace')),
          ],
        ),
      ),
      actions: [
        TextButton.icon(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: secret));
            notifySuccess('Copied');
          },
          icon: const Icon(Icons.copy),
          label: const Text('Copy'),
        ),
        FilledButton(onPressed: Get.back, child: const Text('I stored it safely')),
      ],
    ),
    barrierDismissible: false,
  );

  Future<void> createKey() async {
    final ctrl = TextEditingController(text: 'Backend');
    final name = await Get.dialog<String>(
      AlertDialog(
        title: const Text('New server API key'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Name'),
        ),
        actions: [
          TextButton(onPressed: Get.back, child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Get.back(result: ctrl.text.trim()),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    await _run(() async {
      final res = asJson(await api.post('/apps/$appId/integrations/api-keys', body: {'name': name}));
      await _showSecret(
        'API key created',
        '${res['apiKey']}',
        'Use this key only from your app backend (Authorization: Bearer …). Never put it in the Flutter app. It will not be shown again.',
      );
    });
  }

  Future<void> revokeKey(Json k) async {
    if (!await confirmAction(
      title: 'Revoke "${k['name']}"?',
      message: 'Requests using this key will be rejected immediately.',
      confirmLabel: 'Revoke',
      destructive: true,
    )) {
      return;
    }
    await _run(() async {
      await api.delete('/apps/$appId/integrations/api-keys/${k['id']}');
      notifySuccess('Key revoked');
    });
  }

  Future<void> configureWebhook() async {
    final ctrl = TextEditingController();
    final url = await Get.dialog<String>(
      AlertDialog(
        title: const Text('Webhook endpoint'),
        content: SizedBox(
          width: 480,
          child: TextField(
            controller: ctrl,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'HTTPS URL', hintText: 'https://api.example.com/hooks/amp'),
          ),
        ),
        actions: [
          TextButton(onPressed: Get.back, child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Get.back(result: ctrl.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (url == null || url.isEmpty) return;
    await _run(() async {
      final res = asJson(await api.put('/apps/$appId/integrations/webhook', body: {'url': url}));
      await _showSecret(
        'Webhook signing secret',
        '${res['signingSecret']}',
        'Verify the X-AMP-Signature header (t=<ts>,v1=HMAC-SHA256(secret, "<ts>.<body>")) on every request. It will not be shown again.',
      );
    });
  }

  Future<void> testWebhook() => _run(() async {
    final res = asJson(await api.post('/apps/$appId/integrations/webhook/test'));
    if (res['ok'] == true) {
      notifySuccess('Webhook responded with HTTP ${res['status']}');
    } else {
      notifyError(ApiException(code: 'webhook_failed', message: 'Webhook delivery failed: ${res['error'] ?? res['status']}'));
    }
  });

  Future<void> removeWebhook() async {
    if (!await confirmAction(
      title: 'Remove webhook?',
      message: 'Your backend will no longer be notified of user status changes.',
      confirmLabel: 'Remove',
      destructive: true,
    )) {
      return;
    }
    await _run(() async {
      await api.delete('/apps/$appId/integrations/webhook');
      notifySuccess('Webhook removed');
    });
  }
}

class IntegrationsView extends StatelessWidget {
  const IntegrationsView({super.key});

  @override
  Widget build(BuildContext context) {
    final c = Get.put(IntegrationsController(Get.find(), Get.find()));
    return AppShell(
      title: 'Integrations & settings',
      breadcrumbs: [const Crumb('Apps', Routes.apps), Crumb(c.appName, Routes.app(c.appId))],
      body: Obx(
        () => AsyncBody(
          loading: c.loading.value && c.data.value == null,
          error: c.error.value,
          onRetry: c.load,
          builder: (context) {
            final d = c.data.value!;
            final fcm = d['fcm'] == null ? null : asJson(d['fcm']);
            final hook = d['webhook'] == null ? null : asJson(d['webhook']);
            final keys = (d['apiKeys'] as List? ?? const []).map(asJson).toList();
            final storage = asJson(d['storage']);
            final w = c.canWrite && !c.busy.value;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SectionCard(
                  title: 'Firebase Cloud Messaging',
                  subtitle: 'Per-app service account used to send push notifications.',
                  trailing: StatusChip(fcm == null ? 'disabled' : 'enabled'),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (fcm != null) ...[
                        InfoRow('Project', '${asJson(fcm['publicConfig'])['projectId']}'),
                        InfoRow('Service account', '${asJson(fcm['publicConfig'])['clientEmail']}'),
                        InfoRow('Configured', formatDateTime(parseDate(fcm['createdAt']))),
                      ] else
                        const Text('Not configured. Push campaigns cannot be scheduled until credentials are added.'),
                      const SizedBox(height: 12),
                      if (c.canWrite)
                        Wrap(
                          spacing: 8,
                          children: [
                            FilledButton(
                              onPressed: w ? c.configureFcm : null,
                              child: Text(fcm == null ? 'Add credentials' : 'Replace credentials'),
                            ),
                            if (fcm != null) OutlinedButton(onPressed: w ? c.testFcm : null, child: const Text('Test credentials')),
                            if (fcm != null) TextButton(onPressed: w ? c.removeFcm : null, child: const Text('Remove')),
                          ],
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                SectionCard(
                  title: 'Server API keys',
                  subtitle: 'For your app backend to sync users, push tokens and activity (ingest API). Keys are stored hashed.',
                  trailing: c.canWrite
                      ? FilledButton.icon(onPressed: w ? c.createKey : null, icon: const Icon(Icons.add), label: const Text('New key'))
                      : null,
                  child: keys.isEmpty
                      ? const EmptyState(title: 'No API keys', icon: Icons.key_outlined)
                      : Column(
                          children: [
                            for (final k in keys)
                              ListTile(
                                contentPadding: EdgeInsets.zero,
                                leading: const Icon(Icons.key_outlined),
                                title: Text('${k['name']}'),
                                subtitle: Text(
                                  '${k['keyPrefix']}… · created ${formatDate(parseDate(k['createdAt']))} · last used ${timeAgo(parseDate(k['lastUsedAt']))}',
                                ),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    StatusChip('${k['status']}'),
                                    if (c.canWrite && k['status'] == 'active')
                                      TextButton(onPressed: w ? () => c.revokeKey(k) : null, child: const Text('Revoke')),
                                  ],
                                ),
                              ),
                          ],
                        ),
                ),
                const SizedBox(height: 20),
                SectionCard(
                  title: 'Webhook',
                  subtitle: 'Signed callbacks to your app backend (e.g. user.status_changed).',
                  trailing: StatusChip(hook == null ? 'disabled' : 'enabled'),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (hook != null) ...[
                        InfoRow('URL', '${asJson(hook['publicConfig'])['url']}'),
                        InfoRow(
                          'Last delivery',
                          hook['lastDeliveryAt'] == null
                              ? 'never'
                              : '${timeAgo(parseDate(hook['lastDeliveryAt']))} · ${hook['lastDeliveryStatus']}',
                        ),
                      ] else
                        const Text('Not configured. User suspensions are recorded but not pushed to your backend.'),
                      const SizedBox(height: 12),
                      if (c.canWrite)
                        Wrap(
                          spacing: 8,
                          children: [
                            FilledButton(
                              onPressed: w ? c.configureWebhook : null,
                              child: Text(hook == null ? 'Add webhook' : 'Replace webhook'),
                            ),
                            if (hook != null) OutlinedButton(onPressed: w ? c.testWebhook : null, child: const Text('Send test')),
                            if (hook != null) TextButton(onPressed: w ? c.removeWebhook : null, child: const Text('Remove')),
                          ],
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                SectionCard(
                  title: 'Object storage',
                  subtitle: 'S3-compatible storage for app images (configured on the server).',
                  trailing: StatusChip(storage['configured'] == true ? 'enabled' : 'disabled'),
                  child: Text(
                    storage['configured'] == true ? 'Uploads use short-lived presigned URLs.' : 'Not configured. Set S3_BUCKET, S3_ACCESS_KEY_ID and S3_SECRET_ACCESS_KEY on the API server. Image URLs can still be entered manually.',
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
