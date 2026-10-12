import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../core/api/api_client.dart';
import '../../core/api/api_exception.dart';
import '../../core/models/models.dart';
import '../../core/services/session_service.dart';
import '../../core/services/theme_service.dart';
import '../../widgets/app_shell.dart';
import '../../widgets/common.dart';
import '../../widgets/confirm_dialog.dart';
import '../../widgets/notify.dart';
import '../../widgets/states.dart';

class ProfileController extends GetxController {
  ProfileController(this.api, this.session);
  final ApiClient api;
  final SessionService session;

  final sessions = <Json>[].obs;
  final loading = true.obs;
  final error = RxnString();
  final saving = false.obs;
  late final name = TextEditingController(text: session.admin.value?.name ?? '');
  final current = TextEditingController();
  final next = TextEditingController();
  final confirm = TextEditingController();
  final passwordForm = GlobalKey<FormState>();
  final passwordError = RxnString();

  @override
  void onReady() {
    super.onReady();
    loadSessions();
  }

  Future<void> loadSessions() async {
    loading.value = true;
    error.value = null;
    try {
      sessions.assignAll(((await api.get('/auth/sessions')) as List).map(asJson));
    } on ApiException catch (e) {
      error.value = e.message;
    } finally {
      loading.value = false;
    }
  }

  Future<void> saveName() async {
    if (name.text.trim().isEmpty) return;
    try {
      await api.patch('/auth/me', body: {'name': name.text.trim()});
      await session.reloadProfile();
      notifySuccess('Profile updated');
    } on ApiException catch (e) {
      notifyError(e);
    }
  }

  Future<void> changePassword() async {
    passwordError.value = null;
    if (!passwordForm.currentState!.validate()) return;
    saving.value = true;
    try {
      final res = asJson(await api.post('/auth/change-password', body: {'currentPassword': current.text, 'newPassword': next.text}));
      current.clear();
      next.clear();
      confirm.clear();
      notifySuccess('Password changed. ${res['revokedSessions']} other session(s) signed out.');
      await loadSessions();
    } on ApiException catch (e) {
      passwordError.value = e.fieldErrors.isNotEmpty ? e.fieldErrors.first.message : e.message;
    } finally {
      saving.value = false;
    }
  }

  Future<void> revoke(Json s) async {
    try {
      await api.delete('/auth/sessions/${s['id']}');
      notifySuccess('Session revoked');
      await loadSessions();
    } on ApiException catch (e) {
      notifyError(e);
    }
  }

  Future<void> revokeOthers() async {
    if (!await confirmAction(
      title: 'Sign out other sessions?',
      message: 'All other browsers and devices will be signed out.',
      confirmLabel: 'Sign out others',
      destructive: true,
    )) {
      return;
    }
    try {
      final res = asJson(await api.post('/auth/sessions/revoke-others'));
      notifySuccess('${res['revoked']} session(s) signed out');
      await loadSessions();
    } on ApiException catch (e) {
      notifyError(e);
    }
  }
}

class ProfileView extends StatelessWidget {
  const ProfileView({super.key});

  @override
  Widget build(BuildContext context) {
    final c = Get.put(ProfileController(Get.find(), Get.find()));
    final theme = Get.find<ThemeService>();
    final admin = c.session.admin.value;
    return AppShell(
      title: 'Profile & security',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionCard(
            title: 'Profile',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                InfoRow('Email', admin?.email),
                InfoRow('Platform role', admin?.isSuperAdmin == true ? 'Super Admin' : 'Member'),
                Obx(() => InfoRow('Memberships', c.session.organizations.map((o) => '${o.name} (${roleLabel(o.role)})').join(', '))),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: c.name,
                        decoration: const InputDecoration(labelText: 'Display name'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    FilledButton(onPressed: c.saveName, child: const Text('Save')),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          SectionCard(
            title: 'Appearance',
            child: Obx(
              () => SegmentedButton<ThemeMode>(
                segments: const [
                  ButtonSegment(value: ThemeMode.system, label: Text('System'), icon: Icon(Icons.brightness_auto_outlined)),
                  ButtonSegment(value: ThemeMode.light, label: Text('Light'), icon: Icon(Icons.light_mode_outlined)),
                  ButtonSegment(value: ThemeMode.dark, label: Text('Dark'), icon: Icon(Icons.dark_mode_outlined)),
                ],
                selected: {theme.mode.value},
                onSelectionChanged: (s) => theme.setMode(s.first),
              ),
            ),
          ),
          const SizedBox(height: 20),
          SectionCard(
            title: 'Change password',
            subtitle: 'Changing your password signs out all other sessions.',
            child: Form(
              key: c.passwordForm,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextFormField(
                    controller: c.current,
                    obscureText: true,
                    decoration: const InputDecoration(labelText: 'Current password'),
                    validator: (v) => (v == null || v.isEmpty) ? 'Required' : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: c.next,
                    obscureText: true,
                    decoration: const InputDecoration(labelText: 'New password', helperText: 'At least 12 characters'),
                    validator: (v) => (v == null || v.length < 12) ? 'At least 12 characters' : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: c.confirm,
                    obscureText: true,
                    decoration: const InputDecoration(labelText: 'Confirm new password'),
                    validator: (v) => v != c.next.text ? 'Passwords do not match' : null,
                  ),
                  Obx(
                    () => c.passwordError.value == null
                        ? const SizedBox(height: 12)
                        : Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Text(c.passwordError.value!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                          ),
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Obx(
                      () => FilledButton(onPressed: c.saving.value ? null : c.changePassword, child: const Text('Change password')),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          SectionCard(
            title: 'Active sessions',
            trailing: TextButton(onPressed: c.revokeOthers, child: const Text('Sign out other sessions')),
            child: Obx(
              () => AsyncBody(
                loading: c.loading.value,
                error: c.error.value,
                onRetry: c.loadSessions,
                builder: (_) => Column(
                  children: [
                    for (final s in c.sessions)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(s['current'] == true ? Icons.computer : Icons.devices_other),
                        title: Text('${s['userAgent'] ?? 'Unknown device'}', maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          '${s['ip'] ?? ''} · last active ${timeAgo(parseDate(s['lastUsedAt']))} · expires ${formatDate(parseDate(s['expiresAt']))}',
                        ),
                        trailing: s['current'] == true
                            ? const Chip(label: Text('This session'))
                            : TextButton(onPressed: () => c.revoke(s), child: const Text('Revoke')),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
