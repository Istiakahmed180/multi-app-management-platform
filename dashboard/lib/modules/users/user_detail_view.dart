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
import '../../widgets/notify.dart';
import '../../widgets/states.dart';

class UserDetailController extends GetxController with AppScope {
  UserDetailController(this.api, this.session);
  final ApiClient api;
  final SessionService session;

  final userId = Get.parameters['userId'] ?? '';
  final user = Rxn<Json>();
  final loading = true.obs;
  final error = RxnString();
  final busy = false.obs;

  bool get canWrite => session.can('users:write');

  @override
  void onReady() {
    super.onReady();
    load();
  }

  Future<void> load() async {
    loading.value = true;
    error.value = null;
    try {
      user.value = asJson(await api.get('/apps/$appId/users/$userId'));
    } on ApiException catch (e) {
      error.value = e.message;
    } finally {
      loading.value = false;
    }
  }

  Future<void> changeStatus(String status) async {
    final reason = TextEditingController();
    final suspending = status == 'suspended';
    final ok = await Get.dialog<bool>(
      AlertDialog(
        title: Text(suspending ? 'Suspend user' : 'Reactivate user'),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                suspending
                    ? 'The status is recorded in the registry and sent to your app backend if a webhook is configured. Your backend is responsible for enforcing it.'
                    : 'The user will be marked active again.',
              ),
              const SizedBox(height: 12),
              TextField(
                controller: reason,
                maxLength: 500,
                decoration: const InputDecoration(labelText: 'Reason (recorded in the audit log)'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Get.back(result: false), child: const Text('Cancel')),
          FilledButton(
            style: suspending ? FilledButton.styleFrom(backgroundColor: Get.theme.colorScheme.error) : null,
            onPressed: () => Get.back(result: true),
            child: Text(suspending ? 'Suspend' : 'Reactivate'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    busy.value = true;
    try {
      final res = asJson(
        await api.patch(
          '/apps/$appId/users/$userId/status',
          body: {'status': status, if (reason.text.trim().isNotEmpty) 'reason': reason.text.trim()},
        ),
      );
      final propagation = asJson(res['propagation']);
      if (propagation['attempted'] != true) {
        notifySuccess('Status recorded. No webhook is configured, so your app backend was not notified.');
      } else if (propagation['delivered'] == true) {
        notifySuccess('Status updated and delivered to your app backend');
      } else {
        notifyError(
          ApiException(
            code: 'webhook_failed',
            message: 'Status recorded, but webhook delivery failed: ${propagation['error'] ?? propagation['httpStatus']}',
          ),
        );
      }
      await load();
    } on ApiException catch (e) {
      notifyError(e);
    } finally {
      busy.value = false;
    }
  }
}

class UserDetailView extends StatelessWidget {
  const UserDetailView({super.key});

  @override
  Widget build(BuildContext context) {
    final c = Get.put(UserDetailController(Get.find(), Get.find()));
    return Obx(() {
      final u = c.user.value;
      return AppShell(
        title: u == null ? 'User' : '${u['displayName'] ?? u['email'] ?? u['externalUserId']}',
        breadcrumbs: [const Crumb('Apps', Routes.apps), Crumb(c.appName, Routes.app(c.appId)), Crumb('Users', Routes.users(c.appId))],
        actions: [
          if (u != null && c.canWrite)
            u['status'] == 'suspended'
                ? FilledButton.icon(
                    onPressed: c.busy.value ? null : () => c.changeStatus('active'),
                    icon: const Icon(Icons.lock_open),
                    label: const Text('Reactivate'),
                  )
                : OutlinedButton.icon(
                    onPressed: c.busy.value ? null : () => c.changeStatus('suspended'),
                    icon: const Icon(Icons.block),
                    label: const Text('Suspend'),
                  ),
        ],
        body: AsyncBody(
          loading: c.loading.value && u == null,
          error: c.error.value,
          onRetry: c.load,
          builder: (context) {
            final activity = asJson(u!['activity']);
            final recent = (activity['recent'] as List? ?? const []).map(asJson).toList();
            final attrs = asJson(u['attributes']);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SectionCard(
                  title: 'Profile',
                  child: Column(
                    children: [
                      InfoRow(
                        'Status',
                        null,
                        child: Align(alignment: Alignment.centerLeft, child: StatusChip('${u['status']}')),
                      ),
                      if (u['statusReason'] != null) InfoRow('Status reason', '${u['statusReason']}'),
                      if (u['statusChangedAt'] != null) InfoRow('Status changed', formatDateTime(parseDate(u['statusChangedAt']))),
                      InfoRow('External user id', '${u['externalUserId']}'),
                      InfoRow('Email', '${u['email'] ?? '—'}'),
                      InfoRow('Display name', '${u['displayName'] ?? '—'}'),
                      InfoRow('Platform / version', '${u['platform'] ?? '—'} / ${u['appVersion'] ?? '—'}'),
                      InfoRow('Locale', '${u['locale'] ?? '—'}'),
                      InfoRow('Push', u['pushOptIn'] == true ? 'Opted in · ${u['pushTokenCount']} device token(s)' : 'Opted out'),
                      InfoRow('First seen', formatDateTime(parseDate(u['firstSeenAt']))),
                      InfoRow('Last seen', formatDateTime(parseDate(u['lastSeenAt']))),
                      if (attrs.isNotEmpty) InfoRow('Attributes', const JsonEncoder.withIndent('  ').convert(attrs)),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                SectionCard(
                  title: 'Recent activity',
                  subtitle: activity['available'] == true ? '${activity['total']} events recorded' : null,
                  child: recent.isEmpty
                      ? const EmptyState(
                          icon: Icons.timeline,
                          title: 'No activity recorded',
                          message: 'Activity appears when your backend sends events through the ingest API.',
                        )
                      : Column(
                          children: [
                            for (final e in recent)
                              ListTile(
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                leading: const Icon(Icons.bolt_outlined, size: 18),
                                title: Text('${e['type']}'),
                                subtitle: Text(
                                  '${formatDateTime(parseDate(e['occurredAt']))} · ${e['platform'] ?? ''} ${e['appVersion'] ?? ''}',
                                ),
                              ),
                          ],
                        ),
                ),
              ],
            );
          },
        ),
      );
    });
  }
}
