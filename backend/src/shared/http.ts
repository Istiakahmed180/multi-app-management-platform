import type { Request, Response } from 'express';
import type { Types } from 'mongoose';
import { z } from 'zod';
import { AppError } from './errors.js';
import type { PageMeta } from './pagination.js';
import type { OrgRole, Permission } from './rbac.js';

export interface AuthContext {
  adminId: Types.ObjectId;
  email: string;
  name: string;
  isSuperAdmin: boolean;
  sessionId: Types.ObjectId;
}

export interface TenantContext {
  orgId: Types.ObjectId;
  /** `super_admin` when access comes from the platform-level flag rather than a membership. */
  role: OrgRole | 'super_admin';
  permissions: ReadonlySet<Permission>;
  /** `null` = all apps in the organization. */
  appIds: Types.ObjectId[] | null;
}

export interface RequestContext {
  requestId: string;
  auth?: AuthContext;
  tenant?: TenantContext;
  appId?: Types.ObjectId;
  metricsAppId?: Types.ObjectId;
}

declare global {
  // eslint-disable-next-line @typescript-eslint/no-namespace
  namespace Express {
    interface Request {
      ctx: RequestContext;
    }
  }
}

export function parse<S extends z.ZodType>(schema: S, data: unknown): z.output<S> {
  const result = schema.safeParse(data);
  if (!result.success) {
    throw new AppError(
      'validation_failed',
      'Request validation failed',
      result.error.issues.map((i) => ({ path: i.path.join('.'), message: i.message, code: i.code })),
    );
  }
  return result.data;
}

export function ok<T>(res: Response, data: T, meta?: PageMeta | Record<string, unknown>, status = 200): void {
  res.status(status).json(meta ? { data, meta } : { data });
}

export function created<T>(res: Response, data: T): void {
  ok(res, data, undefined, 201);
}

export function requireAuth(req: Request): AuthContext {
  if (!req.ctx.auth) throw new AppError('unauthenticated', 'Authentication required');
  return req.ctx.auth;
}

export function requireTenant(req: Request): TenantContext {
  if (!req.ctx.tenant) throw new AppError('internal_error', 'Tenant context missing');
  return req.ctx.tenant;
}

export function requireAppId(req: Request): Types.ObjectId {
  if (!req.ctx.appId) throw new AppError('internal_error', 'App context missing');
  return req.ctx.appId;
}

export function clientInfo(req: Request): { ip?: string; userAgent?: string } {
  return { ip: req.ip, userAgent: req.get('user-agent')?.slice(0, 300) };
}

export const objectIdString = z.string().regex(/^[a-f0-9]{24}$/i, 'Invalid id');
