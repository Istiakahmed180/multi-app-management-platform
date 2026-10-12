import { Router } from 'express';
import type { Deps } from '../../deps.js';
import { requireApp } from '../../shared/middleware/tenancy.js';
import { featureFlagController } from './feature-flag.controller.js';

/** Mounted at /apps/:appId/features (mergeParams). */
export function featureFlagRouter(deps: Deps): Router {
  const r = Router({ mergeParams: true });
  const c = featureFlagController(deps);
  r.get('/', requireApp('flags:read'), c.list);
  r.post('/', requireApp('flags:write'), c.create);
  r.patch('/:key', requireApp('flags:write'), c.update);
  r.delete('/:key', requireApp('flags:write'), c.remove);
  return r;
}
