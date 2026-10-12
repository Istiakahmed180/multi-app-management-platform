import type { Request, Response } from 'express';
import { z } from 'zod';
import { toObjectId } from '../../shared/db.js';
import { notFound } from '../../shared/errors.js';
import { objectIdString, ok, parse, requireAppId, requireAuth } from '../../shared/http.js';
import { AnalyticsService } from './analytics.service.js';
import { OverviewService } from './overview.service.js';

const analyticsQuery = z.object({ days: z.coerce.number().int().min(1).max(365).default(30) });
const overviewQuery = z.object({ orgId: objectIdString.optional() });

export function analyticsController() {
  const analytics = new AnalyticsService();
  const overview = new OverviewService();
  return {
    async app(req: Request, res: Response) {
      const { days } = parse(analyticsQuery, req.query);
      ok(res, await analytics.forApp(requireAppId(req), days));
    },
    async overview(req: Request, res: Response) {
      const { orgId } = parse(overviewQuery, req.query);
      const data = await overview.build(requireAuth(req), orgId ? toObjectId(orgId) : undefined);
      if (!data) throw notFound('Organization');
      ok(res, data);
    },
  };
}
