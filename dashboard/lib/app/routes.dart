abstract class Routes {
  static const login = '/login';
  static const acceptInvite = '/accept-invite';
  static const overview = '/';
  static const organizations = '/organizations';
  static const members = '/members';
  static const auditLogs = '/audit-logs';
  static const profile = '/profile';
  static const apps = '/apps';
  static const newApp = '/apps/new';

  static String app(String id) => '/apps/$id';
  static String editApp(String id) => '/apps/$id/edit';
  static String users(String id) => '/apps/$id/users';
  static String user(String appId, String userId) => '/apps/$appId/users/$userId';
  static String config(String id) => '/apps/$id/config';
  static String configHistory(String id) => '/apps/$id/config/history';
  static String features(String id) => '/apps/$id/features';
  static String campaigns(String id) => '/apps/$id/campaigns';
  static String releases(String id) => '/apps/$id/releases';
  static String analytics(String id) => '/apps/$id/analytics';
  static String integrations(String id) => '/apps/$id/integrations';
  static String appAuditLogs(String id) => '/apps/$id/audit-logs';
}
