typedef Json = Map<String, dynamic>;

DateTime? parseDate(Object? v) => v is String ? DateTime.tryParse(v)?.toLocal() : null;
List<String> stringList(Object? v) => v is List ? v.map((e) => '$e').toList() : const [];
Json asJson(Object? v) => v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
int asInt(Object? v, [int fallback = 0]) => v is num ? v.toInt() : fallback;

class Admin {
  const Admin({required this.id, required this.email, required this.name, required this.isSuperAdmin, this.lastLoginAt});

  final String id;
  final String email;
  final String name;
  final bool isSuperAdmin;
  final DateTime? lastLoginAt;

  factory Admin.fromJson(Json j) => Admin(
    id: '${j['id']}',
    email: '${j['email']}',
    name: '${j['name']}',
    isSuperAdmin: j['isSuperAdmin'] == true,
    lastLoginAt: parseDate(j['lastLoginAt']),
  );
}

/// The signed-in admin's access to one organization.
class OrgAccess {
  const OrgAccess({
    required this.id,
    required this.name,
    required this.slug,
    required this.role,
    required this.permissions,
    this.appIds = const [],
  });

  final String id;
  final String name;
  final String slug;
  final String role;
  final Set<String> permissions;
  final List<String> appIds;

  bool can(String permission) => permissions.contains(permission);

  factory OrgAccess.fromJson(Json j) => OrgAccess(
    id: '${j['id']}',
    name: '${j['name']}',
    slug: '${j['slug']}',
    role: '${j['role']}',
    permissions: stringList(j['permissions']).toSet(),
    appIds: stringList(j['appIds']),
  );
}

class AppInfo {
  const AppInfo({
    required this.id,
    required this.orgId,
    required this.name,
    required this.slug,
    required this.appKey,
    required this.platforms,
    required this.environment,
    required this.status,
    this.description = '',
    this.androidPackageId,
    this.iosBundleId,
    this.iconUrl,
    this.publishedConfigVersion,
    this.createdAt,
    this.updatedAt,
    this.summary = const {},
    this.permissions = const {},
  });

  final String id;
  final String orgId;
  final String name;
  final String slug;
  final String appKey;
  final List<String> platforms;
  final String environment;
  final String status;
  final String description;
  final String? androidPackageId;
  final String? iosBundleId;
  final String? iconUrl;
  final int? publishedConfigVersion;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final Json summary;

  /// Present on the detail endpoint: the caller's permissions for this app.
  final Set<String> permissions;

  factory AppInfo.fromJson(Json j) => AppInfo(
    id: '${j['id']}',
    orgId: '${j['orgId']}',
    name: '${j['name']}',
    slug: '${j['slug']}',
    appKey: '${j['appKey']}',
    platforms: stringList(j['platforms']),
    environment: '${j['environment']}',
    status: '${j['status']}',
    description: (j['description'] as String?) ?? '',
    androidPackageId: j['androidPackageId'] as String?,
    iosBundleId: j['iosBundleId'] as String?,
    iconUrl: j['iconUrl'] as String?,
    publishedConfigVersion: (j['publishedConfigVersion'] as num?)?.toInt(),
    createdAt: parseDate(j['createdAt']),
    updatedAt: parseDate(j['updatedAt']),
    summary: asJson(j['summary']),
    permissions: stringList(asJson(j['access'])['permissions']).toSet(),
  );
}

class Member {
  const Member({
    required this.id,
    required this.adminId,
    required this.email,
    required this.name,
    required this.role,
    required this.appIds,
    this.lastLoginAt,
    this.createdAt,
  });

  final String id;
  final String adminId;
  final String email;
  final String name;
  final String role;
  final List<String> appIds;
  final DateTime? lastLoginAt;
  final DateTime? createdAt;

  factory Member.fromJson(Json j) => Member(
    id: '${j['id']}',
    adminId: '${j['adminId']}',
    email: '${j['email'] ?? ''}',
    name: '${j['name'] ?? ''}',
    role: '${j['role']}',
    appIds: stringList(j['appIds']),
    lastLoginAt: parseDate(j['lastLoginAt']),
    createdAt: parseDate(j['createdAt']),
  );
}

const roleLabels = {
  'super_admin': 'Super Admin',
  'owner': 'Organization Owner',
  'app_admin': 'App Admin',
  'support_agent': 'Support Agent',
};

String roleLabel(String role) => roleLabels[role] ?? role;
