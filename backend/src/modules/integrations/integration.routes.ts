import { Router } from 'express';
import type { Deps } from '../../deps.js';
import { requireApp } from '../../shared/middleware/tenancy.js';
import { integrationController } from './integration.controller.js';

/** Mounted at /apps/:appId/integrations (mergeParams). */
export function integrationRouter(deps: Deps): Router {
  const r = Router({ mergeParams: true });
  const c = integrationController(deps);
  r.get('/', requireApp('integrations:read'), c.list);
  r.put('/fcm', requireApp('integrations:write'), c.configureFcm);
  r.delete('/fcm', requireApp('integrations:write'), c.removeFcm);
  r.post('/fcm/test', requireApp('integrations:write'), c.testFcm);
  r.post('/api-keys', requireApp('integrations:write'), c.createApiKey);
  r.delete('/api-keys/:integrationId', requireApp('integrations:write'), c.revokeApiKey);
  r.put('/webhook', requireApp('integrations:write'), c.configureWebhook);
  r.delete('/webhook', requireApp('integrations:write'), c.removeWebhook);
  r.post('/webhook/test', requireApp('integrations:write'), c.testWebhook);
  return r;
}
