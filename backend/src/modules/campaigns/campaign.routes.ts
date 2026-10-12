import { Router } from 'express';
import type { Deps } from '../../deps.js';
import { requireApp } from '../../shared/middleware/tenancy.js';
import { campaignController } from './campaign.controller.js';

/** Mounted at /apps/:appId/campaigns (mergeParams). */
export function campaignRouter(deps: Deps): Router {
  const r = Router({ mergeParams: true });
  const c = campaignController(deps);
  r.get('/', requireApp('campaigns:read'), c.list);
  r.post('/', requireApp('campaigns:write'), c.create);
  r.post('/audience-estimate', requireApp('campaigns:read'), c.estimate);
  r.get('/:campaignId', requireApp('campaigns:read'), c.get);
  r.patch('/:campaignId', requireApp('campaigns:write'), c.update);
  r.post('/:campaignId/schedule', requireApp('campaigns:write'), c.schedule);
  r.post('/:campaignId/cancel', requireApp('campaigns:write'), c.cancel);
  return r;
}
