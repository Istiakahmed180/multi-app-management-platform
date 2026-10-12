import type { RequestHandler } from 'express';
import type { Types } from 'mongoose';
import { App } from '../../modules/apps/app.model.js';
import { Membership } from '../../modules/organizations/organization.models.js';
import { Organization } from '../../modules/organizations/organization.models.js';
import { isObjectId, toObjectId } from '../db.js';
import { AppError, forbidden, notFound } from '../errors.js';
import { type AuthContext, requireAuth, type TenantContext } from '../http.js';
import { isAppScopedRole, PERMISSIONS, ROLE_PERMISSIONS, type OrgRole, type Permission } from '../rbac.js';

const ALL_PERMISSIONS: ReadonlySet<Permission> = new Set(PERMISSIONS);

/** Resolves the caller's access to an organization, or null when they have none. */
export async function resolveTenant(auth: AuthContext, orgId: Types.ObjectId): Promise<TenantContext | null> {
  if (auth.isSuperAdmin) {
    const exists = await Organization.exists({ _id: orgId });
    return exists ? { orgId, role: 'super_admin', permissions: ALL_PERMISSIONS, appIds: null } : null;
  }
  const membership = await Membership.findOne({ orgId, adminId: auth.adminId }).lean();
  if (!membership) return null;
  const role = membership.role as OrgRole;
  const scoped = isAppScopedRole(role) && membership.appIds.length > 0;
  return {
    orgId,
    role,
    permissions: ROLE_PERMISSIONS[role],
    appIds: scoped ? membership.appIds : null,
  };
}

export function canAccessApp(tenant: TenantContext, appId: Types.ObjectId): boolean {
  return tenant.appIds === null || tenant.appIds.some((id) => id.equals(appId));
}

/**
 * Org-scoped routes (`/organizations/:orgId/...`). Non-members get 404 so that
 * organization ids cannot be probed; members lacking the permission get 403.
 */
export function requireOrg(permission: Permission): RequestHandler {
  return async (req, _res, next) => {
    const auth = requireAuth(req);
    const raw = req.params.orgId;
    if (!isObjectId(raw)) throw notFound('Organization');
    const tenant = await resolveTenant(auth, toObjectId(raw));
    if (!tenant) throw notFound('Organization');
    if (!tenant.permissions.has(permission)) throw forbidden();
    req.ctx.tenant = tenant;
    next();
  };
}

/**
 * App-scoped routes (`/apps/:appId/...`). The organization is derived from the
 * stored app, never from client input. Inaccessible apps are reported as 404.
 */
export function requireApp(permission: Permission): RequestHandler {
  return async (req, _res, next) => {
    const auth = requireAuth(req);
    const raw = req.params.appId;
    if (!isObjectId(raw)) throw notFound('App');
    const app = await App.findById(raw).select('_id orgId').lean();
    if (!app) throw notFound('App');
    const tenant = await resolveTenant(auth, app.orgId);
    if (!tenant || !canAccessApp(tenant, app._id)) throw notFound('App');
    if (!tenant.permissions.has(permission)) throw forbidden();
    req.ctx.tenant = tenant;
    req.ctx.appId = app._id;
    req.ctx.metricsAppId = app._id;
    next();
  };
}

export function requireSuperAdmin(): RequestHandler {
  return (req, _res, next) => {
    if (!requireAuth(req).isSuperAdmin) throw new AppError('forbidden', 'Super admin access required');
    next();
  };
}

/** All organizations the admin can see, with their effective role. */
export async function accessibleOrgs(
  auth: AuthContext,
): Promise<{ orgId: Types.ObjectId; role: OrgRole | 'super_admin'; appIds: Types.ObjectId[] | null }[]> {
  if (auth.isSuperAdmin) {
    const orgs = await Organization.find().select('_id').lean();
    return orgs.map((o) => ({ orgId: o._id, role: 'super_admin' as const, appIds: null }));
  }
  const memberships = await Membership.find({ adminId: auth.adminId }).lean();
  return memberships.map((m) => ({
    orgId: m.orgId,
    role: m.role as OrgRole,
    appIds: isAppScopedRole(m.role as OrgRole) && m.appIds.length > 0 ? m.appIds : null,
  }));
}

/** Mongo filter matching every app the admin can access (optionally within one org). */
export async function accessibleAppFilter(auth: AuthContext, orgId?: Types.ObjectId, permission: Permission = 'apps:read') {
  const orgs = (await accessibleOrgs(auth)).filter(
    (o) => (!orgId || o.orgId.equals(orgId)) && (o.role === 'super_admin' || ROLE_PERMISSIONS[o.role].has(permission)),
  );
  if (orgs.length === 0) return null;
  return {
    $or: orgs.map((o) => (o.appIds ? { orgId: o.orgId, _id: { $in: o.appIds } } : { orgId: o.orgId })),
  };
}
