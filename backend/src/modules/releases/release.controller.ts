import type { Request, Response } from 'express';
import type { Deps } from '../../deps.js';
import { forbidden, notFound } from '../../shared/errors.js';
import { created, ok, parse, requireAppId, requireAuth, requireTenant } from '../../shared/http.js';
import { audit } from '../audit-logs/audit.service.js';
import { createReleaseBody, listReleasesQuery, releaseIdParam, updateReleaseBody } from './release.schemas.js';
import { ReleaseService } from './release.service.js';

function releaseId(req: Request): string {
  const r = releaseIdParam.safeParse(req.params.releaseId);
  if (!r.success) throw notFound('Release');
  return r.data;
}

export function releaseController(_deps: Deps) {
  const service = new ReleaseService();

  return {
    async list(req: Request, res: Response) {
      const { items, meta } = await service.list(requireAppId(req), parse(listReleasesQuery, req.query));
      ok(res, items, meta);
    },

    async summary(req: Request, res: Response) {
      ok(res, await service.summary(requireAppId(req)));
    },

    async create(req: Request, res: Response) {
      const body = parse(createReleaseBody, req.body);
      const appId = requireAppId(req);
      const tenant = requireTenant(req);
      const r = await service.create(appId, tenant.orgId, requireAuth(req).adminId, body);
      await audit(req, {
        action: 'release.created',
        orgId: tenant.orgId,
        appId,
        targetType: 'release',
        targetId: r._id,
        metadata: { platform: r.platform, version: r.version, status: r.status },
      });
      created(res, r.toJSON());
    },

    async update(req: Request, res: Response) {
      const body = parse(updateReleaseBody, req.body);
      const appId = requireAppId(req);
      const { release, previousStatus } = await service.update(appId, releaseId(req), requireAuth(req).adminId, body);
      await audit(req, {
        action: 'release.updated',
        orgId: requireTenant(req).orgId,
        appId,
        targetType: 'release',
        targetId: release._id,
        metadata: { ...body, previousStatus },
      });
      ok(res, release.toJSON());
    },

    async applyToDraft(req: Request, res: Response) {
      const tenant = requireTenant(req);
      if (!tenant.permissions.has('config:write')) throw forbidden();
      const appId = requireAppId(req);
      const id = releaseId(req);
      const policy = await service.applyToDraft(appId, id, requireAuth(req).adminId);
      await audit(req, {
        action: 'release.applied_to_draft',
        orgId: tenant.orgId,
        appId,
        targetType: 'release',
        targetId: id,
        metadata: { updatePolicy: policy },
      });
      ok(res, { draftUpdatePolicy: policy });
    },
  };
}
