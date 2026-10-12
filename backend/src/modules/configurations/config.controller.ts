import type { Request, Response } from 'express';
import type { Deps } from '../../deps.js';
import { toObjectId } from '../../shared/db.js';
import { AppError, notFound } from '../../shared/errors.js';
import { ok, parse, requireAppId, requireAuth, requireTenant } from '../../shared/http.js';
import { App } from '../apps/app.model.js';
import { audit } from '../audit-logs/audit.service.js';
import {
  appKeyParam,
  listVersionsQuery,
  publicConfigQuery,
  publishBody,
  rollbackBody,
  updateDraftBody,
  versionParam,
} from './config.schemas.js';
import { ConfigService } from './config.service.js';

function etagMatches(header: string | undefined, etag: string): boolean {
  if (!header) return false;
  return header
    .split(',')
    .map((t) => t.trim().replace(/^W\//, ''))
    .some((t) => t === etag || t === '*');
}

export function configController(deps: Deps) {
  const service = new ConfigService();

  async function invalidate(appId: import('mongoose').Types.ObjectId) {
    const app = await App.findById(appId).select('appKey').lean();
    if (app) deps.publicConfigCache.invalidate(app.appKey);
  }

  return {
    async overview(req: Request, res: Response) {
      const { data, meta } = await service.overview(requireAppId(req), parse(listVersionsQuery, req.query));
      ok(res, data, meta);
    },

    async getVersion(req: Request, res: Response) {
      const version = parse(versionParam, req.params.version);
      ok(res, await service.getVersion(requireAppId(req), version));
    },

    async saveDraft(req: Request, res: Response) {
      const body = parse(updateDraftBody, req.body);
      const appId = requireAppId(req);
      const draft = await service.saveDraft(appId, requireAuth(req).adminId, body.content, body.expectedUpdatedAt);
      await audit(req, {
        action: 'config.draft_saved',
        orgId: requireTenant(req).orgId,
        appId,
        targetType: 'config',
        targetId: 'draft',
      });
      ok(res, { content: draft.content, updatedAt: draft.updatedAt, baseVersion: draft.baseVersion });
    },

    async publish(req: Request, res: Response) {
      const body = parse(publishBody, req.body);
      const appId = requireAppId(req);
      const tenant = requireTenant(req);
      const doc = await service.publish(appId, tenant.orgId, requireAuth(req).adminId, body.changeNote);
      await invalidate(appId);
      await audit(req, {
        action: 'config.published',
        orgId: tenant.orgId,
        appId,
        targetType: 'config',
        targetId: String(doc.version),
        metadata: { version: doc.version, changeNote: body.changeNote },
      });
      ok(res, { version: doc.version, publishedAt: doc.publishedAt, changeNote: doc.changeNote });
    },

    async rollback(req: Request, res: Response) {
      const body = parse(rollbackBody, req.body);
      const appId = requireAppId(req);
      const tenant = requireTenant(req);
      const doc = await service.rollback(appId, tenant.orgId, requireAuth(req).adminId, body.version, body.changeNote);
      await invalidate(appId);
      await audit(req, {
        action: 'config.rolled_back',
        orgId: tenant.orgId,
        appId,
        targetType: 'config',
        targetId: String(doc.version),
        metadata: { toVersion: body.version, newVersion: doc.version },
      });
      ok(res, { version: doc.version, rollbackOfVersion: doc.rollbackOfVersion, publishedAt: doc.publishedAt });
    },

    /** Unauthenticated. Serves only the public projection of the latest published version. */
    async publicConfig(req: Request, res: Response) {
      const keyResult = appKeyParam.safeParse(req.params.appKey);
      if (!keyResult.success) throw notFound('App');
      const appKey = keyResult.data;
      const { platform } = parse(publicConfigQuery, req.query);
      const cacheKey = `${appKey}|${platform ?? ''}`;
      let entry = deps.publicConfigCache.get(cacheKey);
      if (!entry) {
        const built = await service.buildPublic(appKey, platform);
        if (!built) throw notFound('App');
        if (!built.payload) throw new AppError('not_found', 'No configuration has been published for this app');
        const value = { ...built.payload, appId: String(built.app._id), orgId: String(built.app.orgId) };
        deps.publicConfigCache.set(cacheKey, value);
        entry = { ...value, expiresAt: 0 };
      }
      req.ctx.metricsAppId = toObjectId(entry.appId);
      res.setHeader('ETag', entry.etag);
      res.setHeader('Cache-Control', `public, max-age=${deps.env.PUBLIC_CONFIG_CACHE_SECONDS}, must-revalidate`);
      if (etagMatches(req.get('if-none-match'), entry.etag)) {
        res.status(304).end();
        return;
      }
      res.type('application/json').send(entry.body);
    },
  };
}
