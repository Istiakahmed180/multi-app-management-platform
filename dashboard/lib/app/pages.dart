import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../core/services/session_service.dart';
import '../modules/analytics/analytics_view.dart';
import '../modules/apps/app_detail_view.dart';
import '../modules/apps/app_form_view.dart';
import '../modules/apps/apps_list_view.dart';
import '../modules/audit/audit_logs_view.dart';
import '../modules/auth/accept_invite_view.dart';
import '../modules/auth/login_view.dart';
import '../modules/campaigns/campaigns_view.dart';
import '../modules/config/config_editor_view.dart';
import '../modules/config/config_history_view.dart';
import '../modules/features/features_view.dart';
import '../modules/integrations/integrations_view.dart';
import '../modules/members/members_view.dart';
import '../modules/organizations/organizations_view.dart';
import '../modules/overview/overview_view.dart';
import '../modules/profile/profile_view.dart';
import '../modules/releases/releases_view.dart';
import '../modules/users/user_detail_view.dart';
import '../modules/users/users_view.dart';
import 'routes.dart';

/// Sends unauthenticated visitors to the login page, preserving the target route.
class AuthMiddleware extends GetMiddleware {
  @override
  RouteSettings? redirect(String? route) {
    final session = Get.find<SessionService>();
    if (session.isAuthenticated) return null;
    final target = route ?? Routes.overview;
    return RouteSettings(name: target == Routes.overview ? Routes.login : '${Routes.login}?redirect=${Uri.encodeComponent(target)}');
  }
}

/// Keeps signed-in admins away from the login page.
class GuestMiddleware extends GetMiddleware {
  @override
  RouteSettings? redirect(String? route) => Get.find<SessionService>().isAuthenticated ? const RouteSettings(name: Routes.overview) : null;
}

GetPage<dynamic> _private(String name, Widget Function() page) =>
    GetPage<dynamic>(name: name, page: page, middlewares: [AuthMiddleware()], transition: Transition.noTransition);

final appPages = <GetPage<dynamic>>[
  GetPage<dynamic>(name: Routes.login, page: () => const LoginView(), middlewares: [GuestMiddleware()]),
  GetPage<dynamic>(name: Routes.acceptInvite, page: () => const AcceptInviteView()),
  _private(Routes.overview, () => const OverviewView()),
  _private(Routes.organizations, () => const OrganizationsView()),
  _private(Routes.members, () => const MembersView()),
  _private(Routes.auditLogs, () => const AuditLogsView()),
  _private(Routes.profile, () => const ProfileView()),
  _private(Routes.apps, () => const AppsListView()),
  _private(Routes.newApp, () => const AppFormView()),
  _private('/apps/:appId', () => const AppDetailView()),
  _private('/apps/:appId/edit', () => const AppFormView()),
  _private('/apps/:appId/users', () => const UsersView()),
  _private('/apps/:appId/users/:userId', () => const UserDetailView()),
  _private('/apps/:appId/config', () => const ConfigEditorView()),
  _private('/apps/:appId/config/history', () => const ConfigHistoryView()),
  _private('/apps/:appId/features', () => const FeaturesView()),
  _private('/apps/:appId/campaigns', () => const CampaignsView()),
  _private('/apps/:appId/releases', () => const ReleasesView()),
  _private('/apps/:appId/analytics', () => const AnalyticsView()),
  _private('/apps/:appId/integrations', () => const IntegrationsView()),
  _private('/apps/:appId/audit-logs', () => const AuditLogsView()),
];
