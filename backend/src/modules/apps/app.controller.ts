import type { Request, Response } from 'express';
import type { Deps } from '../../deps.js';
import { created, ok, parse, requireAppId, requireAuth, requireTenant } from '../../shared/http.js';
import { audit } from '../audit-logs/audit.service.js';
import { createAppBody, listAppsQuery, presignBody, updateAppBody, updateStatusBody } from './app.schemas.js';
import { AppService } from './app.service.js';

export function appController(deps: Deps) {
  const service = new AppService();

  return {
    async list(req: Request, res: Response) {
      const { items, meta } = await service.list(requireAuth(req), parse(listAppsQuery, req.query));
      ok(res, items, meta);
    },

    async create(req: Request, res: Response) {
      const body = parse(createAppBody, req.body);
      const app = await service.create(requireAuth(req), body);
      await audit(req, {
        action: 'app.created',
        orgId: app.orgId,
        appId: app._id,
        targetType: 'app',
        targetId: app._id,
        metadata: { name: app.name, slug: app.slug, platforms: app.platforms },
      });
      created(res, app.toJSON());
    },

    async get(req: Request, res: Response) {
      const tenant = requireTenant(req);
      const data = await service.get(requireAppId(req));
      ok(res, { ...data, access: { role: tenant.role, permissions: [...tenant.permissions] } });
    },

    async update(req: Request, res: Response) {
      const body = parse(updateAppBody, req.body);
      const appId = requireAppId(req);
      const { app, before } = await service.update(appId, body);
      const changed = Object.fromEntries(
        Object.keys(body).map((k) => [k, { from: (before as Record<string, unknown>)[k], to: app.get(k) }]),
      );
      await audit(req, {
        action: 'app.updated',
        orgId: app.orgId,
        appId,
        targetType: 'app',
        targetId: appId,
        metadata: { changed },
      });
      ok(res, app.toJSON());
    },

    async setStatus(req: Request, res: Response) {
      const body = parse(updateStatusBody, req.body);
      const appId = requireAppId(req);
      const { app, previous } = await service.setStatus(appId, body.status);
      deps.publicConfigCache.invalidate(app.appKey);
      await audit(req, {
        action: 'app.status_changed',
        orgId: app.orgId,
        appId,
        targetType: 'app',
        targetId: appId,
        metadata: { from: previous, to: body.status, reason: body.reason ?? null },
      });
      ok(res, app.toJSON());
    },

    async presignUpload(req: Request, res: Response) {
      const body = parse(presignBody, req.body);
      const appId = requireAppId(req);
      const tenant = requireTenant(req);
      const upload = await deps.storage.presignUpload({
        prefix: `orgs/${tenant.orgId}/apps/${appId}/${body.purpose}`,
        fileName: body.fileName,
        contentType: body.contentType,
        contentLength: body.contentLength,
      });
      await audit(req, {
        action: 'asset.upload_presigned',
        orgId: tenant.orgId,
        appId,
        targetType: 'asset',
        targetId: upload.key,
        metadata: { purpose: body.purpose, contentType: body.contentType },
      });
      ok(res, upload);
    },
  };
}
