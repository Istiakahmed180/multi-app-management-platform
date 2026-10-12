import { beforeEach, describe, expect, it } from 'vitest';
import { AuditLog } from '../src/modules/audit-logs/audit-log.model.js';
import { AppConfig } from '../src/modules/configurations/config.model.js';
import { buildTestApp, createAdmin, createAppVia, createOrg, login, type Session } from './helpers.js';

describe('apps', () => {
  let ctx: ReturnType<typeof buildTestApp>;
  let s: Session;
  let orgId: string;

  beforeEach(async () => {
    ctx = buildTestApp();
    const admin = await createAdmin('owner@example.com');
    orgId = String((await createOrg('Acme', admin._id))._id);
    s = await login(ctx.app, 'owner@example.com');
  });

  it('creates an app with a public appKey, a default draft config and an audit entry', async () => {
    const app = await createAppVia(s, orgId, { name: 'Shop App', description: 'Storefront' });
    expect(app.appKey).toMatch(/^app_[A-Za-z0-9]{20}$/);
    expect(app.slug).toBe('shop-app');
    const draft = await AppConfig.findOne({ appId: app.id, state: 'draft' }).lean();
    expect((draft!.content as { branding: { appTitle: string } }).branding.appTitle).toBe('Shop App');
    expect(await AuditLog.countDocuments({ action: 'app.created', appId: app.id })).toBe(1);
  });

  it('validates platform identifiers', async () => {
    const res = await s.post('/api/v1/apps', { orgId, name: 'No Package', platforms: ['android'] });
    expect(res.status).toBe(422);
    expect(res.body.error.details).toEqual(expect.arrayContaining([expect.objectContaining({ path: 'androidPackageId' })]));
    const bad = await s.post('/api/v1/apps', { orgId, name: 'Bad', platforms: ['ios'], iosBundleId: 'not a bundle' });
    expect(bad.status).toBe(422);
    const unknownField = await s.post('/api/v1/apps', {
      orgId,
      name: 'X',
      platforms: ['ios'],
      iosBundleId: 'com.a.b',
      appKey: 'app_mine',
    });
    expect(unknownField.status).toBe(422);
  });

  it('rejects duplicate slugs within an organization', async () => {
    await createAppVia(s, orgId, { name: 'Same' });
    const res = await s.post('/api/v1/apps', { orgId, name: 'Same', platforms: ['ios'], iosBundleId: 'com.a.b' });
    expect(res.status).toBe(409);
  });

  it('paginates, searches and filters the app list', async () => {
    for (let i = 1; i <= 5; i++) {
      await createAppVia(s, orgId, {
        name: `App ${i}`,
        platforms: i % 2 ? ['android'] : ['ios'],
        androidPackageId: i % 2 ? `com.example.app${i}` : null,
        iosBundleId: i % 2 ? null : `com.example.app${i}`,
        environment: i === 5 ? 'staging' : 'production',
      });
    }
    const page1 = await s.get('/api/v1/apps?page=1&pageSize=2&sort=name');
    expect(page1.body.data.map((a: { name: string }) => a.name)).toEqual(['App 1', 'App 2']);
    expect(page1.body.meta).toEqual({ page: 1, pageSize: 2, total: 5, totalPages: 3 });
    const page3 = await s.get('/api/v1/apps?page=3&pageSize=2&sort=name');
    expect(page3.body.data.map((a: { name: string }) => a.name)).toEqual(['App 5']);
    expect((await s.get('/api/v1/apps?platform=ios')).body.meta.total).toBe(2);
    expect((await s.get('/api/v1/apps?environment=staging')).body.meta.total).toBe(1);
    expect((await s.get('/api/v1/apps?search=app3')).body.data[0].name).toBe('App 3');
    expect((await s.get('/api/v1/apps?pageSize=1000')).status).toBe(422);
    expect((await s.get('/api/v1/apps?sort=password')).status).toBe(422);
    // Regex metacharacters are escaped rather than interpreted.
    expect((await s.get('/api/v1/apps?search=.*')).body.meta.total).toBe(0);
  });

  it('updates apps and records what changed', async () => {
    const app = await createAppVia(s, orgId);
    const res = await s.patch(`/api/v1/apps/${app.id}`, { name: 'Renamed', platforms: ['ios'] });
    expect(res.status).toBe(200);
    expect(res.body.data.name).toBe('Renamed');
    expect(res.body.data.androidPackageId).toBeNull();
    const log = await AuditLog.findOne({ action: 'app.updated' }).lean();
    expect((log!.metadata as { changed: Record<string, unknown> }).changed.name).toEqual({ from: 'Test App', to: 'Renamed' });
    const invalid = await s.patch(`/api/v1/apps/${app.id}`, { platforms: ['android'], androidPackageId: null });
    expect(invalid.status).toBe(422);
  });

  it('changes status; archived apps are hidden from the default list', async () => {
    const app = await createAppVia(s, orgId);
    expect((await s.patch(`/api/v1/apps/${app.id}/status`, { status: 'paused' })).status).toBe(422);
    const res = await s.patch(`/api/v1/apps/${app.id}/status`, { status: 'archived', reason: 'Sunset' });
    expect(res.body.data.status).toBe('archived');
    expect((await s.get('/api/v1/apps')).body.meta.total).toBe(0);
    expect((await s.get('/api/v1/apps?status=archived')).body.meta.total).toBe(1);
  });

  it('returns app details with integration summary and caller permissions', async () => {
    const app = await createAppVia(s, orgId);
    const res = await s.get(`/api/v1/apps/${app.id}`);
    expect(res.body.data.summary).toMatchObject({
      userCount: 0,
      integrations: { fcm: false, serverApiKey: false, webhook: false },
    });
    expect(res.body.data.access.role).toBe('owner');
  });

  it('reports unconfigured storage honestly when presigning uploads', async () => {
    const app = await createAppVia(s, orgId);
    const res = await s.post(`/api/v1/apps/${app.id}/assets/presign`, {
      fileName: 'icon.png',
      contentType: 'image/png',
      contentLength: 1000,
      purpose: 'icon',
    });
    expect(res.status).toBe(503);
    expect(res.body.error.code).toBe('not_configured');
    const tooBig = await s.post(`/api/v1/apps/${app.id}/assets/presign`, {
      fileName: 'i.png',
      contentType: 'image/png',
      contentLength: 50_000_000,
      purpose: 'icon',
    });
    expect(tooBig.status).toBe(422);
  });

  it('returns 404 for malformed and unknown app ids', async () => {
    expect((await s.get('/api/v1/apps/not-an-id')).status).toBe(404);
    expect((await s.get('/api/v1/apps/64b7f0f0f0f0f0f0f0f0f0f0')).status).toBe(404);
  });
});
