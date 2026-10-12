import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../../core/api/api_client.dart';
import '../../core/api/api_exception.dart';
import '../../core/controllers/paged_controller.dart';
import '../../core/models/models.dart';
import '../../core/services/session_service.dart';
import '../../core/services/workspace_service.dart';
import '../../widgets/app_shell.dart';
import '../../widgets/common.dart';
import '../../widgets/confirm_dialog.dart';
import '../../widgets/data_table_card.dart';
import '../../widgets/notify.dart';
import '../../widgets/states.dart';

class MembersController extends PagedController<Member> {
  MembersController(this.api, this.session, this.workspace);
  final ApiClient api;
  final SessionService session;
  final WorkspaceService workspace;

  final invitations = <Json>[].obs;

  String get orgId => session.currentOrg.value!.id;
  bool get canManage => session.can('members:manage');

  @override
  Future<Paged<Member>> fetch(Map<String, dynamic> query) => api.getPaged('/organizations/$orgId/members', Member.fromJson, query: query);

  @override
  Future<void> load() async {
    await super.load();
    try {
      invitations.assignAll(((await api.get('/organizations/$orgId/invitations')) as List).map(asJson));
    } on ApiException {
      invitations.clear();
    }
  }

  Future<void> invite(String email, String role, List<String> appIds) async {
    try {
      final res = asJson(await api.post('/organizations/$orgId/invitations', body: {'email': email, 'role': role, 'appIds': appIds}));
      await load();
      final link = res['inviteUrl'] as String? ?? 'Invitation token: ${res['inviteToken']}';
      await Get.dialog<void>(
        AlertDialog(
          title: const Text('Invitation created'),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('No email provider is configured, so share this one-time link with the invitee. It will not be shown again.'),
                const SizedBox(height: 12),
                SelectableText(link, style: const TextStyle(fontFamily: 'monospace')),
              ],
            ),
          ),
          actions: [
            TextButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: link));
                notifySuccess('Copied to clipboard');
              },
              icon: const Icon(Icons.copy),
              label: const Text('Copy'),
            ),
            FilledButton(onPressed: Get.back, child: const Text('Done')),
          ],
        ),
      );
    } on ApiException catch (e) {
      notifyError(e);
    }
  }

  Future<void> updateMember(Member m, String role, List<String> appIds) async {
    try {
      await api.patch('/organizations/$orgId/members/${m.id}', body: {'role': role, 'appIds': appIds});
      notifySuccess('Member updated');
      await load();
    } on ApiException catch (e) {
      notifyError(e);
    }
  }

  Future<void> remove(Member m) async {
    final ok = await confirmAction(
      title: 'Remove member',
      message: 'Remove ${m.email} from this organization? They lose access immediately.',
      confirmLabel: 'Remove',
      destructive: true,
    );
    if (!ok) return;
    try {
      await api.delete('/organizations/$orgId/members/${m.id}');
      notifySuccess('Member removed');
      await load();
    } on ApiException catch (e) {
      notifyError(e);
    }
  }

  Future<void> revokeInvite(Json inv) async {
    try {
      await api.delete('/organizations/$orgId/invitations/${inv['id']}');
      notifySuccess('Invitation revoked');
      await load();
    } on ApiException catch (e) {
      notifyError(e);
    }
  }
}

/// Role + app-scope editor used for invitations and membership edits.
Future<(String, List<String>)?> _roleDialog({
  required String title,
  required List<AppInfo> apps,
  String role = 'support_agent',
  List<String> appIds = const [],
  bool withEmail = false,
  bool allowOwner = true,
  void Function(String email)? onEmail,
}) {
  final email = TextEditingController();
  final formKey = GlobalKey<FormState>();
  var selectedRole = role;
  final selectedApps = {...appIds};
  return Get.dialog<(String, List<String>)>(
    StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 460,
          child: Form(
            key: formKey,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (withEmail) ...[
                    TextFormField(
                      controller: email,
                      autofocus: true,
                      decoration: const InputDecoration(labelText: 'Email'),
                      validator: (v) => (v == null || !v.contains('@')) ? 'Enter a valid email' : null,
                    ),
                    const SizedBox(height: 16),
                  ],
                  DropdownButtonFormField<String>(
                    initialValue: selectedRole,
                    decoration: const InputDecoration(labelText: 'Role'),
                    items: [
                      if (allowOwner) const DropdownMenuItem(value: 'owner', child: Text('Organization Owner')),
                      const DropdownMenuItem(value: 'app_admin', child: Text('App Admin')),
                      const DropdownMenuItem(value: 'support_agent', child: Text('Support Agent')),
                    ],
                    onChanged: (v) => setState(() => selectedRole = v ?? selectedRole),
                  ),
                  if (selectedRole != 'owner') ...[
                    const SizedBox(height: 16),
                    const Text('App access'),
                    Text(
                      'Leave all unchecked to grant access to every app in the organization.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    for (final a in apps)
                      CheckboxListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        value: selectedApps.contains(a.id),
                        title: Text(a.name),
                        onChanged: (v) => setState(() => v == true ? selectedApps.add(a.id) : selectedApps.remove(a.id)),
                      ),
                  ],
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
              onEmail?.call(email.text.trim());
              Get.back(result: (selectedRole, selectedRole == 'owner' ? <String>[] : selectedApps.toList()));
            },
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  );
}

class MembersView extends StatelessWidget {
  const MembersView({super.key});

  @override
  Widget build(BuildContext context) {
    final c = Get.put(MembersController(Get.find(), Get.find(), Get.find()));
    final appNames = {for (final a in c.workspace.apps) a.id: a.name};
    return AppShell(
      title: 'Members & roles',
      actions: [
        if (c.canManage)
          FilledButton.icon(
            icon: const Icon(Icons.person_add_alt),
            label: const Text('Invite member'),
            onPressed: () async {
              var email = '';
              final result = await _roleDialog(title: 'Invite member', apps: c.workspace.apps, withEmail: true, onEmail: (e) => email = e);
              if (result != null) await c.invite(email, result.$1, result.$2);
            },
          ),
      ],
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Obx(
            () => DataTableCard<Member>(
              loading: c.loading.value,
              error: c.error.value,
              onRetry: c.load,
              rows: c.items.toList(),
              searchHint: 'Search by name or email',
              onSearch: c.setSearch,
              filters: [
                FilterDropdown(
                  label: 'Role',
                  value: c.filters['role'],
                  options: const {'owner': 'Owner', 'app_admin': 'App Admin', 'support_agent': 'Support Agent'},
                  onChanged: (v) => c.setFilter('role', v),
                ),
              ],
              page: c.page.value,
              totalPages: c.totalPages.value,
              total: c.total.value,
              onPage: c.goToPage,
              columns: [
                TableColumn(
                  'Member',
                  (m) => Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(m.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                      Text(m.email, style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                ),
                TableColumn('Role', (m) => Text(roleLabel(m.role))),
                TableColumn(
                  'App access',
                  (m) => Text(m.role == 'owner' || m.appIds.isEmpty ? 'All apps' : m.appIds.map((id) => appNames[id] ?? id).join(', ')),
                ),
                TableColumn('Last sign-in', (m) => Text(timeAgo(m.lastLoginAt))),
                TableColumn(
                  '',
                  (m) => !c.canManage
                      ? const SizedBox.shrink()
                      : Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: 'Change role',
                              icon: const Icon(Icons.manage_accounts_outlined),
                              onPressed: () async {
                                final r = await _roleDialog(
                                  title: 'Edit ${m.email}',
                                  apps: c.workspace.apps,
                                  role: m.role,
                                  appIds: m.appIds,
                                );
                                if (r != null) await c.updateMember(m, r.$1, r.$2);
                              },
                            ),
                            IconButton(tooltip: 'Remove', icon: const Icon(Icons.person_remove_outlined), onPressed: () => c.remove(m)),
                          ],
                        ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          SectionCard(
            title: 'Pending invitations',
            child: Obx(
              () => c.invitations.isEmpty
                  ? const EmptyState(title: 'No pending invitations', icon: Icons.mail_outline)
                  : Column(
                      children: [
                        for (final inv in c.invitations)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text('${inv['email']}'),
                            subtitle: Text('${roleLabel('${inv['role']}')} · expires ${formatDate(parseDate(inv['expiresAt']))}'),
                            trailing: c.canManage ? TextButton(onPressed: () => c.revokeInvite(inv), child: const Text('Revoke')) : null,
                          ),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
