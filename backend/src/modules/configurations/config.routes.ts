import { Router } from 'express';
import type { Deps } from '../../deps.js';
import { requireApp } from '../../shared/middleware/tenancy.js';
import { configController } from './config.controller.js';

/** Mounted at /apps/:appId/configs (mergeParams). */
export function configRouter(deps: Deps): Router {
  const r = Router({ mergeParams: true });
  const c = configController(deps);
  r.get('/', requireApp('config:read'), c.overview);
  r.put('/draft', requireApp('config:write'), c.saveDraft);
  r.post('/publish', requireApp('config:publish'), c.publish);
  r.post('/rollback', requireApp('config:publish'), c.rollback);
  r.get('/versions/:version', requireApp('config:read'), c.getVersion);
  return r;
}

/** Mounted at /public (unauthenticated, separately rate-limited). */
export function publicConfigRouter(deps: Deps): Router {
  const r = Router();
  const c = configController(deps);
  r.get('/apps/:appKey/config', c.publicConfig);
  return r;
}
