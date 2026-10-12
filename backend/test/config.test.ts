import request from 'supertest';
import { beforeEach, describe, expect, it } from 'vitest';
import { defaultConfigContent } from '../src/modules/configurations/config.content.js';
import { AppConfig } from '../src/modules/configurations/config.model.js';
import { buildTestApp, createAdmin, createAppVia, createOrg, login, type Session } from './helpers.js';

describe('remote configuration', () => {
  let ctx: ReturnType<typeof buildTestApp>;
  let s: Session;
  let app: { id: string; appKey: string };
  let base: string;

  beforeEach(async () => {
    ctx = buildTestApp();
    const admin = await createAdmin('owner@example.com');
    const org = await createOrg('Acme', admin._id);
    s = await login(ctx.app, 'owner@example.com');
    app = await createAppVia(s, String(org._id), { name: 'Config App' });
    base = `/api/v1/apps/${app.id}/configs`;
  });

  const content = (patch: (c: ReturnType<typeof defaultConfigContent>) => void = () => undefined) => {
    const c = defaultConfigContent('Config App');
    patch(c);
    return c;
  };

  it('starts with an unpublished draft and no versions', async () => {
    const res = await s.get(base);
    expect(res.status).toBe(200);
    expect(res.body.data.current).toBeNull();
    expect(res.body.data.versions).toEqual([]);
    expect(res.body.data.draft.hasUnpublishedChanges).toBe(true);
    const pub = await request(ctx.app).get(`/api/v1/public/apps/${app.appKey}/config`);
    expect(pub.status).toBe(404);
  });

  it('rejects invalid configuration payloads with field-level errors', async () => {
    const cases: [string, unknown][] = [
      ['bad color', content((c) => (c.theme.light.primary = 'blue'))],
      ['http image', content((c) => (c.branding.logoUrl = 'http://insecure.example.com/logo.png'))],
      ['bad semver', content((c) => (c.updatePolicy.android.minimumVersion = '1.2'))],
      ['unknown field', { ...content(), secretKey: 'x' }],
      [
        'duplicate banner ids',
        content(
          (c) =>
            (c.banners = [
              {
                id: 'a',
                title: 'A',
                subtitle: null,
                imageUrl: null,
                actionUrl: null,
                active: true,
                priority: 0,
                startsAt: null,
                endsAt: null,
              },
              {
                id: 'a',
                title: 'B',
                subtitle: null,
                imageUrl: null,
                actionUrl: null,
                active: true,
                priority: 0,
                startsAt: null,
                endsAt: null,
              },
            ]),
        ),
      ],
      [
        'missing section',
        (() => {
          const c: Record<string, unknown> = content();
          delete c.theme;
          return c;
        })(),
      ],
    ];
    for (const [label, body] of cases) {
      const res = await s.put(`${base}/draft`, { content: body });
      expect(res.status, label).toBe(422);
      expect(res.body.error.details.length, label).toBeGreaterThan(0);
    }
  });

  it('saves drafts with optimistic concurrency', async () => {
    const first = await s.get(base);
    const updatedAt = first.body.data.draft.updatedAt;
    const ok = await s.put(`${base}/draft`, {
      content: content((c) => (c.branding.appTitle = 'v1 title')),
      expectedUpdatedAt: updatedAt,
    });
    expect(ok.status).toBe(200);
    const stale = await s.put(`${base}/draft`, {
      content: content((c) => (c.branding.appTitle = 'lost update')),
      expectedUpdatedAt: updatedAt,
    });
    expect(stale.status).toBe(409);
  });

  it('publishes immutable versions, refuses no-op publishes and keeps history', async () => {
    await s.put(`${base}/draft`, { content: content((c) => (c.branding.appTitle = 'Version One')) });
    const v1 = await s.post(`${base}/publish`, { changeNote: 'first' });
    expect(v1.status).toBe(200);
    expect(v1.body.data.version).toBe(1);
    expect((await s.post(`${base}/publish`, {})).status).toBe(409);

    await s.put(`${base}/draft`, { content: content((c) => (c.branding.appTitle = 'Version Two')) });
    expect((await s.post(`${base}/publish`, { changeNote: 'second' })).body.data.version).toBe(2);

    const overview = await s.get(base);
    expect(overview.body.data.current.version).toBe(2);
    expect(overview.body.data.versions.map((v: { version: number }) => v.version)).toEqual([2, 1]);
    expect(overview.body.data.draft.hasUnpublishedChanges).toBe(false);

    const v1Content = await s.get(`${base}/versions/1`);
    expect(v1Content.body.data.content.branding.appTitle).toBe('Version One');

    // Published documents cannot be modified, even through the model layer.
    const res = await AppConfig.updateOne({ appId: app.id, version: 1 }, { $set: { 'content.branding.appTitle': 'tampered' } });
    expect(res.modifiedCount).toBe(0);
    expect((await s.get(`${base}/versions/1`)).body.data.content.branding.appTitle).toBe('Version One');
  });

  it('rolls back by publishing a new version with the old content and resets the draft', async () => {
    await s.put(`${base}/draft`, { content: content((c) => (c.branding.appTitle = 'Good')) });
    await s.post(`${base}/publish`, {});
    await s.put(`${base}/draft`, { content: content((c) => (c.branding.appTitle = 'Broken')) });
    await s.post(`${base}/publish`, {});
    expect((await s.post(`${base}/rollback`, { version: 2 })).status).toBe(409);
    expect((await s.post(`${base}/rollback`, { version: 99 })).status).toBe(404);
    const rb = await s.post(`${base}/rollback`, { version: 1, changeNote: 'revert' });
    expect(rb.status).toBe(200);
    expect(rb.body.data).toMatchObject({ version: 3, rollbackOfVersion: 1 });
    const overview = await s.get(base);
    expect(overview.body.data.draft.content.branding.appTitle).toBe('Good');
    const pub = await request(ctx.app).get(`/api/v1/public/apps/${app.appKey}/config`);
    expect(pub.body.configVersion).toBe(3);
    expect(pub.body.config.branding.appTitle).toBe('Good');
  });

  describe('public endpoint', () => {
    beforeEach(async () => {
      await s.put(`${base}/draft`, {
        content: content((c) => {
          c.internalNotes = 'Do not leak: partner contract details';
          c.maintenance = { enabled: true, title: 'Down', message: 'Back soon', estimatedEndAt: null };
          c.banners = [
            {
              id: 'live',
              title: 'Sale',
              subtitle: null,
              imageUrl: null,
              actionUrl: null,
              active: true,
              priority: 1,
              startsAt: null,
              endsAt: null,
            },
            {
              id: 'off',
              title: 'Hidden',
              subtitle: null,
              imageUrl: null,
              actionUrl: null,
              active: false,
              priority: 2,
              startsAt: null,
              endsAt: null,
            },
            {
              id: 'past',
              title: 'Expired',
              subtitle: null,
              imageUrl: null,
              actionUrl: null,
              active: true,
              priority: 3,
              startsAt: null,
              endsAt: '2020-01-01T00:00:00.000Z',
            },
          ];
        }),
      });
      await s.post(`${base}/publish`, {});
    });

    it('exposes only the approved public projection', async () => {
      const res = await request(ctx.app).get(`/api/v1/public/apps/${app.appKey}/config`);
      expect(res.status).toBe(200);
      expect(res.headers['access-control-allow-origin']).toBe('*');
      expect(res.body.schemaVersion).toBe(1);
      expect(res.body.config.maintenance.enabled).toBe(true);
      expect(JSON.stringify(res.body)).not.toContain('partner contract');
      expect(res.body.config.internalNotes).toBeUndefined();
      expect(res.body.config.banners.map((b: { id: string }) => b.id)).toEqual(['live']);
      expect(Object.keys(res.body).sort()).toEqual([
        'appKey',
        'config',
        'configVersion',
        'features',
        'publishedAt',
        'schemaVersion',
      ]);
    });

    it('supports ETag revalidation with 304 responses', async () => {
      const first = await request(ctx.app).get(`/api/v1/public/apps/${app.appKey}/config`);
      const etag = first.headers.etag as string;
      expect(etag).toMatch(/^"v1-/);
      expect(first.headers['cache-control']).toContain('max-age=');
      const second = await request(ctx.app).get(`/api/v1/public/apps/${app.appKey}/config`).set('If-None-Match', etag);
      expect(second.status).toBe(304);
      expect(second.text).toBe('');
      // Publishing invalidates the cache and changes the ETag.
      await s.put(`${base}/draft`, { content: content((c) => (c.branding.appTitle = 'Changed')) });
      await s.post(`${base}/publish`, {});
      const third = await request(ctx.app).get(`/api/v1/public/apps/${app.appKey}/config`).set('If-None-Match', etag);
      expect(third.status).toBe(200);
      expect(third.body.config.branding.appTitle).toBe('Changed');
    });

    it('returns 404 for unknown keys and inactive apps', async () => {
      expect((await request(ctx.app).get('/api/v1/public/apps/app_doesnotexist0000/config')).status).toBe(404);
      expect((await request(ctx.app).get('/api/v1/public/apps/../config')).status).toBe(404);
      await s.patch(`/api/v1/apps/${app.id}/status`, { status: 'inactive' });
      expect((await request(ctx.app).get(`/api/v1/public/apps/${app.appKey}/config`)).status).toBe(404);
    });

    it('does not accept writes or credentials on the public surface', async () => {
      const res = await request(ctx.app).post(`/api/v1/public/apps/${app.appKey}/config`).send({});
      expect(res.status).toBe(404);
    });
  });
});
