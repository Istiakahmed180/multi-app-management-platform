import type { Types } from 'mongoose';
import { notFound } from '../../shared/errors.js';
import { permissionsFor, type OrgRole } from '../../shared/rbac.js';
import { Membership, Organization } from '../organizations/organization.models.js';
import { Admin } from './auth.models.js';

/** The signed-in admin together with every organization they can access and their permissions there. */
export async function getProfile(adminId: Types.ObjectId) {
  const admin = await Admin.findById(adminId);
  if (!admin) throw notFound('Admin');
  let organizations: { id: string; name: string; slug: string; role: OrgRole | 'super_admin'; appIds: string[] }[];
  if (admin.isSuperAdmin) {
    const orgs = await Organization.find().sort({ name: 1 }).lean();
    organizations = orgs.map((o) => ({ id: String(o._id), name: o.name, slug: o.slug, role: 'super_admin', appIds: [] }));
  } else {
    const memberships = await Membership.find({ adminId }).lean();
    const orgs = await Organization.find({ _id: { $in: memberships.map((m) => m.orgId) } }).lean();
    const byId = new Map(orgs.map((o) => [String(o._id), o]));
    organizations = memberships
      .filter((m) => byId.has(String(m.orgId)))
      .map((m) => {
        const o = byId.get(String(m.orgId))!;
        return { id: String(o._id), name: o.name, slug: o.slug, role: m.role as OrgRole, appIds: m.appIds.map(String) };
      })
      .sort((a, b) => a.name.localeCompare(b.name));
  }
  return {
    admin: admin.toJSON(),
    organizations: organizations.map((o) => ({ ...o, permissions: permissionsFor(o.role) })),
  };
}
