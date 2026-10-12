import 'dart:math';

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

String newIdempotencyKey() {
  final r = Random.secure();
  return 'dash-${DateTime.now().millisecondsSinceEpoch}-${List.generate(12, (_) => r.nextInt(36).toRadixString(36)).join()}';
}

class CampaignsController extends PagedController<Json> with AppScope {
  CampaignsController(this.api, this.session);
  final ApiClient api;
  final SessionService session;

  bool get canWrite => session.can('campaigns:write');

  @override
  Future<Paged<Json>> fetch(Map<String, dynamic> query) => api.getPaged('/apps/$appId/campaigns', (j) => j, query: query);

  Future<void> create() async {
    final result = await Get.dialog<Json>(_CampaignDialog(api: api, appId: appId));
    if (result == null) return;
    final key = result.remove('_idempotencyKey') as String;
    try {
      final c = asJson(await api.post('/apps/$appId/campaigns', body: result, headers: {'Idempotency-Key': key}));
      notifySuccess(c['status'] == 'scheduled' ? 'Campaign scheduled' : 'Draft saved');
      await load();
    } on ApiException catch (e) {
      notifyError(e);
    }
  }

  Future<void> schedule(Json c) async {
    final when = await _pickSchedule();
    if (when == null) return;
    try {
      await api.post(
        '/apps/$appId/campaigns/${c['id']}/schedule',
        body: {if (when.isAfter(DateTime.now())) 'scheduledAt': when.toUtc().toIso8601String()},
      );
      notifySuccess('Campaign scheduled');
      await load();
    } on ApiException catch (e) {
      notifyError(e);
    }
  }

  Future<void> cancel(Json c) async {
    final ok = await confirmAction(
      title: 'Cancel "${c['name']}"?',
      message: 'The campaign will not be sent. This cannot be undone.',
      confirmLabel: 'Cancel campaign',
      destructive: true,
    );
    if (!ok) return;
    try {
      await api.post('/apps/$appId/campaigns/${c['id']}/cancel');
      notifySuccess('Campaign cancelled');
      await load();
    } on ApiException catch (e) {
      notifyError(e);
    }
  }

  void details(Json c) {
    final stats = asJson(c['stats']);
    final errors = asJson(c['errorSummary']);
    final audience = asJson(c['audience']);
    Get.dialog<void>(
      AlertDialog(
        title: Text('${c['name']}'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                InfoRow(
                  'Status',
                  null,
                  child: Align(alignment: Alignment.centerLeft, child: StatusChip('${c['status']}')),
                ),
                InfoRow('Title', '${c['title']}'),
                InfoRow('Body', '${c['body']}'),
                if (c['imageUrl'] != null) InfoRow('Image', '${c['imageUrl']}'),
                InfoRow('Audience', _audienceLabel(audience)),
                InfoRow('Scheduled', formatDateTime(parseDate(c['scheduledAt']))),
                InfoRow('Completed', formatDateTime(parseDate(c['completedAt']))),
                InfoRow('Targeted users', formatNumber(asInt(stats['targeted']))),
                InfoRow('Delivered to FCM', formatNumber(asInt(stats['sent']))),
                InfoRow('Failed', formatNumber(asInt(stats['failed']))),
                InfoRow('Invalid tokens removed', formatNumber(asInt(stats['invalidTokens']))),
                if (errors.isNotEmpty) InfoRow('Errors', errors.entries.map((e) => '${e.key}: ${e.value}').join('\n')),
                if (c['lastError'] != null) InfoRow('Last error', '${c['lastError']}'),
                const SizedBox(height: 8),
                Text(
                  '"Delivered" means accepted by Firebase Cloud Messaging; device-level receipt is not reported by FCM.',
                  style: Get.theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
        actions: [TextButton(onPressed: Get.back, child: const Text('Close'))],
      ),
    );
  }
}

String _audienceLabel(Json a) => switch (a['type']) {
  'all' => 'All eligible users',
  'platform' => 'Platform: ${stringList(a['platforms']).join(', ')}',
  'active_recently' => 'Active in the last ${a['activeWithinDays']} days',
  'users' => '${stringList(a['externalUserIds']).length} specific users',
  _ => '${a['type']}',
};

Future<DateTime?> _pickSchedule() async {
  final context = Get.context!;
  final now = DateTime.now();
  final choice = await Get.dialog<String>(
    SimpleDialog(
      title: const Text('When should it be sent?'),
      children: [
        SimpleDialogOption(
          onPressed: () => Get.back(result: 'now'),
          child: const Text('Send now'),
        ),
        SimpleDialogOption(
          onPressed: () => Get.back(result: 'later'),
          child: const Text('Schedule for later…'),
        ),
      ],
    ),
  );
  if (choice == 'now') return now;
  if (choice != 'later' || !context.mounted) return null;
  final date = await showDatePicker(context: context, firstDate: now, lastDate: now.add(const Duration(days: 365)), initialDate: now);
  if (date == null || !context.mounted) return null;
  final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(now.add(const Duration(hours: 1))));
  if (time == null) return null;
  return DateTime(date.year, date.month, date.day, time.hour, time.minute);
}

class _CampaignDialog extends StatefulWidget {
  const _CampaignDialog({required this.api, required this.appId});
  final ApiClient api;
  final String appId;

  @override
  State<_CampaignDialog> createState() => _CampaignDialogState();
}

class _CampaignDialogState extends State<_CampaignDialog> {
  final formKey = GlobalKey<FormState>();
  final idempotencyKey = newIdempotencyKey();
  final name = TextEditingController();
  final title = TextEditingController();
  final body = TextEditingController();
  final imageUrl = TextEditingController();
  final data = TextEditingController();
  final userIds = TextEditingController();
  String audience = 'all';
  final platforms = <String>{'android', 'ios'};
  int activeDays = 7;
  String? estimate;

  Json _audience() => switch (audience) {
    'platform' => {'type': 'platform', 'platforms': platforms.toList()},
    'active_recently' => {'type': 'active_recently', 'activeWithinDays': activeDays},
    'users' => {'type': 'users', 'externalUserIds': userIds.text.split(RegExp(r'[\s,]+')).where((s) => s.isNotEmpty).toList()},
    _ => {'type': 'all'},
  };

  Map<String, String>? _data() {
    final out = <String, String>{};
    for (final line in data.text.split('\n')) {
      if (line.trim().isEmpty) continue;
      final i = line.indexOf('=');
      if (i <= 0) return null;
      out[line.substring(0, i).trim()] = line.substring(i + 1).trim();
    }
    return out;
  }

  Future<void> _estimate() async {
    try {
      final res = asJson(await widget.api.post('/apps/${widget.appId}/campaigns/audience-estimate', body: {'audience': _audience()}));
      setState(
        () => estimate =
            '${formatNumber(asInt(res['eligibleUsers']))} eligible of ${formatNumber(asInt(res['totalUsers']))} registered users',
      );
    } on ApiException catch (e) {
      setState(() => estimate = e.message);
    }
  }

  Future<void> _submit({required bool scheduleIt}) async {
    if (!formKey.currentState!.validate()) return;
    DateTime? when;
    if (scheduleIt) {
      when = await _pickSchedule();
      if (when == null) return;
    }
    Get.back(
      result: <String, dynamic>{
        '_idempotencyKey': idempotencyKey,
        'name': name.text.trim(),
        'title': title.text.trim(),
        'body': body.text.trim(),
        'imageUrl': imageUrl.text.trim().isEmpty ? null : imageUrl.text.trim(),
        'data': _data() ?? {},
        'audience': _audience(),
        if (when != null) 'scheduledAt': (when.isAfter(DateTime.now()) ? when : DateTime.now()).toUtc().toIso8601String(),
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New notification campaign'),
      content: SizedBox(
        width: 560,
        child: Form(
          key: formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  controller: name,
                  decoration: const InputDecoration(labelText: 'Internal name *'),
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: title,
                  maxLength: 120,
                  decoration: const InputDecoration(labelText: 'Notification title *'),
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
                ),
                TextFormField(
                  controller: body,
                  maxLength: 1000,
                  maxLines: 3,
                  decoration: const InputDecoration(labelText: 'Body *'),
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
                ),
                TextFormField(
                  controller: imageUrl,
                  decoration: const InputDecoration(labelText: 'Image URL (https, optional)'),
                  validator: (v) => (v == null || v.isEmpty || v.startsWith('https://')) ? null : 'Must be https',
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: data,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'Data payload (optional)',
                    hintText: 'deeplink=/sale\npromo=SPRING',
                    helperText: 'One key=value per line',
                  ),
                  validator: (_) => _data() == null ? 'Use key=value lines' : null,
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  initialValue: audience,
                  decoration: const InputDecoration(labelText: 'Audience'),
                  items: const [
                    DropdownMenuItem(value: 'all', child: Text('All eligible users')),
                    DropdownMenuItem(value: 'platform', child: Text('By platform')),
                    DropdownMenuItem(value: 'active_recently', child: Text('Recently active users')),
                    DropdownMenuItem(value: 'users', child: Text('Specific user ids')),
                  ],
                  onChanged: (v) => setState(() {
                    audience = v ?? 'all';
                    estimate = null;
                  }),
                ),
                if (audience == 'platform')
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
                if (audience == 'active_recently')
                  Row(
                    children: [
                      const Text('Active within'),
                      const SizedBox(width: 12),
                      DropdownButton<int>(
                        value: activeDays,
                        items: [
                          for (final d in [1, 7, 14, 30, 90]) DropdownMenuItem(value: d, child: Text('$d days')),
                        ],
                        onChanged: (v) => setState(() => activeDays = v ?? 7),
                      ),
                    ],
                  ),
                if (audience == 'users')
                  TextFormField(
                    controller: userIds,
                    maxLines: 3,
                    decoration: const InputDecoration(labelText: 'External user ids', helperText: 'Comma or newline separated'),
                    validator: (v) => (v == null || v.trim().isEmpty) ? 'Add at least one id' : null,
                  ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    TextButton.icon(onPressed: _estimate, icon: const Icon(Icons.people_outline), label: const Text('Estimate audience')),
                    if (estimate != null) Expanded(child: Text(estimate!, style: Theme.of(context).textTheme.bodySmall)),
                  ],
                ),
                Text(
                  'Only active users who opted in and have a device token receive pushes.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: Get.back, child: const Text('Cancel')),
        OutlinedButton(onPressed: () => _submit(scheduleIt: false), child: const Text('Save draft')),
        FilledButton(onPressed: () => _submit(scheduleIt: true), child: const Text('Send / schedule…')),
      ],
    );
  }
}

class CampaignsView extends StatelessWidget {
  const CampaignsView({super.key});

  @override
  Widget build(BuildContext context) {
    final c = Get.put(CampaignsController(Get.find(), Get.find()));
    return AppShell(
      title: 'Notification campaigns',
      breadcrumbs: [const Crumb('Apps', Routes.apps), Crumb(c.appName, Routes.app(c.appId))],
      actions: [
        IconButton(tooltip: 'Refresh', onPressed: c.load, icon: const Icon(Icons.refresh)),
        if (c.canWrite) FilledButton.icon(onPressed: c.create, icon: const Icon(Icons.add), label: const Text('New campaign')),
      ],
      body: Obx(
        () => DataTableCard<Json>(
          loading: c.loading.value,
          error: c.error.value,
          onRetry: c.load,
          rows: c.items.toList(),
          onRowTap: c.details,
          searchHint: 'Search by name',
          onSearch: c.setSearch,
          filters: [
            FilterDropdown(
              label: 'Status',
              value: c.filters['status'],
              options: const {
                'draft': 'Draft',
                'scheduled': 'Scheduled',
                'sending': 'Sending',
                'sent': 'Sent',
                'partially_failed': 'Partially failed',
                'failed': 'Failed',
                'cancelled': 'Cancelled',
              },
              onChanged: (v) => c.setFilter('status', v),
            ),
          ],
          page: c.page.value,
          totalPages: c.totalPages.value,
          total: c.total.value,
          onPage: c.goToPage,
          emptyTitle: 'No campaigns yet',
          emptyMessage: 'Configure Firebase Cloud Messaging under Integrations, then create a campaign.',
          columns: [
            TableColumn(
              'Campaign',
              (x) => Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${x['name']}', style: const TextStyle(fontWeight: FontWeight.w600)),
                  Text('${x['title']}', style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
            TableColumn('Status', (x) => StatusChip('${x['status']}')),
            TableColumn('Audience', (x) => Text(_audienceLabel(asJson(x['audience'])))),
            TableColumn('Scheduled', (x) => Text(formatDateTime(parseDate(x['scheduledAt'])))),
            TableColumn('Sent / failed', (x) {
              final s = asJson(x['stats']);
              return Text('${formatNumber(asInt(s['sent']))} / ${formatNumber(asInt(s['failed']))}');
            }),
            TableColumn(
              '',
              (x) => !c.canWrite
                  ? const SizedBox.shrink()
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (x['status'] == 'draft') TextButton(onPressed: () => c.schedule(x), child: const Text('Schedule')),
                        if (x['status'] == 'draft' || x['status'] == 'scheduled')
                          TextButton(onPressed: () => c.cancel(x), child: const Text('Cancel')),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
