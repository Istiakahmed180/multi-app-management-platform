import type { Request, Response } from 'express';
import type { Types } from 'mongoose';
import type { Deps } from '../../deps.js';
import { notFound } from '../../shared/errors.js';
import { created, ok, parse, requireAppId, requireAuth, requireTenant } from '../../shared/http.js';
import { App } from '../apps/app.model.js';
import { audit } from '../audit-logs/audit.service.js';
import { createFlagBody, flagKeyParam, listFlagsQuery, updateFlagBody } from './feature-flag.schemas.js';
import { FeatureFlagService } from './feature-flag.service.js';

function keyParam(req: Request): string {
  const r = flagKeyParam.safeParse(req.params.key);
  if (!r.success) throw notFound('Feature flag');
  return r.data;
}

export function featureFlagController(deps: Deps) {
  const service = new FeatureFlagService();

  // Flags are live: drop the cached public payload so clients see changes promptly.
  async function invalidate(appId: Types.ObjectId) {
    const app = await App.findById(appId).select('appKey').lean();
    if (app) deps.publicConfigCache.invalidate(app.appKey);
  }

  return {
    async list(req: Request, res: Response) {
      const flags = await service.list(requireAppId(req), parse(listFlagsQuery, req.query));
      ok(
        res,
        flags.map((f) => f.toJSON()),
      );
    },

    async create(req: Request, res: Response) {
      const body = parse(createFlagBody, req.body);
      const appId = requireAppId(req);
      const tenant = requireTenant(req);
      const flag = await service.create(appId, tenant.orgId, requireAuth(req).adminId, body);
      await invalidate(appId);
      await audit(req, {
        action: 'flag.created',
        orgId: tenant.orgId,
        appId,
        targetType: 'feature_flag',
        targetId: flag.key,
        metadata: body,
      });
      created(res, flag.toJSON());
    },

    async update(req: Request, res: Response) {
      const key = keyParam(req);
      const body = parse(updateFlagBody, req.body);
      const appId = requireAppId(req);
      const tenant = requireTenant(req);
      const { flag, before } = await service.update(appId, key, requireAuth(req).adminId, body);
      await invalidate(appId);
      const changes = Object.fromEntries(
        Object.keys(body).map((k) => [k, { from: (before as Record<string, unknown>)[k], to: flag.get(k) }]),
      );
      await audit(req, {
        action: 'flag.updated',
        orgId: tenant.orgId,
        appId,
        targetType: 'feature_flag',
        targetId: key,
        metadata: { changes },
      });
      ok(res, flag.toJSON());
    },

    async remove(req: Request, res: Response) {
      const key = keyParam(req);
      const appId = requireAppId(req);
      const tenant = requireTenant(req);
      await service.remove(appId, key);
      await invalidate(appId);
      await audit(req, { action: 'flag.deleted', orgId: tenant.orgId, appId, targetType: 'feature_flag', targetId: key });
      ok(res, { deleted: true });
    },
  };
}
