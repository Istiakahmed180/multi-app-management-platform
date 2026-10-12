import type { Request, Response } from 'express';
import type { Deps } from '../../deps.js';
import { isObjectId, toObjectId } from '../../shared/db.js';
import { notFound } from '../../shared/errors.js';
import { clientInfo, created, ok, parse, requireAuth, requireTenant } from '../../shared/http.js';
import { audit, recordAudit } from '../audit-logs/audit.service.js';
import { setSessionCookies } from '../auth/cookies.js';
import {
  acceptInvitationBody,
  createInvitationBody,
  createOrgBody,
  listOrgsQuery,
  memberListQuery,
  updateMemberBody,
  updateOrgBody,
} from './organization.schemas.js';
import { OrganizationService } from './organization.service.js';

function idParam(req: Request, name: string, label: string) {
  const v = req.params[name];
  if (!isObjectId(v)) throw notFound(label);
  return toObjectId(v);
}

export function organizationController(deps: Deps) {
  const service = new OrganizationService(deps.env);

  return {
    async list(req: Request, res: Response) {
      const { items, meta } = await service.list(requireAuth(req), parse(listOrgsQuery, req.query));
      ok(res, items, meta);
    },

    async create(req: Request, res: Response) {
      const body = parse(createOrgBody, req.body);
      const org = await service.create(requireAuth(req), body);
      await audit(req, {
        action: 'organization.created',
        orgId: org._id,
        targetType: 'organization',
        targetId: org._id,
        metadata: { name: org.name },
      });
      created(res, org.toJSON());
    },

    async get(req: Request, res: Response) {
      const tenant = requireTenant(req);
      ok(res, await service.get(tenant.orgId, tenant));
    },

    async update(req: Request, res: Response) {
      const tenant = requireTenant(req);
      const body = parse(updateOrgBody, req.body);
      const org = await service.rename(tenant.orgId, body.name);
      await audit(req, {
        action: 'organization.updated',
        orgId: tenant.orgId,
        targetType: 'organization',
        targetId: tenant.orgId,
        metadata: body,
      });
      ok(res, org.toJSON());
    },

    async listMembers(req: Request, res: Response) {
      const tenant = requireTenant(req);
      const { items, meta } = await service.listMembers(tenant.orgId, parse(memberListQuery, req.query));
      ok(res, items, meta);
    },

    async updateMember(req: Request, res: Response) {
      const tenant = requireTenant(req);
      const memberId = idParam(req, 'memberId', 'Member');
      const body = parse(updateMemberBody, req.body);
      const { membership, before } = await service.updateMember(tenant.orgId, memberId, body);
      await audit(req, {
        action: 'member.updated',
        orgId: tenant.orgId,
        targetType: 'membership',
        targetId: memberId,
        metadata: { before, after: { role: membership.role, appIds: membership.appIds.map(String) } },
      });
      ok(res, membership.toJSON());
    },

    async removeMember(req: Request, res: Response) {
      const tenant = requireTenant(req);
      const memberId = idParam(req, 'memberId', 'Member');
      const m = await service.removeMember(tenant.orgId, memberId);
      await audit(req, {
        action: 'member.removed',
        orgId: tenant.orgId,
        targetType: 'membership',
        targetId: memberId,
        metadata: { adminId: String(m.adminId), role: m.role },
      });
      ok(res, { removed: true });
    },

    async listInvitations(req: Request, res: Response) {
      const tenant = requireTenant(req);
      const items = await service.listInvitations(tenant.orgId);
      ok(
        res,
        items.map((i) => ({
          id: String(i._id),
          email: i.email,
          role: i.role,
          appIds: i.appIds.map(String),
          expiresAt: i.expiresAt,
          createdAt: i.createdAt,
        })),
      );
    },

    async invite(req: Request, res: Response) {
      const tenant = requireTenant(req);
      const body = parse(createInvitationBody, req.body);
      const { invitation, token, inviteUrl } = await service.invite(tenant.orgId, requireAuth(req), tenant, body);
      await audit(req, {
        action: 'member.invited',
        orgId: tenant.orgId,
        targetType: 'invitation',
        targetId: invitation._id,
        metadata: { email: body.email, role: body.role },
      });
      // No email provider is wired in; the token is returned once so the inviter can share the link.
      created(res, {
        invitation: {
          id: String(invitation._id),
          email: invitation.email,
          role: invitation.role,
          appIds: invitation.appIds.map(String),
          expiresAt: invitation.expiresAt,
        },
        inviteToken: token,
        inviteUrl,
      });
    },

    async revokeInvitation(req: Request, res: Response) {
      const tenant = requireTenant(req);
      const id = idParam(req, 'invitationId', 'Invitation');
      const inv = await service.revokeInvitation(tenant.orgId, id);
      await audit(req, {
        action: 'invitation.revoked',
        orgId: tenant.orgId,
        targetType: 'invitation',
        targetId: id,
        metadata: { email: inv.email },
      });
      ok(res, { revoked: true });
    },

    async previewInvitation(req: Request, res: Response) {
      const token = String(req.params.token ?? '');
      ok(res, await service.previewInvitation(token));
    },

    async acceptInvitation(req: Request, res: Response) {
      const body = parse(acceptInvitationBody, req.body);
      const result = await service.acceptInvitation(body, req.ctx.auth);
      await recordAudit(
        {
          action: 'invitation.accepted',
          orgId: result.orgId,
          targetType: 'admin',
          targetId: result.admin._id,
          metadata: { role: result.role, createdAccount: result.createdAccount },
        },
        { actorType: 'admin', actorId: result.admin._id, actorEmail: result.admin.email },
        req,
      );
      let csrfToken: string | undefined;
      if (result.createdAccount) {
        const tokens = await deps.auth.createSession(result.admin._id, clientInfo(req));
        csrfToken = setSessionCookies(res, deps.env, tokens);
      }
      ok(res, { orgId: String(result.orgId), role: result.role, createdAccount: result.createdAccount, csrfToken });
    },
  };
}
