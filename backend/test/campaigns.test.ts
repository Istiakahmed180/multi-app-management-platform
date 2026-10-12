import request from 'supertest';
import { beforeEach, describe, expect, it } from 'vitest';
import { AppUser } from '../src/modules/app-users/app-user.models.js';
import { NotificationCampaign } from '../src/modules/campaigns/campaign.model.js';
import { Integration } from '../src/modules/integrations/integration.model.js';
import {
  addMember,
  buildTestApp,
  createAdmin,
  createApiKey,
  createAppVia,
  createOrg,
  FAKE_SERVICE_ACCOUNT,
  login,
  type Session,
} from './helpers.js';

describe('notification campaigns', () => {
  let ctx: ReturnType<typeof buildTestApp>;
  let s: Session;
  let agent: Session;
  let app: { id: string; appKey: string };
  let base: string;
  let apiKey: string;

  const message = { name: 'Spring sale', title: 'Sale!', body: '20% off today', audience: { type: 'all' } };

  async function ingestUser(id: string, body: Record<string, unknown>) {
    const res = await request(ctx.app)
      .put(`/api/v1/ingest/apps/${app.appKey}/users/${id}`)
      .set('Authorization', `Bearer ${apiKey}`)
      .send(body);
    expect([200, 201]).toContain(res.status);
  }

  beforeEach(async () => {
    ctx = buildTestApp();
    const admin = await createAdmin('owner@example.com');
    const ag = await createAdmin('agent@example.com');
    const org = await createOrg('Acme', admin._id);
    await addMember(org._id, ag._id, 'support_agent');
    s = await login(ctx.app, 'owner@example.com');
    agent = await login(ctx.app, 'agent@example.com');
    app = await createAppVia(s, String(org._id));
    base = `/api/v1/apps/${app.id}/campaigns`;
    apiKey = await createApiKey(s, app.id);
    await ingestUser('u1', {
      pushOptIn: true,
      platform: 'android',
      pushTokens: [{ token: 'token-android-1', platform: 'android' }],
    });
    await ingestUser('u2', { pushOptIn: true, platform: 'ios', pushTokens: [{ token: 'token-ios-2xxxx', platform: 'ios' }] });
    await ingestUser('u3', { pushOptIn: false, pushTokens: [{ token: 'token-optout-3', platform: 'ios' }] });
    await ingestUser('u4', { pushOptIn: true });
  });

  async function configureFcm() {
    const res = await s.put(`/api/v1/apps/${app.id}/integrations/fcm`, { serviceAccountJson: FAKE_SERVICE_ACCOUNT });
    expect(res.status).toBe(200);
  }

  it('stores FCM credentials encrypted and never returns them', async () => {
    await configureFcm();
    const stored = await Integration.findOne({ type: 'fcm' }).select('+secret').lean();
    expect(JSON.stringify(stored)).not.toContain('PRIVATE KEY');
    const list = await s.get(`/api/v1/apps/${app.id}/integrations`);
    expect(list.body.data.fcm.publicConfig.projectId).toBe('demo-project');
    expect(JSON.stringify(list.body)).not.toContain('PRIVATE KEY');
    expect(
      (
        await s.put(`/api/v1/apps/${app.id}/integrations/fcm`, {
          serviceAccountJson: '{"type":"service_account","project_id":"x"}'.padEnd(60, ' '),
        })
      ).status,
    ).toBe(422);
  });

  it('creates drafts, estimates audiences and requires FCM before scheduling', async () => {
    const draft = await s.post(base, message);
    expect(draft.status).toBe(201);
    expect(draft.body.data.status).toBe('draft');
    const estimate = await s.post(`${base}/audience-estimate`, { audience: { type: 'all' } });
    expect(estimate.body.data).toEqual({ eligibleUsers: 2, totalUsers: 4 });
    const ios = await s.post(`${base}/audience-estimate`, { audience: { type: 'platform', platforms: ['ios'] } });
    expect(ios.body.data.eligibleUsers).toBe(1);
    const sched = await s.post(`${base}/${draft.body.data.id}/schedule`, {});
    expect(sched.status).toBe(503);
    expect(sched.body.error.code).toBe('not_configured');
  });

  it('validates campaign payloads', async () => {
    expect((await s.post(base, { ...message, audience: { type: 'everyone' } })).status).toBe(422);
    expect((await s.post(base, { ...message, imageUrl: 'http://x.example.com/a.png' })).status).toBe(422);
    expect((await s.post(base, { ...message, data: { 'google.c': 'x' } })).status).toBe(422);
    expect((await s.post(base, { ...message, title: '' })).status).toBe(422);
    await configureFcm();
    expect((await s.post(base, { ...message, scheduledAt: '2001-01-01T00:00:00.000Z' })).status).toBe(422);
  });

  it('dispatches due campaigns to eligible users and records delivery stats', async () => {
    await configureFcm();
    const created = await s.post(base, { ...message, data: { deeplink: '/sale' }, scheduledAt: new Date().toISOString() });
    expect(created.body.data.status).toBe('scheduled');
    expect(await ctx.worker.tick()).toBe(1);
    const sentTokens = ctx.push.sent.flatMap((c) => c.tokens).sort();
    expect(sentTokens).toEqual(['token-android-1', 'token-ios-2xxxx']);
    expect(ctx.push.sent[0]!.message.data).toMatchObject({ deeplink: '/sale', campaignId: created.body.data.id });
    const done = await s.get(`${base}/${created.body.data.id}`);
    expect(done.body.data.status).toBe('sent');
    expect(done.body.data.stats).toMatchObject({ targeted: 2, sent: 2, failed: 0 });
    // A second tick finds nothing to do: no duplicate sends.
    expect(await ctx.worker.tick()).toBe(0);
    expect(ctx.push.sent.flatMap((c) => c.tokens)).toHaveLength(2);
  });

  it('does not send campaigns scheduled in the future', async () => {
    await configureFcm();
    await s.post(base, { ...message, scheduledAt: new Date(Date.now() + 3600_000).toISOString() });
    expect(await ctx.worker.tick()).toBe(0);
    expect(ctx.push.sent).toHaveLength(0);
  });

  it('retries transient failures and removes invalid tokens', async () => {
    await configureFcm();
    ctx.push.respond = (token, call) => {
      if (token === 'token-android-1')
        return { ok: false, errorCode: 'messaging/registration-token-not-registered', invalidToken: true };
      if (call === 1) return { ok: false, errorCode: 'messaging/server-unavailable', retryable: true };
      return { ok: true };
    };
    const created = await s.post(base, { ...message, scheduledAt: new Date().toISOString() });
    await ctx.worker.tick();
    const c = await NotificationCampaign.findById(created.body.data.id).lean();
    expect(c!.status).toBe('partially_failed');
    expect(c!.stats).toMatchObject({ sent: 1, failed: 1, invalidTokens: 1 });
    expect(c!.errorSummary).toEqual({ 'messaging/registration-token-not-registered': 1 });
    const u1 = await AppUser.findOne({ externalUserId: 'u1' }).lean();
    expect(u1!.pushTokens).toHaveLength(0);
  });

  it('marks campaigns failed when no recipients are eligible', async () => {
    await configureFcm();
    const created = await s.post(base, {
      ...message,
      audience: { type: 'users', externalUserIds: ['u3', 'nobody'] },
      scheduledAt: new Date().toISOString(),
    });
    await ctx.worker.tick();
    const c = await s.get(`${base}/${created.body.data.id}`);
    expect(c.body.data.status).toBe('failed');
    expect(c.body.data.lastError).toMatch(/No eligible recipients/);
  });

  it('resumes an interrupted dispatch after the lease expires without re-sending', async () => {
    await configureFcm();
    const created = await s.post(base, { ...message, scheduledAt: new Date().toISOString() });
    const u1 = await AppUser.findOne({ externalUserId: 'u1' }).lean();
    // Simulate a crash after u1 was processed: status sending, expired lease, cursor at u1.
    await NotificationCampaign.updateOne(
      { _id: created.body.data.id },
      {
        $set: {
          status: 'sending',
          lockedUntil: new Date(Date.now() - 1000),
          cursor: u1!._id,
          'stats.targeted': 2,
          'stats.sent': 1,
        },
        $inc: { attempts: 1 },
      },
    );
    await ctx.worker.tick();
    expect(ctx.push.sent.flatMap((c) => c.tokens)).toEqual(['token-ios-2xxxx']);
    const c = await NotificationCampaign.findById(created.body.data.id).lean();
    expect(c!.status).toBe('sent');
    expect(c!.stats?.sent).toBe(2);
  });

  it('honours Idempotency-Key for creation', async () => {
    const first = await s.agent.post(base).set('X-CSRF-Token', s.csrf).set('Idempotency-Key', 'create-sale-0001').send(message);
    const replay = await s.agent.post(base).set('X-CSRF-Token', s.csrf).set('Idempotency-Key', 'create-sale-0001').send(message);
    expect(first.status).toBe(201);
    expect(replay.status).toBe(200);
    expect(replay.headers['idempotent-replayed']).toBe('true');
    expect(replay.body.data.id).toBe(first.body.data.id);
    expect(await NotificationCampaign.countDocuments()).toBe(1);
  });

  it('cancels scheduled campaigns and prevents cancelling completed ones', async () => {
    await configureFcm();
    const future = await s.post(base, { ...message, scheduledAt: new Date(Date.now() + 3600_000).toISOString() });
    const cancelled = await s.post(`${base}/${future.body.data.id}/cancel`);
    expect(cancelled.body.data.status).toBe('cancelled');
    expect((await s.post(`${base}/${future.body.data.id}/schedule`, {})).status).toBe(409);

    const now = await s.post(base, { ...message, scheduledAt: new Date().toISOString() });
    await ctx.worker.tick();
    expect((await s.post(`${base}/${now.body.data.id}/cancel`)).status).toBe(409);
    expect((await s.patch(`${base}/${now.body.data.id}`, { title: 'edit' })).status).toBe(409);
  });

  it('lets support agents view but not create, schedule or cancel campaigns', async () => {
    const draft = await s.post(base, message);
    expect((await agent.get(base)).status).toBe(200);
    expect((await agent.post(base, message)).status).toBe(403);
    expect((await agent.post(`${base}/${draft.body.data.id}/schedule`, {})).status).toBe(403);
    expect((await agent.post(`${base}/${draft.body.data.id}/cancel`)).status).toBe(403);
  });

  it('filters and paginates campaign history', async () => {
    for (let i = 0; i < 3; i++) await s.post(base, { ...message, name: `Draft ${i}` });
    await configureFcm();
    await s.post(base, { ...message, name: 'Later', scheduledAt: new Date(Date.now() + 3600_000).toISOString() });
    const drafts = await s.get(`${base}?status=draft&pageSize=2`);
    expect(drafts.body.meta).toMatchObject({ total: 3, totalPages: 2 });
    expect((await s.get(`${base}?status=scheduled`)).body.data[0].name).toBe('Later');
  });
});
