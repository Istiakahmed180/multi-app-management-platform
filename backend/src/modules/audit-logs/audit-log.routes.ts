import { Router, type Request, type Response } from 'express';
import type { Types } from 'mongoose';
import { z } from 'zod';
import { toObjectId } from '../../shared/db.js';
import { objectIdString, ok, parse, requireAppId, requireTenant } from '../../shared/http.js';
import { requireApp, requireOrg } from '../../shared/middleware/tenancy.js';
import { escapeRegex, pageMeta, paginationQuery, skip } from '../../shared/pagination.js';
import { AuditLog } from './audit-log.model.js';

const auditQuery = paginationQuery.extend({
  action: z.string().trim().max(64).optional(),
  actorEmail: z.string().trim().max(254).optional(),
  targetType: z.string().trim().max(64).optional(),
  from: z.iso.datetime().optional(),
  to: z.iso.datetime().optional(),
  appId: objectIdString.optional(),
});

async function query(res: Response, base: Record<string, unknown>, q: z.infer<typeof auditQuery>) {
  const filter: Record<string, unknown> = { ...base };
  // Prefix matches so "config." finds config.published, config.rolled_back, ...
  if (q.action) filter.action = { $regex: `^${escapeRegex(q.action)}` };
  if (q.actorEmail) filter.actorEmail = { $regex: `^${escapeRegex(q.actorEmail.toLowerCase())}` };
  if (q.targetType) filter.targetType = q.targetType;
  if (q.from || q.to) {
    filter.createdAt = { ...(q.from ? { $gte: new Date(q.from) } : {}), ...(q.to ? { $lte: new Date(q.to) } : {}) };
  }
  const [items, total] = await Promise.all([
    AuditLog.find(filter).sort({ createdAt: -1, _id: -1 }).skip(skip(q)).limit(q.pageSize),
    AuditLog.countDocuments(filter),
  ]);
  ok(
    res,
    items.map((i) => i.toJSON()),
    pageMeta(q, total),
  );
}

/** Mounted at /apps/:appId/audit-logs (mergeParams). */
export function appAuditLogRouter(): Router {
  const r = Router({ mergeParams: true });
  r.get('/', requireApp('audit:read'), async (req: Request, res: Response) => {
    const q = parse(auditQuery.omit({ appId: true }), req.query);
    await query(res, { appId: requireAppId(req) }, q);
  });
  return r;
}

/** Mounted at /organizations/:orgId/audit-logs (mergeParams). */
export function orgAuditLogRouter(): Router {
  const r = Router({ mergeParams: true });
  r.get('/', requireOrg('audit:read'), async (req: Request, res: Response) => {
    const tenant = requireTenant(req);
    const q = parse(auditQuery, req.query);
    const base: Record<string, unknown> = { orgId: tenant.orgId };
    // App-scoped members only see entries for their apps.
    const allowed: Types.ObjectId[] | null = tenant.appIds;
    if (q.appId) {
      const id = toObjectId(q.appId);
      base.appId = allowed && !allowed.some((a) => a.equals(id)) ? { $in: [] } : id;
    } else if (allowed) {
      base.appId = { $in: allowed };
    }
    await query(res, base, q);
  });
  return r;
}
