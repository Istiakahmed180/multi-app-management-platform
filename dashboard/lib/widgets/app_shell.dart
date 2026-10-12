import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../app/routes.dart';
import '../core/env.dart';
import '../core/models/models.dart';
import '../core/services/session_service.dart';
import '../core/services/theme_service.dart';
import '../core/services/workspace_service.dart';

class Crumb {
  const Crumb(this.label, [this.route]);
  final String label;
  final String? route;
}

class _NavItem {
  const _NavItem(this.label, this.icon, this.route, {this.permission, this.exact = false});
  final String label;
  final IconData icon;
  final String route;
  final String? permission;
  final bool exact;
}

const double kSidebarBreakpoint = 1100;

/// Persistent layout: sidebar navigation, header with breadcrumbs, org and app
/// switchers, theme toggle and profile menu. Collapses to a drawer on narrow screens.
class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.title, required this.body, this.breadcrumbs = const [], this.actions = const []});

  final String title;
  final List<Crumb> breadcrumbs;
  final List<Widget> actions;
  final Widget body;

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= kSidebarBreakpoint;
    return Scaffold(
      drawer: wide ? null : const Drawer(child: _Sidebar()),
      body: Row(
        children: [
          if (wide) const SizedBox(width: 264, child: _Sidebar()),
          Expanded(
            child: Column(
              children: [
                _Header(title: title, breadcrumbs: breadcrumbs, showMenu: !wide),
                Expanded(
                  child: SingleChildScrollView(
                    padding: EdgeInsets.all(wide ? 28 : 16),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 1400),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _PageTitle(title: title, actions: actions),
                            const SizedBox(height: 20),
                            body,
                          ],
                        ),
                      ),
                    ),
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

class _PageTitle extends StatelessWidget {
  const _PageTitle({required this.title, required this.actions});
  final String title;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 12,
      runSpacing: 12,
      children: [
        Semantics(
          header: true,
          child: Text(title, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
        ),
        if (actions.isNotEmpty) Wrap(spacing: 8, runSpacing: 8, children: actions),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.title, required this.breadcrumbs, required this.showMenu});
  final String title;
  final List<Crumb> breadcrumbs;
  final bool showMenu;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final session = Get.find<SessionService>();
    final themeService = Get.find<ThemeService>();
    return Material(
      color: theme.colorScheme.surfaceContainerLowest,
      child: Container(
        height: 64,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: theme.dividerTheme.color ?? theme.dividerColor)),
        ),
        child: Row(
          children: [
            if (showMenu)
              Builder(
                builder: (ctx) =>
                    IconButton(tooltip: 'Open navigation', icon: const Icon(Icons.menu), onPressed: () => Scaffold.of(ctx).openDrawer()),
              ),
            Expanded(child: _Breadcrumbs(crumbs: [...breadcrumbs, Crumb(title)])),
            Obx(
              () => IconButton(
                tooltip: 'Toggle theme',
                icon: Icon(switch (themeService.mode.value) {
                  ThemeMode.dark => Icons.dark_mode_outlined,
                  ThemeMode.light => Icons.light_mode_outlined,
                  ThemeMode.system => Icons.brightness_auto_outlined,
                }),
                onPressed: () => themeService.setMode(switch (themeService.mode.value) {
                  ThemeMode.system => ThemeMode.light,
                  ThemeMode.light => ThemeMode.dark,
                  ThemeMode.dark => ThemeMode.system,
                }),
              ),
            ),
            const SizedBox(width: 4),
            Obx(() {
              final admin = session.admin.value;
              return PopupMenuButton<String>(
                tooltip: 'Account menu',
                onSelected: (v) async {
                  if (v == 'profile') Get.toNamed(Routes.profile);
                  if (v == 'logout') {
                    await session.logout();
                    Get.offAllNamed(Routes.login);
                  }
                },
                itemBuilder: (_) => [
                  PopupMenuItem(
                    enabled: false,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(admin?.name ?? '', style: theme.textTheme.titleSmall),
                        Text(admin?.email ?? '', style: theme.textTheme.bodySmall),
                      ],
                    ),
                  ),
                  const PopupMenuDivider(),
                  const PopupMenuItem(
                    value: 'profile',
                    child: ListTile(leading: Icon(Icons.person_outline), title: Text('Profile & security')),
                  ),
                  const PopupMenuItem(
                    value: 'logout',
                    child: ListTile(leading: Icon(Icons.logout), title: Text('Sign out')),
                  ),
                ],
                child: CircleAvatar(
                  radius: 17,
                  backgroundColor: theme.colorScheme.primaryContainer,
                  child: Text(
                    (admin?.name.isNotEmpty ?? false) ? admin!.name[0].toUpperCase() : '?',
                    style: TextStyle(color: theme.colorScheme.onPrimaryContainer, fontWeight: FontWeight.w700),
                  ),
                ),
              );
            }),
          ],
        ),
      ),
    );
  }
}

class _Breadcrumbs extends StatelessWidget {
  const _Breadcrumbs({required this.crumbs});
  final List<Crumb> crumbs;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      label: 'Breadcrumbs',
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (var i = 0; i < crumbs.length; i++) ...[
              if (i > 0) Icon(Icons.chevron_right, size: 16, color: theme.colorScheme.outline),
              if (crumbs[i].route != null && i < crumbs.length - 1)
                TextButton(
                  style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 6), minimumSize: const Size(0, 32)),
                  onPressed: () => Get.toNamed(crumbs[i].route!),
                  child: Text(crumbs[i].label),
                )
              else
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Text(
                    crumbs[i].label,
                    style: theme.textTheme.bodyMedium?.copyWith(fontWeight: i == crumbs.length - 1 ? FontWeight.w600 : null),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar();

  static const _workspace = [
    _NavItem('Overview', Icons.space_dashboard_outlined, Routes.overview, exact: true),
    _NavItem('Apps', Icons.apps_outlined, Routes.apps, permission: 'apps:read', exact: true),
    _NavItem('Organizations', Icons.domain_outlined, Routes.organizations),
    _NavItem('Members & roles', Icons.group_outlined, Routes.members, permission: 'members:read'),
    _NavItem('Audit logs', Icons.receipt_long_outlined, Routes.auditLogs, permission: 'audit:read'),
  ];

  static List<_NavItem> _appItems(String id) => [
    _NavItem('App overview', Icons.info_outline, Routes.app(id), exact: true),
    _NavItem('Users', Icons.people_outline, Routes.users(id), permission: 'users:read'),
    _NavItem('Remote config', Icons.tune, Routes.config(id), permission: 'config:read', exact: true),
    _NavItem('Version history', Icons.history, Routes.configHistory(id), permission: 'config:read'),
    _NavItem('Feature flags', Icons.flag_outlined, Routes.features(id), permission: 'flags:read'),
    _NavItem('Notifications', Icons.campaign_outlined, Routes.campaigns(id), permission: 'campaigns:read'),
    _NavItem('Releases', Icons.rocket_launch_outlined, Routes.releases(id), permission: 'releases:read'),
    _NavItem('Analytics', Icons.insights_outlined, Routes.analytics(id), permission: 'analytics:read'),
    _NavItem('Integrations', Icons.extension_outlined, Routes.integrations(id), permission: 'integrations:read'),
    _NavItem('App audit log', Icons.fact_check_outlined, Routes.appAuditLogs(id), permission: 'audit:read'),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final session = Get.find<SessionService>();
    final workspace = Get.find<WorkspaceService>();
    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      child: SafeArea(
        child: Obx(() {
          final current = Get.currentRoute.split('?').first;
          final appId = workspace.selectedAppId.value;
          bool visible(_NavItem i) => i.permission == null || session.can(i.permission!);
          return ListView(
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
                child: Row(
                  children: [
                    Icon(Icons.hub_outlined, color: theme.colorScheme.primary),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(Env.appName, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700), maxLines: 2),
                    ),
                  ],
                ),
              ),
              const _OrgSwitcher(),
              const SizedBox(height: 8),
              for (final i in _workspace.where(visible)) _NavTile(item: i, current: current),
              const SizedBox(height: 16),
              const _SectionLabel('Application'),
              const _AppSwitcher(),
              const SizedBox(height: 4),
              if (appId != null)
                for (final i in _appItems(appId).where(visible)) _NavTile(item: i, current: current)
              else
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Text('Select an app to manage its users, config, flags and more.', style: theme.textTheme.bodySmall),
                ),
            ],
          );
        }),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Text(
        text.toUpperCase(),
        style: theme.textTheme.labelSmall?.copyWith(letterSpacing: 0.8, color: theme.colorScheme.onSurfaceVariant),
      ),
    );
  }
}

class _NavTile extends StatelessWidget {
  const _NavTile({required this.item, required this.current});
  final _NavItem item;
  final String current;

  @override
  Widget build(BuildContext context) {
    final selected = item.exact ? current == item.route : (current == item.route || current.startsWith('${item.route}/'));
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: ListTile(
        dense: true,
        selected: selected,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        selectedTileColor: Theme.of(context).colorScheme.secondaryContainer,
        leading: Icon(item.icon, size: 20),
        title: Text(item.label),
        onTap: () {
          if (Scaffold.maybeOf(context)?.isDrawerOpen ?? false) Navigator.of(context).pop();
          // Sidebar entries are top-level destinations: replace the stack so each
          // visit gets a fresh controller (and fresh data) instead of a stale one.
          if (!selected) Get.offAllNamed(item.route);
        },
      ),
    );
  }
}

class _OrgSwitcher extends StatelessWidget {
  const _OrgSwitcher();

  @override
  Widget build(BuildContext context) {
    final session = Get.find<SessionService>();
    return Obx(() {
      final orgs = session.organizations;
      final current = session.currentOrg.value;
      if (orgs.isEmpty) {
        return const ListTile(dense: true, title: Text('No organization'), subtitle: Text('Create one under Organizations'));
      }
      return DropdownButtonFormField<String>(
        initialValue: current?.id,
        isExpanded: true,
        decoration: const InputDecoration(labelText: 'Organization', prefixIcon: Icon(Icons.domain, size: 18)),
        items: [
          for (final o in orgs)
            DropdownMenuItem(
              value: o.id,
              child: Text(o.name, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: (id) {
          if (id == null || id == current?.id) return;
          session.selectOrg(id);
          Get.offAllNamed(Routes.overview);
        },
      );
    });
  }
}

class _AppSwitcher extends StatelessWidget {
  const _AppSwitcher();

  @override
  Widget build(BuildContext context) {
    final workspace = Get.find<WorkspaceService>();
    return Obx(() {
      final apps = workspace.apps;
      final selected = workspace.selectedAppId.value;
      if (workspace.loading.value && apps.isEmpty) return const LinearProgressIndicator(minHeight: 2);
      if (apps.isEmpty) {
        return const ListTile(dense: true, title: Text('No apps yet'));
      }
      return DropdownButtonFormField<String>(
        key: ValueKey('app-switcher-$selected-${apps.length}'),
        initialValue: apps.any((a) => a.id == selected) ? selected : null,
        isExpanded: true,
        decoration: const InputDecoration(labelText: 'Current app', prefixIcon: Icon(Icons.phone_iphone, size: 18)),
        items: [
          for (final AppInfo a in apps)
            DropdownMenuItem(
              value: a.id,
              child: Text(a.name, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: (id) {
          if (id == null || id == selected) return;
          // Keep the same section when switching apps (e.g. users -> users).
          final current = Get.currentRoute.split('?').first;
          final match = RegExp(r'^/apps/[^/]+(/.*)?$').firstMatch(current);
          final suffix = match?.group(1) ?? '';
          final safeSuffix = suffix.startsWith('/users/') ? '/users' : (suffix == '/edit' ? '' : suffix);
          workspace.selectApp(id);
          Get.offAllNamed('/apps/$id$safeSuffix');
        },
      );
    });
  }
}
