import type { Request, Response } from 'express';
import type { Deps } from '../../deps.js';
import { notFound } from '../../shared/errors.js';
import { ok, parse, requireAppId, requireAuth, requireTenant } from '../../shared/http.js';
import { audit } from '../audit-logs/audit.service.js';
import {
  campaignIdParam,
  createCampaignBody,
  estimateBody,
  idempotencyKeyHeader,
  listCampaignsQuery,
  scheduleBody,
  updateCampaignBody,
} from './campaign.schemas.js';
import { CampaignService } from './campaign.service.js';

function campaignId(req: Request): string {
  const r = campaignIdParam.safeParse(req.params.campaignId);
  if (!r.success) throw notFound('Campaign');
  return r.data;
}

export function campaignController(_deps: Deps) {
  const service = new CampaignService();

  return {
    async list(req: Request, res: Response) {
      const { items, meta } = await service.list(requireAppId(req), parse(listCampaignsQuery, req.query));
      ok(res, items, meta);
    },

    async get(req: Request, res: Response) {
      ok(res, (await service.get(requireAppId(req), campaignId(req))).toJSON());
    },

    async create(req: Request, res: Response) {
      const body = parse(createCampaignBody, req.body);
      const rawKey = req.get('idempotency-key');
      const key = rawKey === undefined ? undefined : parse(idempotencyKeyHeader, rawKey);
      const appId = requireAppId(req);
      const tenant = requireTenant(req);
      const { campaign, replayed } = await service.create(appId, tenant.orgId, requireAuth(req).adminId, body, key);
      if (replayed) {
        res.setHeader('Idempotent-Replayed', 'true');
        ok(res, campaign.toJSON());
        return;
      }
      await audit(req, {
        action: campaign.status === 'scheduled' ? 'campaign.scheduled' : 'campaign.created',
        orgId: tenant.orgId,
        appId,
        targetType: 'campaign',
        targetId: campaign._id,
        metadata: { name: campaign.name, audience: body.audience, scheduledAt: campaign.scheduledAt },
      });
      res.status(201).json({ data: campaign.toJSON() });
    },

    async update(req: Request, res: Response) {
      const body = parse(updateCampaignBody, req.body);
      const appId = requireAppId(req);
      const c = await service.update(appId, campaignId(req), body);
      await audit(req, {
        action: 'campaign.updated',
        orgId: requireTenant(req).orgId,
        appId,
        targetType: 'campaign',
        targetId: c._id,
        metadata: { fields: Object.keys(body) },
      });
      ok(res, c.toJSON());
    },

    async schedule(req: Request, res: Response) {
      const body = parse(scheduleBody, req.body ?? {});
      const appId = requireAppId(req);
      const c = await service.schedule(appId, campaignId(req), body.scheduledAt);
      await audit(req, {
        action: 'campaign.scheduled',
        orgId: requireTenant(req).orgId,
        appId,
        targetType: 'campaign',
        targetId: c._id,
        metadata: { scheduledAt: c.scheduledAt },
      });
      ok(res, c.toJSON());
    },

    async cancel(req: Request, res: Response) {
      const appId = requireAppId(req);
      const c = await service.cancel(appId, campaignId(req), requireAuth(req).adminId);
      await audit(req, {
        action: 'campaign.cancelled',
        orgId: requireTenant(req).orgId,
        appId,
        targetType: 'campaign',
        targetId: c._id,
      });
      ok(res, c.toJSON());
    },

    async estimate(req: Request, res: Response) {
      const body = parse(estimateBody, req.body);
      ok(res, await service.estimate(requireAppId(req), body.audience));
    },
  };
}
