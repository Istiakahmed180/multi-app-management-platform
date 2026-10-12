import request from 'supertest';
import { beforeEach, describe, expect, it } from 'vitest';
import { AppUserEvent } from '../src/modules/app-users/app-user.models.js';
import { AuditLog } from '../src/modules/audit-logs/audit-log.model.js';
import { buildTestApp, createAdmin, createApiKey, createAppVia, createOrg, login, type Session } from './helpers.js';

describe('app users and ingest API', () => {
  let ctx: ReturnType<typeof buildTestApp>;
  let s: Session;
  let app: { id: string; appKey: string };
  let other: { id: string; appKey: string };
  let apiKey: string;

  const ingest = (path: string, key = apiKey) => ({
    put: (body: object) =>
      request(ctx.app).put(`/api/v1/ingest/apps/${app.appKey}${path}`).set('Authorization', `Bearer ${key}`).send(body),
    post: (body: object) =>
      request(ctx.app).post(`/api/v1/ingest/apps/${app.appKey}${path}`).set('Authorization', `Bearer ${key}`).send(body),
    get: () => request(ctx.app).get(`/api/v1/ingest/apps/${app.appKey}${path}`).set('Authorization', `Bearer ${key}`),
    del: () => request(ctx.app).delete(`/api/v1/ingest/apps/${app.appKey}${path}`).set('Authorization', `Bearer ${key}`),
  });

  beforeEach(async () => {
    ctx = buildTestApp();
    const admin = await createAdmin('owner@example.com');
    const org = await createOrg('Acme', admin._id);
    s = await login(ctx.app, 'owner@example.com');
    app = await createAppVia(s, String(org._id), { name: 'Users App' });
    other = await createAppVia(s, String(org._id), { name: 'Other App' });
    apiKey = await createApiKey(s, app.id);
  });

  describe('ingest authentication', () => {
    it('requires a valid server API key bound to the app', async () => {
      expect((await request(ctx.app).put(`/api/v1/ingest/apps/${app.appKey}/users/u1`).send({})).status).toBe(401);
      expect((await ingest('/users/u1', 'amk_invalid').put({})).status).toBe(401);
      const otherKey = await createApiKey(s, other.id);
      const crossApp = await ingest('/users/u1', otherKey).put({});
      expect(crossApp.status).toBe(403);
    });

    it('rejects revoked keys', async () => {
      const list = await s.get(`/api/v1/apps/${app.id}/integrations`);
      const keyId = list.body.data.apiKeys[0].id;
      expect(list.body.data.apiKeys[0].keyPrefix).toBe(apiKey.slice(0, 12));
      expect(JSON.stringify(list.body)).not.toContain(apiKey);
      await s.del(`/api/v1/apps/${app.id}/integrations/api-keys/${keyId}`);
      expect((await ingest('/users/u1').put({})).status).toBe(401);
    });

    it('does not accept dashboard cookies on ingest routes', async () => {
      const res = await s.agent.put(`/api/v1/ingest/apps/${app.appKey}/users/u1`).send({});
      expect(res.status).toBe(401);
    });
  });

  it('upserts users idempotently by externalUserId', async () => {
    const first = await ingest('/users/user-42').put({
      email: 'Jane@Example.com',
      displayName: 'Jane',
      platform: 'ios',
      appVersion: '1.2.0',
      attributes: { plan: 'pro' },
    });
    expect(first.status).toBe(201);
    const second = await ingest('/users/user-42').put({ appVersion: '1.3.0' });
    expect(second.status).toBe(200);
    expect(second.body.data).toMatchObject({ email: 'jane@example.com', appVersion: '1.3.0', attributes: { plan: 'pro' } });
    expect(second.body.data.pushTokens).toBeUndefined();
    expect((await ingest('/users/user-42').put({ email: 'not-an-email' })).status).toBe(422);
    expect((await ingest('/users/bad id!').put({})).status).toBe(422);
  });

  it('lists, searches, filters and paginates users', async () => {
    for (let i = 1; i <= 6; i++) {
      await ingest(`/users/user-${i}`).put({
        email: `user${i}@example.com`,
        platform: i <= 4 ? 'android' : 'ios',
        appVersion: i <= 2 ? '1.0.0' : '2.0.0',
      });
    }
    const page = await s.get(`/api/v1/apps/${app.id}/users?pageSize=4`);
    expect(page.body.meta).toMatchObject({ total: 6, totalPages: 2 });
    expect((await s.get(`/api/v1/apps/${app.id}/users?platform=ios`)).body.meta.total).toBe(2);
    expect((await s.get(`/api/v1/apps/${app.id}/users?appVersion=1.0.0`)).body.meta.total).toBe(2);
    const search = await s.get(`/api/v1/apps/${app.id}/users?search=user3`);
    expect(search.body.data.map((u: { externalUserId: string }) => u.externalUserId)).toEqual(['user-3']);
    // Users are isolated per app.
    expect((await s.get(`/api/v1/apps/${other.id}/users`)).body.meta.total).toBe(0);
  });

  it('ingests activity events and updates last-seen data', async () => {
    await ingest('/users/u1').put({ platform: 'android' });
    const res = await ingest('/events').post({
      events: [
        { externalUserId: 'u1', type: 'session.start', occurredAt: '2026-01-02T10:00:00.000Z', appVersion: '3.1.0' },
        { externalUserId: 'u1', type: 'purchase', occurredAt: '2026-01-02T11:00:00.000Z', properties: { amount: 9.99 } },
        { externalUserId: 'ghost', type: 'session.start', occurredAt: '2026-01-02T10:00:00.000Z' },
      ],
    });
    expect(res.body.data).toEqual({ accepted: 2, rejected: 1, unknownUsers: ['ghost'] });
    const list = await s.get(`/api/v1/apps/${app.id}/users`);
    const user = list.body.data[0];
    expect(user.lastSeenAt).toBe('2026-01-02T11:00:00.000Z');
    expect(user.appVersion).toBe('3.1.0');
    const detail = await s.get(`/api/v1/apps/${app.id}/users/${user.id}`);
    expect(detail.body.data.activity.available).toBe(true);
    expect(detail.body.data.activity.recent[0].type).toBe('purchase');
    const activity = await s.get(`/api/v1/apps/${app.id}/users/${user.id}/activity?pageSize=1`);
    expect(activity.body.meta.total).toBe(2);
  });

  it('suspends users, notifies the app backend via signed webhook and exposes status to the backend', async () => {
    await ingest('/users/u1').put({});
    const userId = (await s.get(`/api/v1/apps/${app.id}/users`)).body.data[0].id;

    const noHook = await s.patch(`/api/v1/apps/${app.id}/users/${userId}/status`, { status: 'suspended', reason: 'Fraud' });
    expect(noHook.status).toBe(200);
    expect(noHook.body.data.propagation).toMatchObject({ attempted: false, delivered: false });
    expect((await ingest('/users/u1/status').get()).body.data).toMatchObject({ status: 'suspended', reason: 'Fraud' });
    expect((await s.patch(`/api/v1/apps/${app.id}/users/${userId}/status`, { status: 'suspended' })).status).toBe(409);

    const hook = await s.put(`/api/v1/apps/${app.id}/integrations/webhook`, { url: 'https://backend.example.com/hooks/amp' });
    expect(hook.status).toBe(201);
    expect(hook.body.data.signingSecret).toMatch(/^whsec_/);
    const reactivate = await s.patch(`/api/v1/apps/${app.id}/users/${userId}/status`, { status: 'active' });
    expect(reactivate.body.data.propagation).toMatchObject({ attempted: true, delivered: true });
    const call = ctx.webhooks.calls.at(-1)!;
    expect(call.event).toBe('user.status_changed');
    expect(call.secret).toBe(hook.body.data.signingSecret);
    expect(call.payload).toMatchObject({ externalUserId: 'u1', status: 'active', previousStatus: 'suspended' });
    expect(await AuditLog.countDocuments({ action: { $in: ['app_user.suspended', 'app_user.reactivated'] } })).toBe(2);
  });

  it('rejects webhook URLs that are not https', async () => {
    const env = buildTestApp({ NODE_ENV: 'production', CORS_ORIGINS: 'https://dash.example.com' });
    const { assertSafeWebhookUrl } = await import('../src/modules/integrations/webhook.sender.js');
    expect(() => assertSafeWebhookUrl('http://example.com/hook', env.env)).toThrow();
    expect(() => assertSafeWebhookUrl('https://127.0.0.1/hook', env.env)).toThrow();
    expect(() => assertSafeWebhookUrl('https://10.0.0.5/hook', env.env)).toThrow();
    expect(() => assertSafeWebhookUrl('https://user:pw@example.com/hook', env.env)).toThrow();
    expect(assertSafeWebhookUrl('https://hooks.example.com/x', env.env).host).toBe('hooks.example.com');
  });

  it('deletes a user and their events on request from the app backend', async () => {
    await ingest('/users/u1').put({});
    await ingest('/events').post({ events: [{ externalUserId: 'u1', type: 'open', occurredAt: new Date().toISOString() }] });
    const res = await ingest('/users/u1').del();
    expect(res.body.data).toMatchObject({ deleted: true, deletedEvents: 1 });
    expect(await AppUserEvent.countDocuments()).toBe(0);
    expect((await ingest('/users/u1/status').get()).status).toBe(404);
  });
});
