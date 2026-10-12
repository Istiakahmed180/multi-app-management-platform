export const ORG_ROLES = ['owner', 'app_admin', 'support_agent'] as const;
export type OrgRole = (typeof ORG_ROLES)[number];

export const PERMISSIONS = [
  'org:read',
  'org:manage',
  'members:read',
  'members:manage',
  'apps:read',
  'apps:create',
  'apps:write',
  'config:read',
  'config:write',
  'config:publish',
  'flags:read',
  'flags:write',
  'users:read',
  'users:write',
  'campaigns:read',
  'campaigns:write',
  'releases:read',
  'releases:write',
  'analytics:read',
  'audit:read',
  'integrations:read',
  'integrations:write',
] as const;
export type Permission = (typeof PERMISSIONS)[number];

const OWNER: readonly Permission[] = PERMISSIONS;

const APP_ADMIN: readonly Permission[] = [
  'org:read',
  'members:read',
  'apps:read',
  'apps:write',
  'config:read',
  'config:write',
  'config:publish',
  'flags:read',
  'flags:write',
  'users:read',
  'users:write',
  'campaigns:read',
  'campaigns:write',
  'releases:read',
  'releases:write',
  'analytics:read',
  'audit:read',
  'integrations:read',
];

const SUPPORT_AGENT: readonly Permission[] = [
  'org:read',
  'apps:read',
  'config:read',
  'flags:read',
  'users:read',
  'users:write',
  'campaigns:read',
  'releases:read',
  'analytics:read',
];

export const ROLE_PERMISSIONS: Record<OrgRole, ReadonlySet<Permission>> = {
  owner: new Set(OWNER),
  app_admin: new Set(APP_ADMIN),
  support_agent: new Set(SUPPORT_AGENT),
};

export function roleHas(role: OrgRole, permission: Permission): boolean {
  return ROLE_PERMISSIONS[role].has(permission);
}

export function permissionsFor(role: OrgRole | 'super_admin'): Permission[] {
  return role === 'super_admin' ? [...PERMISSIONS] : [...ROLE_PERMISSIONS[role]];
}

/** Roles that can be restricted to a subset of the organization's apps. */
export function isAppScopedRole(role: OrgRole): boolean {
  return role !== 'owner';
}
