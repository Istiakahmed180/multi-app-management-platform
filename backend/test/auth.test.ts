import request from 'supertest';
import { beforeEach, describe, expect, it } from 'vitest';
import { Session } from '../src/modules/auth/auth.models.js';
import { AuditLog } from '../src/modules/audit-logs/audit-log.model.js';
import { buildTestApp, createAdmin, login, PASSWORD } from './helpers.js';

describe('authentication', () => {
  let ctx: ReturnType<typeof buildTestApp>;

  beforeEach(async () => {
    ctx = buildTestApp({ LOGIN_MAX_FAILED_ATTEMPTS: '3' });
    await createAdmin('alice@example.com');
  });

  it('logs in with valid credentials, sets HttpOnly cookies and returns a CSRF token', async () => {
    const res = await request(ctx.app).post('/api/v1/auth/login').send({ email: 'Alice@Example.com', password: PASSWORD });
    expect(res.status).toBe(200);
    expect(res.body.data.admin.email).toBe('alice@example.com');
    expect(res.body.data.admin.passwordHash).toBeUndefined();
    expect(res.body.data.csrfToken).toMatch(/.{20,}/);
    const cookies = res.headers['set-cookie'] as unknown as string[];
    const access = cookies.find((c) => c.startsWith('amp_at='))!;
    const refresh = cookies.find((c) => c.startsWith('amp_rt='))!;
    expect(access).toMatch(/HttpOnly/);
    expect(access).toMatch(/SameSite=Strict/);
    expect(refresh).toMatch(/HttpOnly/);
    expect(refresh).toMatch(/Path=\/api\/v1\/auth/);
    expect(await AuditLog.countDocuments({ action: 'auth.login' })).toBe(1);
  });

  it('rejects wrong passwords and unknown emails with the same error', async () => {
    const wrong = await request(ctx.app)
      .post('/api/v1/auth/login')
      .send({ email: 'alice@example.com', password: 'nope-nope-nope' });
    const unknown = await request(ctx.app)
      .post('/api/v1/auth/login')
      .send({ email: 'ghost@example.com', password: 'nope-nope-nope' });
    expect(wrong.status).toBe(401);
    expect(unknown.status).toBe(401);
    expect(wrong.body.error.message).toBe(unknown.body.error.message);
    expect(await AuditLog.countDocuments({ action: 'auth.login_failed' })).toBe(2);
  });

  it('validates the login payload', async () => {
    const res = await request(ctx.app).post('/api/v1/auth/login').send({ email: 'not-an-email', password: '' });
    expect(res.status).toBe(422);
    expect(res.body.error.code).toBe('validation_failed');
  });

  it('locks the account after repeated failures', async () => {
    for (let i = 0; i < 3; i++) {
      await request(ctx.app).post('/api/v1/auth/login').send({ email: 'alice@example.com', password: 'wrong-password!' });
    }
    const res = await request(ctx.app).post('/api/v1/auth/login').send({ email: 'alice@example.com', password: PASSWORD });
    expect(res.status).toBe(423);
    expect(res.body.error.code).toBe('account_locked');
  });

  it('requires authentication for /me', async () => {
    const res = await request(ctx.app).get('/api/v1/auth/me');
    expect(res.status).toBe(401);
  });

  it('returns the profile and CSRF token from /me', async () => {
    const s = await login(ctx.app, 'alice@example.com');
    const res = await s.get('/api/v1/auth/me');
    expect(res.status).toBe(200);
    expect(res.body.data.admin.email).toBe('alice@example.com');
    expect(res.body.data.csrfToken).toBe(s.csrf);
  });

  it('rejects state-changing requests without a valid CSRF token', async () => {
    const s = await login(ctx.app, 'alice@example.com');
    const missing = await s.agent.post('/api/v1/organizations').send({ name: 'Acme' });
    expect(missing.status).toBe(403);
    expect(missing.body.error.code).toBe('csrf_failed');
    const wrong = await s.agent.post('/api/v1/organizations').set('X-CSRF-Token', 'forged').send({ name: 'Acme' });
    expect(wrong.status).toBe(403);
    const okRes = await s.post('/api/v1/organizations', { name: 'Acme' });
    expect(okRes.status).toBe(201);
  });

  it('logout revokes the session server-side', async () => {
    const s = await login(ctx.app, 'alice@example.com');
    expect((await s.post('/api/v1/auth/logout')).status).toBe(200);
    expect((await s.get('/api/v1/auth/me')).status).toBe(401);
    expect(await Session.countDocuments({ revokedAt: { $ne: null }, revokedReason: 'logout' })).toBe(1);
  });

  it('expires sessions whose access token is past its expiry', async () => {
    const s = await login(ctx.app, 'alice@example.com');
    await Session.updateMany({}, { $set: { accessExpiresAt: new Date(Date.now() - 1000) } });
    const res = await s.get('/api/v1/auth/me');
    expect(res.status).toBe(401);
    expect(res.body.error.code).toBe('session_expired');
  });

  it('refresh rotates tokens and restores access', async () => {
    const s = await login(ctx.app, 'alice@example.com');
    const before = await Session.findOne().lean();
    await Session.updateMany({}, { $set: { accessExpiresAt: new Date(Date.now() - 1000) } });
    const res = await s.agent.post('/api/v1/auth/refresh');
    expect(res.status).toBe(200);
    expect(res.body.data.csrfToken).toBeTruthy();
    const after = await Session.findOne().lean();
    expect(after!.refreshTokenHash).not.toBe(before!.refreshTokenHash);
    expect(after!.accessTokenHash).not.toBe(before!.accessTokenHash);
    expect((await s.get('/api/v1/auth/me')).status).toBe(200);
  });

  it('revokes the session when a rotated refresh token is reused', async () => {
    const s = await login(ctx.app, 'alice@example.com');
    const loginRes = await request(ctx.app).post('/api/v1/auth/login').send({ email: 'alice@example.com', password: PASSWORD });
    const cookies = loginRes.headers['set-cookie'] as unknown as string[];
    const oldRefresh = cookies.find((c) => c.startsWith('amp_rt='))!.split(';')[0]!;
    // Rotate once with the legitimate client.
    expect((await request(ctx.app).post('/api/v1/auth/refresh').set('Cookie', oldRefresh)).status).toBe(200);
    // Move the rotation outside the concurrency grace window, then replay the old token.
    await Session.updateMany({}, { $set: { rotatedAt: new Date(Date.now() - 120_000) } });
    const replay = await request(ctx.app).post('/api/v1/auth/refresh').set('Cookie', oldRefresh);
    expect(replay.status).toBe(401);
    expect(await Session.countDocuments({ revokedReason: 'refresh_token_reuse' })).toBe(1);
    // The first, unrelated session is unaffected.
    expect((await s.get('/api/v1/auth/me')).status).toBe(200);
  });

  it('lists and revokes sessions', async () => {
    const a = await login(ctx.app, 'alice@example.com');
    const b = await login(ctx.app, 'alice@example.com');
    const list = await a.get('/api/v1/auth/sessions');
    expect(list.body.data).toHaveLength(2);
    const other = list.body.data.find((x: { current: boolean }) => !x.current);
    expect((await a.del(`/api/v1/auth/sessions/${other.id}`)).status).toBe(200);
    expect((await b.get('/api/v1/auth/me')).status).toBe(401);
    expect((await a.get('/api/v1/auth/me')).status).toBe(200);
  });

  it('revoke-others keeps only the current session', async () => {
    const a = await login(ctx.app, 'alice@example.com');
    const b = await login(ctx.app, 'alice@example.com');
    const res = await a.post('/api/v1/auth/sessions/revoke-others');
    expect(res.body.data.revoked).toBe(1);
    expect((await b.get('/api/v1/auth/me')).status).toBe(401);
    expect((await a.get('/api/v1/auth/me')).status).toBe(200);
  });

  it('changing the password enforces policy and revokes other sessions', async () => {
    const a = await login(ctx.app, 'alice@example.com');
    const b = await login(ctx.app, 'alice@example.com');
    const weak = await a.post('/api/v1/auth/change-password', { currentPassword: PASSWORD, newPassword: 'short' });
    expect(weak.status).toBe(422);
    const wrongCurrent = await a.post('/api/v1/auth/change-password', {
      currentPassword: 'not-my-password',
      newPassword: 'a-much-longer-password',
    });
    expect(wrongCurrent.status).toBe(422);
    const res = await a.post('/api/v1/auth/change-password', {
      currentPassword: PASSWORD,
      newPassword: 'a-much-longer-password',
    });
    expect(res.status).toBe(200);
    expect((await b.get('/api/v1/auth/me')).status).toBe(401);
    expect((await a.get('/api/v1/auth/me')).status).toBe(200);
    await login(ctx.app, 'alice@example.com', 'a-much-longer-password');
  });

  it('never writes passwords into audit logs', async () => {
    const a = await login(ctx.app, 'alice@example.com');
    await a.post('/api/v1/auth/change-password', { currentPassword: PASSWORD, newPassword: 'a-much-longer-password' });
    const logs = await AuditLog.find().lean();
    expect(JSON.stringify(logs)).not.toContain(PASSWORD);
    expect(JSON.stringify(logs)).not.toContain('a-much-longer-password');
  });

  it('disabled admins cannot use existing sessions', async () => {
    const a = await login(ctx.app, 'alice@example.com');
    const { Admin } = await import('../src/modules/auth/auth.models.js');
    await Admin.updateOne({ email: 'alice@example.com' }, { $set: { status: 'disabled' } });
    expect((await a.get('/api/v1/auth/me')).status).toBe(401);
  });
});
