import type { Request } from 'express';
import type { Types } from 'mongoose';
import { logger } from '../../config/logger.js';
import { redact } from '../../shared/redact.js';
import { AuditLog } from './audit-log.model.js';

export interface AuditEntry {
  action: string;
  orgId?: Types.ObjectId | null;
  appId?: Types.ObjectId | null;
  targetType?: string;
  targetId?: string | Types.ObjectId;
  metadata?: Record<string, unknown>;
}

interface Actor {
  actorType: 'admin' | 'api_key' | 'system';
  actorId?: Types.ObjectId | null;
  actorEmail?: string | null;
}

/**
 * Persists an audit entry. Failures are logged but never break the request that
 * triggered them, because the primary change has already been committed.
 */
export async function recordAudit(entry: AuditEntry, actor: Actor, req?: Request): Promise<void> {
  try {
    await AuditLog.create({
      orgId: entry.orgId ?? null,
      appId: entry.appId ?? null,
      action: entry.action,
      targetType: entry.targetType ?? null,
      targetId: entry.targetId ? String(entry.targetId) : null,
      metadata: redact(entry.metadata ?? {}),
      actorType: actor.actorType,
      actorId: actor.actorId ?? null,
      actorEmail: actor.actorEmail ?? null,
      ip: req?.ip ?? null,
      userAgent: req?.get('user-agent')?.slice(0, 300) ?? null,
      requestId: req?.ctx?.requestId ?? null,
    });
  } catch (err) {
    logger.error({ err, action: entry.action }, 'Failed to write audit log');
  }
}

/** Audit helper for requests made by an authenticated admin. */
export function audit(req: Request, entry: AuditEntry): Promise<void> {
  const auth = req.ctx.auth;
  return recordAudit(entry, { actorType: 'admin', actorId: auth?.adminId ?? null, actorEmail: auth?.email ?? null }, req);
}
