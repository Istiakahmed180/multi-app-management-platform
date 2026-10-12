/// Build-time configuration, supplied with `--dart-define`.
///
/// `API_BASE_URL` defaults to same-origin (`/api/v1`), which is the recommended
/// production setup where nginx serves the dashboard and proxies `/api`.
class Env {
  static const apiBaseUrl = String.fromEnvironment('API_BASE_URL', defaultValue: '/api/v1');
  static const appName = String.fromEnvironment('APP_NAME', defaultValue: 'App Management Platform');
}
