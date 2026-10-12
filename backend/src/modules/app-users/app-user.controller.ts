import type { Request, Response } from 'express';
import type { Deps } from '../../deps.js';
import { ok, parse, requireAppId, requireAuth, requireTenant } from '../../shared/http.js';
import { audit } from '../audit-logs/audit.service.js';
import { IntegrationService } from '../integrations/integration.service.js';
import { activityQuery, listUsersQuery, updateUserStatusBody } from './app-user.schemas.js';
import { AppUserService } from './app-user.service.js';

export function appUserController(deps: Deps) {
  const service = new AppUserService(new IntegrationService(deps.env, deps.push, deps.webhooks));

  return {
    async list(req: Request, res: Response) {
      const { items, meta } = await service.list(requireAppId(req), parse(listUsersQuery, req.query));
      ok(res, items, meta);
    },

    async get(req: Request, res: Response) {
      ok(res, await service.get(requireAppId(req), String(req.params.userId)));
    },

    async activity(req: Request, res: Response) {
      const { items, meta } = await service.activity(
        requireAppId(req),
        String(req.params.userId),
        parse(activityQuery, req.query),
      );
      ok(res, items, meta);
    },

    async setStatus(req: Request, res: Response) {
      const body = parse(updateUserStatusBody, req.body);
      const appId = requireAppId(req);
      const result = await service.setStatus(
        appId,
        String(req.params.userId),
        requireAuth(req).adminId,
        body.status,
        body.reason,
      );
      await audit(req, {
        action: body.status === 'suspended' ? 'app_user.suspended' : 'app_user.reactivated',
        orgId: requireTenant(req).orgId,
        appId,
        targetType: 'app_user',
        targetId: result.user._id,
        metadata: {
          externalUserId: result.user.externalUserId,
          from: result.previous,
          reason: body.reason ?? null,
          propagated: result.propagation.delivered,
        },
      });
      ok(res, { user: result.user.toJSON(), propagation: result.propagation });
    },
  };
}
