import type { Request, Response } from 'express';
import { AppError } from '../../shared/errors.js';
import { ok, parse } from '../../shared/http.js';
import { recordAudit } from '../audit-logs/audit.service.js';
import { eventsBody, externalUserIdParam, upsertUserBody } from './ingest.schemas.js';
import { IngestService } from './ingest.service.js';

function ctx(res: Response) {
  const c = res.locals.ingest;
  if (!c) throw new AppError('internal_error', 'Ingest context missing');
  return c;
}

export function ingestController() {
  const service = new IngestService();

  return {
    async upsertUser(req: Request, res: Response) {
      const { appId, orgId } = ctx(res);
      const externalUserId = parse(externalUserIdParam, req.params.externalUserId);
      const body = parse(upsertUserBody, req.body);
      const { user, created } = await service.upsertUser(appId, orgId, externalUserId, body);
      res.status(created ? 201 : 200).json({ data: user.toJSON() });
    },

    async status(req: Request, res: Response) {
      const { appId } = ctx(res);
      ok(res, await service.status(appId, parse(externalUserIdParam, req.params.externalUserId)));
    },

    async deleteUser(req: Request, res: Response) {
      const { appId, orgId, keyId } = ctx(res);
      const externalUserId = parse(externalUserIdParam, req.params.externalUserId);
      const result = await service.deleteUser(appId, externalUserId);
      await recordAudit(
        { action: 'app_user.deleted', orgId, appId, targetType: 'app_user', targetId: externalUserId, metadata: result },
        { actorType: 'api_key', actorId: keyId },
        req,
      );
      ok(res, { deleted: true, ...result });
    },

    async events(req: Request, res: Response) {
      const { appId, orgId } = ctx(res);
      const body = parse(eventsBody, req.body);
      ok(res, await service.ingestEvents(appId, orgId, body.events));
    },
  };
}
