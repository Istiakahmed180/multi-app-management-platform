import request from 'supertest';
import { beforeEach, describe, expect, it } from 'vitest';
import { AuditLog } from '../src/modules/audit-logs/audit-log.model.js';
import { buildTestApp, createAdmin, createAppVia, createOrg, login, type Session } from './helpers.js';

describe('feature flags', () => {
  let ctx: ReturnType<typeof buildTestApp>;
  let s: Session;
  let app: { id: string; appKey: string };
  let base: string;

  beforeEach(async () => {
    ctx = buildTestApp();
    const admin = await createAdmin('owner@example.com');
    const org = await createOrg('Acme', admin._id);
    s = await login(ctx.app, 'owner@example.com');
    app = await createAppVia(s, String(org._id));
    base = `/api/v1/apps/${app.id}/features`;
    await s.post(`/api/v1/apps/${app.id}/configs/publish`, {});
  });

  it('creates, lists, updates and deletes flags with audit entries', async () => {
    const created = await s.post(base, {
      key: 'new_checkout',
      description: 'Checkout v2',
      rolloutPercentage: 25,
      platforms: ['android'],
    });
    expect(created.status).toBe(201);
    expect(created.body.data).toMatchObject({ key: 'new_checkout', enabled: false, rolloutPercentage: 25 });
    expect((await s.post(base, { key: 'new_checkout' })).status).toBe(409);
    expect((await s.post(base, { key: 'Bad Key!' })).status).toBe(422);
    expect((await s.post(base, { key: 'x', rolloutPercentage: 150 })).status).toBe(422);

    const updated = await s.patch(`${base}/new_checkout`, { enabled: true, minAppVersion: '2.1.0' });
    expect(updated.status).toBe(200);
    expect(updated.body.data.enabled).toBe(true);
    expect((await s.patch(`${base}/missing_flag`, { enabled: true })).status).toBe(404);
    expect((await s.patch(`${base}/new_checkout`, {})).status).toBe(422);

    const list = await s.get(`${base}?enabled=true`);
    expect(list.body.data).toHaveLength(1);

    const log = await AuditLog.findOne({ action: 'flag.updated' }).lean();
    expect((log!.metadata as { changes: Record<string, unknown> }).changes.enabled).toEqual({ from: false, to: true });

    expect((await s.del(`${base}/new_checkout`)).status).toBe(200);
    expect((await s.get(base)).body.data).toHaveLength(0);
  });

  it('exposes only enabled flags publicly and reflects changes immediately', async () => {
    await s.post(base, { key: 'dark_launch', enabled: false });
    await s.post(base, { key: 'ios_only', enabled: true, platforms: ['ios'] });
    const pub = () => request(ctx.app).get(`/api/v1/public/apps/${app.appKey}/config`);
    let res = await pub();
    expect(Object.keys(res.body.features)).toEqual(['ios_only']);
    const android = await request(ctx.app).get(`/api/v1/public/apps/${app.appKey}/config?platform=android`);
    expect(android.body.features).toEqual({});

    await s.patch(`${base}/dark_launch`, { enabled: true, rolloutPercentage: 10 });
    res = await pub();
    expect(res.body.features.dark_launch).toEqual({ enabled: true, rolloutPercentage: 10, platforms: [], minAppVersion: null });
  });
});
