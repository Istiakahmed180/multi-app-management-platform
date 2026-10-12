import { Router } from 'express';
import { requireApp } from '../../shared/middleware/tenancy.js';
import { analyticsController } from './analytics.controller.js';

/** Mounted at /apps/:appId/analytics (mergeParams). */
export function analyticsRouter(): Router {
  const r = Router({ mergeParams: true });
  r.get('/', requireApp('analytics:read'), analyticsController().app);
  return r;
}

/** Mounted at /overview. */
export function overviewRouter(): Router {
  const r = Router();
  r.get('/', analyticsController().overview);
  return r;
}
