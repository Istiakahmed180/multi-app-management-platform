import request from 'supertest';
import { beforeEach, describe, expect, it } from 'vitest';
import { runRetention } from '../src/jobs/retention.js';
import { AuditLog } from '../src/modules/audit-logs/audit-log.model.js';
import { ApiMetric } from '../src/modules/metrics/api-metric.model.js';
import { normalizePath } from '../src/modules/metrics/metrics.recorder.js';
import { redact } from '../src/shared/redact.js';
import { buildTestApp, createAdmin, createApiKey, createAppVia, createOrg, login, type Session } from './helpers.js';

describe('releases', () => {
  let ctx: ReturnType<typeof buildTestApp>;
  let s: Session;
  let app: { id: string };
  let base: string;

  beforeEach(async () => {
    ctx = buildTestApp();
    const admin = await createAdmin('owner@example.com');
    const org = await createOrg('Acme', admin._id);
    s = await login(ctx.app, 'owner@example.com');
    app = await createAppVia(s, String(org._id), { platforms: ['android'], iosBundleId: null });
    base = `/api/v1/apps/${app.id}/releases`;
  });

  it('records release metadata and history', async () => {
    const created = await s.post(base, {
      platform: 'android',
      version: '2.0.0',
      buildNumber: 200,
      releaseNotes: 'Big update',
      rolloutPercentage: 20,
      status: 'rolling_out',
    });
    expect(created.status).toBe(201);
    expect((await s.post(base, { platform: 'android', version: '2.0.0', buildNumber: 201 })).status).toBe(409);
    expect((await s.post(base, { platform: 'ios', version: '2.0.0', buildNumber: 1 })).status).toBe(409);
    expect((await s.post(base, { platform: 'android', version: 'two', buildNumber: 1 })).status).toBe(422);
    const released = await s.patch(`${base}/${created.body.data.id}`, { status: 'released', rolloutPercentage: 100 });
    expect(released.body.data.releasedAt).toBeTruthy();
    const list = await s.get(`${base}?platform=android`);
    expect(list.body.meta.total).toBe(1);
    const summary = await s.get(`${base}/summary`);
    expect(summary.body.data.latestReleased.android.version).toBe('2.0.0');
    expect(summary.body.data.publishedPolicy).toBeNull();
  });

  it('applies a mandatory release to the draft update policy without publishing', async () => {
    const r = await s.post(base, {
      platform: 'android',
      version: '3.0.0',
      buildNumber: 300,
      isMandatory: true,
      storeUrl: 'https://play.google.com/store/apps/details?id=com.example.test',
    });
    const applied = await s.post(`${base}/${r.body.data.id}/apply-to-draft`);
    expect(applied.status).toBe(200);
    expect(applied.body.data.draftUpdatePolicy.android).toEqual({
      minimumVersion: '3.0.0',
      latestVersion: '3.0.0',
      updateUrl: 'https://play.google.com/store/apps/details?id=com.example.test',
    });
    const configs = await s.get(`/api/v1/apps/${app.id}/configs`);
    expect(configs.body.data.current).toBeNull();
    expect(configs.body.data.draft.content.updatePolicy.android.minimumVersion).toBe('3.0.0');
  });
});

describe('analytics and overview', () => {
  let ctx: ReturnType<typeof buildTestApp>;
  let s: Session;
  let app: { id: string; appKey: string };

  beforeEach(async () => {
    ctx = buildTestApp();
    const admin = await createAdmin('owner@example.com');
    const org = await createOrg('Acme', admin._id);
    s = await login(ctx.app, 'owner@example.com');
    app = await createAppVia(s, String(org._id));
  });

  it('reports empty states instead of fabricated numbers', async () => {
    const res = await s.get(`/api/v1/apps/${app.id}/analytics?days=7`);
    expect(res.status).toBe(200);
    expect(res.body.data.users.total).toBe(0);
    expect(res.body.data.activity).toMatchObject({ available: false, dau: null, mau: null, activeByDay: [] });
    expect(res.body.data.versions.available).toBe(false);
    expect(res.body.data.users.newByDay).toHaveLength(7);
    const overview = await s.get('/api/v1/overview');
    expect(overview.body.data.users.activity).toEqual({ available: false, active7d: null });
    expect(overview.body.data.apps.total).toBe(1);
    expect(overview.body.data.appHealth[0]).toMatchObject({
      id: app.id,
      publishedConfigVersion: null,
      integrations: { fcm: false },
    });
  });

  it('computes analytics from ingested data and recorded API metrics', async () => {
    const key = await createApiKey(s, app.id);
    for (const [id, version, platform] of [
      ['a', '1.0.0', 'android'],
      ['b', '1.0.0', 'android'],
      ['c', '1.1.0', 'ios'],
    ] as const) {
      await request(ctx.app)
        .put(`/api/v1/ingest/apps/${app.appKey}/users/${id}`)
        .set('Authorization', `Bearer ${key}`)
        .send({ appVersion: version, platform });
    }
    await request(ctx.app)
      .post(`/api/v1/ingest/apps/${app.appKey}/events`)
      .set('Authorization', `Bearer ${key}`)
      .send({ events: [{ externalUserId: 'a', type: 'open', occurredAt: new Date().toISOString() }] });
    await s.post(`/api/v1/apps/${app.id}/configs/publish`, {});
    await request(ctx.app).get(`/api/v1/public/apps/${app.appKey}/config`);
    await ctx.deps.metrics.flush();

    const res = await s.get(`/api/v1/apps/${app.id}/analytics?days=30`);
    const d = res.body.data;
    expect(d.users.total).toBe(3);
    expect(d.users.newInRange).toBe(3);
    expect(d.activity).toMatchObject({ available: true, dau: 1, mau: 1 });
    expect(d.versions.distribution).toEqual(
      expect.arrayContaining([
        { platform: 'android', appVersion: '1.0.0', count: 2 },
        { platform: 'ios', appVersion: '1.1.0', count: 1 },
      ]),
    );
    expect(d.api.available).toBe(true);
    expect(d.api.requests).toBeGreaterThanOrEqual(5);
    expect(d.api.topRoutes.map((r: { route: string }) => r.route)).toContain('/api/v1/public/apps/:appKey/config');
  });
});

describe('audit logs, retention and metrics', () => {
  let ctx: ReturnType<typeof buildTestApp>;
  let s: Session;
  let orgId: string;
  let app: { id: string };

  beforeEach(async () => {
    ctx = buildTestApp();
    const admin = await createAdmin('owner@example.com');
    orgId = String((await createOrg('Acme', admin._id))._id);
    s = await login(ctx.app, 'owner@example.com');
    app = await createAppVia(s, orgId);
  });

  it('searches and paginates audit logs per app and per organization', async () => {
    await s.post(`/api/v1/apps/${app.id}/features`, { key: 'one' });
    await s.post(`/api/v1/apps/${app.id}/features`, { key: 'two' });
    await s.post(`/api/v1/apps/${app.id}/configs/publish`, {});
    const flags = await s.get(`/api/v1/apps/${app.id}/audit-logs?action=flag.&pageSize=1`);
    expect(flags.body.meta).toMatchObject({ total: 2, totalPages: 2 });
    const org = await s.get(`/api/v1/organizations/${orgId}/audit-logs?actorEmail=owner@`);
    expect(org.body.meta.total).toBeGreaterThanOrEqual(4);
    expect(org.body.data[0].actorEmail).toBe('owner@example.com');
    const ranged = await s.get(`/api/v1/apps/${app.id}/audit-logs?from=2000-01-01T00:00:00.000Z&to=2000-01-02T00:00:00.000Z`);
    expect(ranged.body.meta.total).toBe(0);
  });

  it('redacts secrets in audit metadata', () => {
    expect(redact({ name: 'x', password: 'p', nested: { apiKey: 'k', token: 't', ok: 1 }, list: [{ secret: 's' }] })).toEqual({
      name: 'x',
      password: '[REDACTED]',
      nested: { apiKey: '[REDACTED]', token: '[REDACTED]', ok: 1 },
      list: [{ secret: '[REDACTED]' }],
    });
  });

  it('deletes data older than the retention windows', async () => {
    const old = new Date(Date.now() - 400 * 86_400_000);
    await AuditLog.create({ actorType: 'system', action: 'old.entry', createdAt: old });
    await ApiMetric.create({ bucket: old, route: '/x', method: 'GET', count: 1 });
    await ApiMetric.create({ bucket: new Date(), route: '/x', method: 'GET', count: 1 });
    const before = await AuditLog.countDocuments();
    const result = await runRetention({ AUDIT_RETENTION_DAYS: 365, METRICS_RETENTION_DAYS: 90, EVENTS_RETENTION_DAYS: 90 });
    expect(result).toMatchObject({ auditLogs: 1, apiMetrics: 1 });
    expect(await AuditLog.countDocuments()).toBe(before - 1);
    expect(await ApiMetric.countDocuments()).toBe(1);
  });

  it('normalizes metric routes so ids and keys do not explode cardinality', () => {
    expect(normalizePath('/api/v1/apps/64b7f0f0f0f0f0f0f0f0f0f0/users/64b7f0f0f0f0f0f0f0f0f0f1?page=2')).toBe(
      '/api/v1/apps/:id/users/:id',
    );
    expect(normalizePath('/api/v1/public/apps/app_abcDEF1234567890abcd/config')).toBe('/api/v1/public/apps/:appKey/config');
    expect(normalizePath('/api/v1/ingest/apps/app_abcDEF1234567890abcd/users/user-42/status')).toBe(
      '/api/v1/ingest/apps/:appKey/users/:externalUserId/status',
    );
  });
});

describe('HTTP behaviour', () => {
  let ctx: ReturnType<typeof buildTestApp>;
  beforeEach(() => {
    ctx = buildTestApp({ BODY_LIMIT: '2kb' });
  });

  it('serves health with database status', async () => {
    const res = await request(ctx.app).get('/api/v1/health');
    expect(res.status).toBe(200);
    expect(res.body.data).toMatchObject({ status: 'ok', checks: { database: 'connected' } });
    expect((await request(ctx.app).get('/api/v1/health/live')).status).toBe(200);
  });

  it('returns structured errors with request ids', async () => {
    const res = await request(ctx.app).get('/api/v1/nope');
    expect(res.status).toBe(401);
    const unmatched = await request(ctx.app).get('/elsewhere');
    expect(unmatched.status).toBe(404);
    expect(unmatched.body.error).toMatchObject({ code: 'not_found' });
    expect(unmatched.body.error.requestId).toBe(unmatched.headers['x-request-id']);
  });

  it('rejects malformed JSON and oversized bodies', async () => {
    const bad = await request(ctx.app).post('/api/v1/auth/login').set('Content-Type', 'application/json').send('{"email":');
    expect(bad.status).toBe(400);
    expect(bad.body.error.code).toBe('bad_request');
    const big = await request(ctx.app)
      .post('/api/v1/auth/login')
      .send({ email: 'a@b.co', password: 'x'.repeat(5000) });
    expect(big.status).toBe(413);
  });

  it('sets security headers and only allows listed CORS origins with credentials', async () => {
    const allowed = await request(ctx.app).get('/api/v1/auth/me').set('Origin', 'http://localhost:8080');
    expect(allowed.headers['access-control-allow-origin']).toBe('http://localhost:8080');
    expect(allowed.headers['access-control-allow-credentials']).toBe('true');
    const denied = await request(ctx.app).get('/api/v1/auth/me').set('Origin', 'https://evil.example.com');
    expect(denied.headers['access-control-allow-origin']).toBeUndefined();
    expect(allowed.headers['x-content-type-options']).toBe('nosniff');
    expect(allowed.headers['x-powered-by']).toBeUndefined();
  });

  it('rate limits login attempts', async () => {
    const limited = buildTestApp({ AUTH_RATE_LIMIT_MAX: '2' });
    for (let i = 0; i < 2; i++) await request(limited.app).post('/api/v1/auth/login').send({ email: 'a@b.co', password: 'x' });
    const res = await request(limited.app).post('/api/v1/auth/login').send({ email: 'a@b.co', password: 'x' });
    expect(res.status).toBe(429);
    expect(res.body.error.code).toBe('rate_limited');
  });
});

describe('environment configuration', () => {
  it('treats blank values as unset and requires secrets', async () => {
    const { loadEnv } = await import('../src/config/env.js');
    const key = Buffer.alloc(32, 1).toString('base64');
    const env = loadEnv({ MONGODB_URI: 'mongodb://x', ENCRYPTION_KEY: key, S3_ENDPOINT: '', DASHBOARD_URL: ' ' });
    expect(env.S3_ENDPOINT).toBeUndefined();
    expect(() => loadEnv({ MONGODB_URI: 'mongodb://x', ENCRYPTION_KEY: '' })).toThrow(/ENCRYPTION_KEY/);
    expect(() => loadEnv({ MONGODB_URI: 'mongodb://x', ENCRYPTION_KEY: 'short' })).toThrow(/32 bytes/);
    expect(() => loadEnv({ NODE_ENV: 'production', MONGODB_URI: 'mongodb://x', ENCRYPTION_KEY: key })).toThrow(/CORS_ORIGINS/);
  });
});
