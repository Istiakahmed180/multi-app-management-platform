import { Router } from 'express';
import type { Deps } from '../../deps.js';
import { requireApp } from '../../shared/middleware/tenancy.js';
import { appController } from './app.controller.js';

export function appRouter(deps: Deps): Router {
  const r = Router();
  const c = appController(deps);
  r.get('/', c.list);
  r.post('/', c.create);
  r.get('/:appId', requireApp('apps:read'), c.get);
  r.patch('/:appId', requireApp('apps:write'), c.update);
  r.patch('/:appId/status', requireApp('apps:write'), c.setStatus);
  r.post('/:appId/assets/presign', requireApp('apps:write'), c.presignUpload);
  return r;
}
