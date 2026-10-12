import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/api_client.dart';
import '../api/api_exception.dart';
import '../models/models.dart';

enum AuthStatus { unknown, authenticated, unauthenticated }

/// Holds the signed-in admin, their organizations and the selected organization.
class SessionService extends GetxService {
  SessionService(this.api, {this._prefs});

  final ApiClient api;
  final SharedPreferencesAsync? _prefs;

  static const _orgKey = 'amp.currentOrgId';

  final status = AuthStatus.unknown.obs;
  final admin = Rxn<Admin>();
  final organizations = <OrgAccess>[].obs;
  final currentOrg = Rxn<OrgAccess>();

  bool get isAuthenticated => status.value == AuthStatus.authenticated;
  bool get isSuperAdmin => admin.value?.isSuperAdmin ?? false;

  bool can(String permission) => isSuperAdmin || (currentOrg.value?.can(permission) ?? false);

  Future<void> _applyProfile(Json data) async {
    api.csrfToken = data['csrfToken'] as String? ?? api.csrfToken;
    admin.value = Admin.fromJson(asJson(data['admin']));
    organizations.assignAll((data['organizations'] as List? ?? const []).map((o) => OrgAccess.fromJson(asJson(o))));
    final saved = await _readSavedOrg();
    final keep = currentOrg.value?.id ?? saved;
    currentOrg.value = organizations.firstWhereOrNull((o) => o.id == keep) ?? organizations.firstOrNull;
    status.value = AuthStatus.authenticated;
  }

  Future<String?> _readSavedOrg() async {
    try {
      return await _prefs?.getString(_orgKey);
    } catch (_) {
      return null;
    }
  }

  /// Restores an existing browser session, if any. Never throws.
  Future<void> bootstrap() async {
    try {
      final data = await api.get('/auth/me');
      await _applyProfile(asJson(data));
    } on ApiException {
      _clear();
    }
  }

  Future<void> login(String email, String password) async {
    final data = await api.post('/auth/login', body: {'email': email, 'password': password}, allowRefresh: false);
    await _applyProfile(asJson(data));
  }

  Future<void> reloadProfile() async {
    final data = await api.get('/auth/me');
    await _applyProfile(asJson(data));
  }

  Future<void> logout() async {
    try {
      await api.post('/auth/logout', allowRefresh: false);
    } on ApiException {
      // Cookies are cleared server-side when possible; local state is reset regardless.
    }
    _clear();
  }

  void handleSessionExpired() => _clear();

  void _clear() {
    api.csrfToken = null;
    admin.value = null;
    organizations.clear();
    currentOrg.value = null;
    status.value = AuthStatus.unauthenticated;
  }

  Future<void> selectOrg(String orgId) async {
    final org = organizations.firstWhereOrNull((o) => o.id == orgId);
    if (org == null) return;
    currentOrg.value = org;
    try {
      await _prefs?.setString(_orgKey, orgId);
    } catch (_) {}
  }
}
