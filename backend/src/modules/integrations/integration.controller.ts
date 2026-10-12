import type { Request, Response } from 'express';
import type { Deps } from '../../deps.js';
import { isObjectId, toObjectId } from '../../shared/db.js';
import { AppError, notFound } from '../../shared/errors.js';
import { created, ok, parse, requireAppId, requireAuth, requireTenant } from '../../shared/http.js';
import { audit } from '../audit-logs/audit.service.js';
import { apiKeyBody, fcmBody, webhookBody } from './integration.schemas.js';
import { IntegrationService } from './integration.service.js';

export function integrationController(deps: Deps) {
  const service = new IntegrationService(deps.env, deps.push, deps.webhooks);

  return {
    async list(req: Request, res: Response) {
      ok(res, await service.list(requireAppId(req)));
    },

    async configureFcm(req: Request, res: Response) {
      const body = parse(fcmBody, req.body);
      const appId = requireAppId(req);
      const tenant = requireTenant(req);
      const integ = await service.configureFcm(appId, tenant.orgId, requireAuth(req).adminId, body.serviceAccountJson);
      await audit(req, {
        action: 'integration.fcm_configured',
        orgId: tenant.orgId,
        appId,
        targetType: 'integration',
        targetId: integ._id,
        metadata: integ.publicConfig as Record<string, unknown>,
      });
      ok(res, integ.toJSON());
    },

    async removeFcm(req: Request, res: Response) {
      const appId = requireAppId(req);
      await service.removeType(appId, 'fcm');
      await audit(req, {
        action: 'integration.fcm_removed',
        orgId: requireTenant(req).orgId,
        appId,
        targetType: 'integration',
        targetId: 'fcm',
      });
      ok(res, { removed: true });
    },

    async testFcm(req: Request, res: Response) {
      const appId = requireAppId(req);
      await service.testFcm(appId);
      ok(res, { ok: true });
    },

    async createApiKey(req: Request, res: Response) {
      const body = parse(apiKeyBody, req.body);
      const appId = requireAppId(req);
      const tenant = requireTenant(req);
      const { integration, key } = await service.createApiKey(appId, tenant.orgId, requireAuth(req).adminId, body.name);
      await audit(req, {
        action: 'integration.api_key_created',
        orgId: tenant.orgId,
        appId,
        targetType: 'integration',
        targetId: integration._id,
        metadata: { name: body.name, prefix: integration.keyPrefix },
      });
      // The plaintext key is returned exactly once and never stored.
      created(res, { ...integration.toJSON(), apiKey: key });
    },

    async revokeApiKey(req: Request, res: Response) {
      const id = req.params.integrationId;
      if (!isObjectId(id)) throw notFound('API key');
      const appId = requireAppId(req);
      const integ = await service.revokeApiKey(appId, toObjectId(id));
      await audit(req, {
        action: 'integration.api_key_revoked',
        orgId: requireTenant(req).orgId,
        appId,
        targetType: 'integration',
        targetId: id,
        metadata: { prefix: integ.keyPrefix },
      });
      ok(res, integ.toJSON());
    },

    async configureWebhook(req: Request, res: Response) {
      const body = parse(webhookBody, req.body);
      const appId = requireAppId(req);
      const tenant = requireTenant(req);
      const { integration, signingSecret } = await service.configureWebhook(
        appId,
        tenant.orgId,
        requireAuth(req).adminId,
        body.url,
      );
      await audit(req, {
        action: 'integration.webhook_configured',
        orgId: tenant.orgId,
        appId,
        targetType: 'integration',
        targetId: integration._id,
        metadata: integration.publicConfig as Record<string, unknown>,
      });
      created(res, { ...integration.toJSON(), signingSecret });
    },

    async removeWebhook(req: Request, res: Response) {
      const appId = requireAppId(req);
      await service.removeType(appId, 'webhook');
      await audit(req, {
        action: 'integration.webhook_removed',
        orgId: requireTenant(req).orgId,
        appId,
        targetType: 'integration',
        targetId: 'webhook',
      });
      ok(res, { removed: true });
    },

    async testWebhook(req: Request, res: Response) {
      const appId = requireAppId(req);
      const result = await service.deliverWebhook(appId, 'ping', { appId: String(appId) });
      if (!result) throw new AppError('not_configured', 'No webhook is configured for this app');
      ok(res, result);
    },
  };
}
