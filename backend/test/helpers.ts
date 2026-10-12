import { randomBytes } from 'node:crypto';
import mongoose from 'mongoose';
import request from 'supertest';
import type TestAgent from 'supertest/lib/agent.js';
import { createApp } from '../src/app.js';
import { loadEnv, type Env } from '../src/config/env.js';
import type { Deps } from '../src/deps.js';
import type { StorageService } from '../src/modules/apps/storage.service.js';
import { Admin } from '../src/modules/auth/auth.models.js';
import { AuthService } from '../src/modules/auth/auth.service.js';
import { CampaignWorker } from '../src/modules/campaigns/campaign.worker.js';
import type { PushMessage, PushProvider, PushProviderFactory, PushResult } from '../src/modules/campaigns/push.provider.js';
import { PublicConfigCache } from '../src/modules/configurations/public-config.cache.js';
import { IntegrationService } from '../src/modules/integrations/integration.service.js';
import type { WebhookSender } from '../src/modules/integrations/webhook.sender.js';
import { MetricsRecorder } from '../src/modules/metrics/metrics.recorder.js';
import { Membership, Organization } from '../src/modules/organizations/organization.models.js';
import { hashPassword } from '../src/shared/crypto.js';
import type { OrgRole } from '../src/shared/rbac.js';

export const PASSWORD = 'correct-horse-battery-staple';

export function testEnv(overrides: Record<string, string> = {}): Env {
  return loadEnv({
    NODE_ENV: 'test',
    MONGODB_URI: 'mongodb://unused',
    ENCRYPTION_KEY: randomBytes(32).toString('base64'),
    CORS_ORIGINS: 'http://localhost:8080',
    AUTH_RATE_LIMIT_MAX: '1000',
    RATE_LIMIT_MAX: '10000',
    PUBLIC_RATE_LIMIT_MAX: '10000',
    LOG_LEVEL: 'silent',
    ...overrides,
  });
}

/** Records every push call; behaviour per token is configurable. */
export class FakePushFactory implements PushProviderFactory {
  sent: { tokens: string[]; message: PushMessage }[] = [];
  respond: (token: string, call: number) => Omit<PushResult, 'token'> = () => ({ ok: true });
  verifyError: Error | null = null;
  private calls = 0;

  forCredentials(): PushProvider {
    return {
      sendMulticast: async (tokens, message) => {
        this.calls++;
        this.sent.push({ tokens, message });
        return tokens.map((token) => ({ token, ...this.respond(token, this.calls) }));
      },
      verify: async () => {
        if (this.verifyError) throw this.verifyError;
      },
    };
  }
}

export class FakeWebhookSender implements WebhookSender {
  calls: { url: string; secret: string; event: string; payload: Record<string, unknown> }[] = [];
  result = { ok: true, status: 200 as number | null };
  async send(url: string, secret: string, event: string, payload: Record<string, unknown>) {
    this.calls.push({ url, secret, event, payload });
    return this.result;
  }
}

export const nullStorage: StorageService = {
  configured: false,
  async presignUpload() {
    const { AppError } = await import('../src/shared/errors.js');
    throw new AppError('not_configured', 'Object storage is not configured');
  },
};

export function buildTestApp(envOverrides: Record<string, string> = {}) {
  const env = testEnv(envOverrides);
  const push = new FakePushFactory();
  const webhooks = new FakeWebhookSender();
  const deps: Deps = {
    env,
    auth: new AuthService(env),
    push,
    webhooks,
    storage: nullStorage,
    metrics: new MetricsRecorder(),
    publicConfigCache: new PublicConfigCache(30_000),
  };
  const app = createApp(deps);
  const worker = new CampaignWorker(new IntegrationService(env, push, webhooks), async () => undefined);
  return { app, deps, env, push, webhooks, worker };
}

export async function createAdmin(email: string, opts: { superAdmin?: boolean; name?: string } = {}) {
  return Admin.create({
    email,
    name: opts.name ?? email.split('@')[0],
    passwordHash: await hashPassword(PASSWORD),
    isSuperAdmin: opts.superAdmin ?? false,
  });
}

export async function createOrg(name: string, owner: mongoose.Types.ObjectId) {
  const org = await Organization.create({ name, slug: name.toLowerCase().replace(/\s+/g, '-'), createdBy: owner });
  await Membership.create({ orgId: org._id, adminId: owner, role: 'owner' });
  return org;
}

export async function addMember(
  orgId: mongoose.Types.ObjectId,
  adminId: mongoose.Types.ObjectId,
  role: OrgRole,
  appIds: string[] = [],
) {
  return Membership.create({ orgId, adminId, role, appIds });
}

export interface Session {
  agent: TestAgent;
  csrf: string;
  /** Mutating request helpers that attach the CSRF header. */
  post: (url: string, body?: object) => request.Test;
  put: (url: string, body?: object) => request.Test;
  patch: (url: string, body?: object) => request.Test;
  del: (url: string) => request.Test;
  get: (url: string) => request.Test;
}

export async function login(app: Parameters<typeof request.agent>[0], email: string, password = PASSWORD): Promise<Session> {
  const agent = request.agent(app);
  const res = await agent.post('/api/v1/auth/login').send({ email, password });
  if (res.status !== 200) throw new Error(`Login failed for ${email}: ${res.status} ${JSON.stringify(res.body)}`);
  const csrf: string = res.body.data.csrfToken;
  return {
    agent,
    csrf,
    get: (url) => agent.get(url),
    post: (url, body) =>
      agent
        .post(url)
        .set('X-CSRF-Token', csrf)
        .send(body ?? {}),
    put: (url, body) =>
      agent
        .put(url)
        .set('X-CSRF-Token', csrf)
        .send(body ?? {}),
    patch: (url, body) =>
      agent
        .patch(url)
        .set('X-CSRF-Token', csrf)
        .send(body ?? {}),
    del: (url) => agent.delete(url).set('X-CSRF-Token', csrf),
  };
}

export async function createAppVia(s: Session, orgId: string, overrides: Record<string, unknown> = {}) {
  const res = await s.post('/api/v1/apps', {
    orgId,
    name: 'Test App',
    platforms: ['android', 'ios'],
    androidPackageId: 'com.example.test',
    iosBundleId: 'com.example.test',
    ...overrides,
  });
  if (res.status !== 201) throw new Error(`App creation failed: ${res.status} ${JSON.stringify(res.body)}`);
  return res.body.data as { id: string; appKey: string; orgId: string; slug: string };
}

export async function createApiKey(s: Session, appId: string): Promise<string> {
  const res = await s.post(`/api/v1/apps/${appId}/integrations/api-keys`, { name: 'backend' });
  if (res.status !== 201) throw new Error(`API key creation failed: ${res.status} ${JSON.stringify(res.body)}`);
  return res.body.data.apiKey;
}

export const FAKE_SERVICE_ACCOUNT = JSON.stringify({
  type: 'service_account',
  project_id: 'demo-project',
  client_email: 'push@demo-project.iam.gserviceaccount.com',
  private_key: '-----BEGIN PRIVATE KEY-----\nTESTONLY\n-----END PRIVATE KEY-----\n',
});
