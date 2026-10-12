import { Router } from 'express';
import type { Deps } from '../../deps.js';
import { requireApp } from '../../shared/middleware/tenancy.js';
import { appUserController } from './app-user.controller.js';

/** Mounted at /apps/:appId/users (mergeParams). */
export function appUserRouter(deps: Deps): Router {
  const r = Router({ mergeParams: true });
  const c = appUserController(deps);
  r.get('/', requireApp('users:read'), c.list);
  r.get('/:userId', requireApp('users:read'), c.get);
  r.get('/:userId/activity', requireApp('users:read'), c.activity);
  r.patch('/:userId/status', requireApp('users:write'), c.setStatus);
  return r;
}
