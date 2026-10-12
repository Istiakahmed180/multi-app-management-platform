import { Router } from 'express';
import type { Deps } from '../../deps.js';
import { optionalAuthenticate } from '../../shared/middleware/auth.js';
import { requireOrg } from '../../shared/middleware/tenancy.js';
import { organizationController } from './organization.controller.js';

/** Authenticated routes; mounted after `authenticate` + `csrfProtection`. */
export function organizationRouter(deps: Deps): Router {
  const r = Router();
  const c = organizationController(deps);
  r.get('/', c.list);
  r.post('/', c.create);
  r.get('/:orgId', requireOrg('org:read'), c.get);
  r.patch('/:orgId', requireOrg('org:manage'), c.update);
  r.get('/:orgId/members', requireOrg('members:read'), c.listMembers);
  r.patch('/:orgId/members/:memberId', requireOrg('members:manage'), c.updateMember);
  r.delete('/:orgId/members/:memberId', requireOrg('members:manage'), c.removeMember);
  r.get('/:orgId/invitations', requireOrg('members:read'), c.listInvitations);
  r.post('/:orgId/invitations', requireOrg('members:manage'), c.invite);
  r.delete('/:orgId/invitations/:invitationId', requireOrg('members:manage'), c.revokeInvitation);
  return r;
}

/** Invitation acceptance for people who may not have an account yet. */
export function invitationRouter(deps: Deps): Router {
  const r = Router();
  const c = organizationController(deps);
  r.get('/:token', c.previewInvitation);
  r.post('/accept', optionalAuthenticate(deps.auth), c.acceptInvitation);
  return r;
}
