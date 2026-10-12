import type { Types } from 'mongoose';
import type { Env } from '../../config/env.js';
import { hashPassword, randomToken, sha256 } from '../../shared/crypto.js';
import { toObjectId } from '../../shared/db.js';
import { AppError, badRequest, conflict, forbidden, isDuplicateKeyError, notFound } from '../../shared/errors.js';
import type { AuthContext, TenantContext } from '../../shared/http.js';
import { accessibleOrgs } from '../../shared/middleware/tenancy.js';
import { escapeRegex, pageMeta, skip, type PaginationQuery } from '../../shared/pagination.js';
import { isAppScopedRole, permissionsFor, type OrgRole } from '../../shared/rbac.js';
import { App } from '../apps/app.model.js';
import { Admin } from '../auth/auth.models.js';
import { Invitation, Membership, Organization } from './organization.models.js';
import { slugify } from './organization.schemas.js';

export class OrganizationService {
  constructor(private readonly env: Env) {}

  async list(auth: AuthContext, q: PaginationQuery & { search?: string }) {
    const access = await accessibleOrgs(auth);
    const roleById = new Map(access.map((a) => [String(a.orgId), a.role]));
    const filter: Record<string, unknown> = { _id: { $in: access.map((a) => a.orgId) } };
    if (q.search) filter.name = { $regex: escapeRegex(q.search), $options: 'i' };
    const [items, total] = await Promise.all([
      Organization.find(filter).sort({ name: 1, _id: 1 }).skip(skip(q)).limit(q.pageSize).lean(),
      Organization.countDocuments(filter),
    ]);
    const counts = await App.aggregate<{ _id: Types.ObjectId; n: number }>([
      { $match: { orgId: { $in: items.map((o) => o._id) }, status: { $ne: 'archived' } } },
      { $group: { _id: '$orgId', n: { $sum: 1 } } },
    ]);
    const appCount = new Map(counts.map((c) => [String(c._id), c.n]));
    return {
      items: items.map((o) => {
        const role = roleById.get(String(o._id))!;
        return {
          id: String(o._id),
          name: o.name,
          slug: o.slug,
          status: o.status,
          createdAt: o.createdAt,
          role,
          permissions: permissionsFor(role),
          appCount: appCount.get(String(o._id)) ?? 0,
        };
      }),
      meta: pageMeta(q, total),
    };
  }

  async create(auth: AuthContext, input: { name: string; slug?: string }) {
    const base = input.slug ?? slugify(input.name);
    let slug = base;
    for (let attempt = 0; attempt < 5; attempt++) {
      try {
        const org = await Organization.create({ name: input.name, slug, createdBy: auth.adminId });
        await Membership.create({ orgId: org._id, adminId: auth.adminId, role: 'owner', createdBy: auth.adminId });
        return org;
      } catch (err) {
        if (!isDuplicateKeyError(err)) throw err;
        if (input.slug) throw conflict('Organization slug is already taken', { fields: ['slug'] });
        slug = `${base.slice(0, 56)}-${randomToken(3)
          .toLowerCase()
          .replace(/[^a-z0-9]/g, '')}`;
      }
    }
    throw conflict('Could not allocate a unique slug');
  }

  async get(orgId: Types.ObjectId, tenant: TenantContext) {
    const org = await Organization.findById(orgId).lean();
    if (!org) throw notFound('Organization');
    const [appCount, memberCount] = await Promise.all([
      App.countDocuments({ orgId, status: { $ne: 'archived' } }),
      Membership.countDocuments({ orgId }),
    ]);
    return {
      id: String(org._id),
      name: org.name,
      slug: org.slug,
      status: org.status,
      createdAt: org.createdAt,
      role: tenant.role,
      permissions: [...tenant.permissions],
      appCount,
      memberCount,
    };
  }

  async rename(orgId: Types.ObjectId, name: string) {
    const org = await Organization.findByIdAndUpdate(orgId, { $set: { name } }, { returnDocument: 'after', runValidators: true });
    if (!org) throw notFound('Organization');
    return org;
  }

  async listMembers(orgId: Types.ObjectId, q: PaginationQuery & { search?: string; role?: OrgRole }) {
    const filter: Record<string, unknown> = { orgId };
    if (q.role) filter.role = q.role;
    if (q.search) {
      const rx = { $regex: escapeRegex(q.search), $options: 'i' };
      const admins = await Admin.find({ $or: [{ email: rx }, { name: rx }] })
        .select('_id')
        .limit(1000)
        .lean();
      filter.adminId = { $in: admins.map((a) => a._id) };
    }
    const [items, total] = await Promise.all([
      Membership.find(filter).sort({ createdAt: -1, _id: -1 }).skip(skip(q)).limit(q.pageSize).lean(),
      Membership.countDocuments(filter),
    ]);
    const admins = await Admin.find({ _id: { $in: items.map((m) => m.adminId) } }).lean();
    const byId = new Map(admins.map((a) => [String(a._id), a]));
    return {
      items: items.map((m) => {
        const a = byId.get(String(m.adminId));
        return {
          id: String(m._id),
          adminId: String(m.adminId),
          email: a?.email ?? null,
          name: a?.name ?? null,
          status: a?.status ?? 'disabled',
          lastLoginAt: a?.lastLoginAt ?? null,
          role: m.role,
          appIds: m.appIds.map(String),
          createdAt: m.createdAt,
        };
      }),
      meta: pageMeta(q, total),
    };
  }

  private async assertAppsInOrg(orgId: Types.ObjectId, appIds: string[]) {
    if (appIds.length === 0) return [];
    const ids = [...new Set(appIds)].map(toObjectId);
    const found = await App.countDocuments({ _id: { $in: ids }, orgId });
    if (found !== ids.length) throw badRequest('appIds must reference apps in this organization');
    return ids;
  }

  private async assertNotLastOwner(orgId: Types.ObjectId, membershipId: Types.ObjectId) {
    const owners = await Membership.countDocuments({ orgId, role: 'owner', _id: { $ne: membershipId } });
    if (owners === 0) throw conflict('An organization must keep at least one owner');
  }

  async updateMember(orgId: Types.ObjectId, memberId: Types.ObjectId, input: { role?: OrgRole; appIds?: string[] }) {
    const m = await Membership.findOne({ _id: memberId, orgId });
    if (!m) throw notFound('Member');
    const nextRole = input.role ?? (m.role as OrgRole);
    if (m.role === 'owner' && nextRole !== 'owner') await this.assertNotLastOwner(orgId, m._id);
    const before = { role: m.role, appIds: m.appIds.map(String) };
    m.role = nextRole;
    if (!isAppScopedRole(nextRole)) m.set('appIds', []);
    else if (input.appIds) m.set('appIds', await this.assertAppsInOrg(orgId, input.appIds));
    await m.save();
    return { membership: m, before };
  }

  async removeMember(orgId: Types.ObjectId, memberId: Types.ObjectId) {
    const m = await Membership.findOne({ _id: memberId, orgId });
    if (!m) throw notFound('Member');
    if (m.role === 'owner') await this.assertNotLastOwner(orgId, m._id);
    await m.deleteOne();
    return m;
  }

  listInvitations(orgId: Types.ObjectId) {
    return Invitation.find({ orgId, acceptedAt: null, revokedAt: null, expiresAt: { $gt: new Date() } })
      .sort({ createdAt: -1 })
      .limit(200)
      .lean();
  }

  async invite(
    orgId: Types.ObjectId,
    auth: AuthContext,
    tenant: TenantContext,
    input: { email: string; role: OrgRole; appIds: string[] },
  ) {
    if (input.role === 'owner' && tenant.role !== 'owner' && tenant.role !== 'super_admin') throw forbidden();
    const existing = await Admin.findOne({ email: input.email }).select('_id').lean();
    if (existing && (await Membership.exists({ orgId, adminId: existing._id }))) {
      throw conflict('This person is already a member of the organization');
    }
    const appIds = isAppScopedRole(input.role) ? await this.assertAppsInOrg(orgId, input.appIds) : [];
    // Supersede any pending invitation for the same email.
    await Invitation.updateMany(
      { orgId, email: input.email, acceptedAt: null, revokedAt: null },
      { $set: { revokedAt: new Date() } },
    );
    const token = randomToken(32);
    const invitation = await Invitation.create({
      orgId,
      email: input.email,
      role: input.role,
      appIds,
      tokenHash: sha256(token),
      invitedBy: auth.adminId,
      expiresAt: new Date(Date.now() + this.env.INVITATION_TTL_DAYS * 86_400_000),
    });
    const inviteUrl = this.env.DASHBOARD_URL
      ? `${this.env.DASHBOARD_URL.replace(/\/$/, '')}/#/accept-invite?token=${token}`
      : null;
    return { invitation, token, inviteUrl };
  }

  async revokeInvitation(orgId: Types.ObjectId, invitationId: Types.ObjectId) {
    const inv = await Invitation.findOneAndUpdate(
      { _id: invitationId, orgId, acceptedAt: null, revokedAt: null },
      { $set: { revokedAt: new Date() } },
      { returnDocument: 'after' },
    );
    if (!inv) throw notFound('Invitation');
    return inv;
  }

  private async findValidInvitation(token: string) {
    const inv = await Invitation.findOne({ tokenHash: sha256(token) });
    if (!inv || inv.revokedAt || inv.acceptedAt || inv.expiresAt <= new Date()) {
      throw new AppError('not_found', 'Invitation is invalid or has expired');
    }
    return inv;
  }

  async previewInvitation(token: string) {
    const inv = await this.findValidInvitation(token);
    const org = await Organization.findById(inv.orgId).lean();
    const accountExists = Boolean(await Admin.exists({ email: inv.email }));
    return {
      email: inv.email,
      role: inv.role,
      organization: org ? { name: org.name } : null,
      accountExists,
      expiresAt: inv.expiresAt,
    };
  }

  /**
   * Existing accounts must be signed in as the invited email. New accounts are
   * created with the supplied name and password.
   */
  async acceptInvitation(input: { token: string; name?: string; password?: string }, auth?: AuthContext) {
    const inv = await this.findValidInvitation(input.token);
    let admin = await Admin.findOne({ email: inv.email });
    let createdAccount = false;
    if (admin) {
      if (!auth || !auth.adminId.equals(admin._id)) {
        throw new AppError('unauthenticated', 'Sign in as the invited email address to accept this invitation');
      }
    } else {
      if (!input.name || !input.password) {
        throw new AppError('validation_failed', 'Name and password are required to create your account', [
          ...(!input.name ? [{ path: 'name', message: 'Required' }] : []),
          ...(!input.password ? [{ path: 'password', message: 'Required' }] : []),
        ]);
      }
      admin = await Admin.create({ email: inv.email, name: input.name, passwordHash: await hashPassword(input.password) });
      createdAccount = true;
    }
    // Claim atomically so a token can only be used once.
    const claimed = await Invitation.findOneAndUpdate(
      { _id: inv._id, acceptedAt: null, revokedAt: null },
      { $set: { acceptedAt: new Date() } },
    );
    if (!claimed) throw new AppError('not_found', 'Invitation is invalid or has expired');
    try {
      await Membership.create({
        orgId: inv.orgId,
        adminId: admin._id,
        role: inv.role,
        appIds: inv.appIds,
        createdBy: inv.invitedBy,
      });
    } catch (err) {
      if (!isDuplicateKeyError(err)) throw err;
    }
    return { admin, orgId: inv.orgId, role: inv.role, createdAccount };
  }
}
