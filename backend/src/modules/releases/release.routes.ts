import { Router } from 'express';
import type { Deps } from '../../deps.js';
import { requireApp } from '../../shared/middleware/tenancy.js';
import { releaseController } from './release.controller.js';

/** Mounted at /apps/:appId/releases (mergeParams). */
export function releaseRouter(deps: Deps): Router {
  const r = Router({ mergeParams: true });
  const c = releaseController(deps);
  r.get('/', requireApp('releases:read'), c.list);
  r.get('/summary', requireApp('releases:read'), c.summary);
  r.post('/', requireApp('releases:write'), c.create);
  r.patch('/:releaseId', requireApp('releases:write'), c.update);
  r.post('/:releaseId/apply-to-draft', requireApp('releases:write'), c.applyToDraft);
  return r;
}
