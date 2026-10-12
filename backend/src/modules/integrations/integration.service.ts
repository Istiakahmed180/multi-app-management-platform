import type { Types } from 'mongoose';
import type { Env } from '../../config/env.js';
import { decrypt, encrypt, randomToken, sha256 } from '../../shared/crypto.js';
import { AppError, notFound } from '../../shared/errors.js';
import type { PushProvider, PushProviderFactory } from '../campaigns/push.provider.js';
import { serviceAccountSchema } from '../campaigns/push.provider.js';
import { Integration } from './integration.model.js';
import { assertSafeWebhookUrl, type WebhookResult, type WebhookSender } from './webhook.sender.js';

export const API_KEY_PREFIX = 'amk_';

export class IntegrationService {
  constructor(
    private readonly env: Env,
    private readonly pushFactory: PushProviderFactory,
    private readonly webhooks: WebhookSender,
  ) {}

  async list(appId: Types.ObjectId) {
    const items = await Integration.find({ appId }).sort({ status: 1, createdAt: -1 }).limit(200);
    const active = items.filter((i) => i.status === 'active');
    return {
      fcm: active.find((i) => i.type === 'fcm')?.toJSON() ?? null,
      webhook: active.find((i) => i.type === 'webhook')?.toJSON() ?? null,
      apiKeys: items.filter((i) => i.type === 'server_api_key').map((i) => i.toJSON()),
      storage: { configured: Boolean(this.env.S3_BUCKET && this.env.S3_ACCESS_KEY_ID) },
    };
  }

  private async revokeActive(appId: Types.ObjectId, type: 'fcm' | 'webhook') {
    await Integration.updateMany({ appId, type, status: 'active' }, { $set: { status: 'revoked', revokedAt: new Date() } });
  }

  async configureFcm(appId: Types.ObjectId, orgId: Types.ObjectId, adminId: Types.ObjectId, serviceAccountJson: string) {
    let parsed;
    try {
      parsed = serviceAccountSchema.parse(JSON.parse(serviceAccountJson));
    } catch {
      throw new AppError('validation_failed', 'Invalid Firebase service account JSON', [
        {
          path: 'serviceAccountJson',
          message: 'Expected a service account key file with project_id, client_email and private_key',
        },
      ]);
    }
    await this.revokeActive(appId, 'fcm');
    return Integration.create({
      orgId,
      appId,
      type: 'fcm',
      name: `Firebase (${parsed.project_id})`,
      publicConfig: { projectId: parsed.project_id, clientEmail: parsed.client_email },
      secret: encrypt(serviceAccountJson, this.env.ENCRYPTION_KEY),
      createdBy: adminId,
    });
  }

  async removeType(appId: Types.ObjectId, type: 'fcm' | 'webhook') {
    const res = await Integration.updateMany(
      { appId, type, status: 'active' },
      { $set: { status: 'revoked', revokedAt: new Date() } },
    );
    if (res.modifiedCount === 0) throw notFound('Integration');
  }

  /** Returns the push provider for an app, or null when FCM is not configured. */
  async pushProviderFor(appId: Types.ObjectId): Promise<PushProvider | null> {
    const integ = await Integration.findOne({ appId, type: 'fcm', status: 'active' }).select('+secret');
    if (!integ?.secret?.data) return null;
    const json = decrypt(integ.secret as { iv: string; tag: string; data: string }, this.env.ENCRYPTION_KEY);
    return this.pushFactory.forCredentials(json, `${integ._id}-${integ.updatedAt?.getTime() ?? 0}`);
  }

  async testFcm(appId: Types.ObjectId) {
    const provider = await this.pushProviderFor(appId);
    if (!provider) throw new AppError('not_configured', 'Firebase Cloud Messaging is not configured for this app');
    await provider.verify();
    await Integration.updateOne({ appId, type: 'fcm', status: 'active' }, { $set: { lastUsedAt: new Date() } });
  }

  async createApiKey(appId: Types.ObjectId, orgId: Types.ObjectId, adminId: Types.ObjectId, name: string) {
    const key = `${API_KEY_PREFIX}${randomToken(32)}`;
    const integ = await Integration.create({
      orgId,
      appId,
      type: 'server_api_key',
      name,
      keyHash: sha256(key),
      keyPrefix: key.slice(0, 12),
      createdBy: adminId,
    });
    return { integration: integ, key };
  }

  async revokeApiKey(appId: Types.ObjectId, id: Types.ObjectId) {
    const integ = await Integration.findOneAndUpdate(
      { _id: id, appId, type: 'server_api_key', status: 'active' },
      { $set: { status: 'revoked', revokedAt: new Date() } },
      { returnDocument: 'after' },
    );
    if (!integ) throw notFound('API key');
    return integ;
  }

  async configureWebhook(appId: Types.ObjectId, orgId: Types.ObjectId, adminId: Types.ObjectId, rawUrl: string) {
    const url = assertSafeWebhookUrl(rawUrl, this.env);
    const secret = `whsec_${randomToken(32)}`;
    await this.revokeActive(appId, 'webhook');
    const integ = await Integration.create({
      orgId,
      appId,
      type: 'webhook',
      name: `Webhook (${url.host})`,
      publicConfig: { url: url.toString(), events: ['user.status_changed', 'ping'] },
      secret: encrypt(secret, this.env.ENCRYPTION_KEY),
      createdBy: adminId,
    });
    return { integration: integ, signingSecret: secret };
  }

  /**
   * Delivers an event to the app backend's webhook. Returns null when no webhook
   * is configured so callers can report that the change was not propagated.
   */
  async deliverWebhook(appId: Types.ObjectId, event: string, payload: Record<string, unknown>): Promise<WebhookResult | null> {
    const integ = await Integration.findOne({ appId, type: 'webhook', status: 'active' }).select('+secret');
    if (!integ?.secret?.data) return null;
    const secret = decrypt(integ.secret as { iv: string; tag: string; data: string }, this.env.ENCRYPTION_KEY);
    const url = String((integ.publicConfig as { url?: string }).url);
    let result = await this.webhooks.send(url, secret, event, payload);
    // One quick retry for transient failures; the outcome is reported to the caller either way.
    if (!result.ok && (result.status === null || result.status >= 500)) {
      result = await this.webhooks.send(url, secret, event, payload);
    }
    await Integration.updateOne(
      { _id: integ._id },
      {
        $set: {
          lastDeliveryAt: new Date(),
          lastDeliveryStatus: result.ok ? `ok (${result.status})` : `failed (${result.error})`,
        },
      },
    );
    return result;
  }
}
