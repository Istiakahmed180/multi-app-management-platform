import request from 'supertest';
import { beforeEach, describe, expect, it } from 'vitest';
import { Membership } from '../src/modules/organizations/organization.models.js';
import { addMember, buildTestApp, createAdmin, createAppVia, createOrg, login, type Session } from './helpers.js';

/**
 * Two organizations:
 *   org1 (owner1) with app1a, app1b; members: appAdmin (all apps), scoped (app1a only), agent (support)
 *   org2 (owner2) with app2
 */
describe('tenant isolation and RBAC', () => {
  let ctx: ReturnType<typeof buildTestApp>;
  let owner1: Session;
  let owner2: Session;
  let appAdmin: Session;
  let scoped: Session;
  let agent: Session;
  let org1Id: string;
  let org2Id: string;
  let app1a: { id: string };
  let app1b: { id: string };
  let app2: { id: string };

  beforeEach(async () => {
    ctx = buildTestApp();
    const o1 = await createAdmin('owner1@example.com');
    const o2 = await createAdmin('owner2@example.com');
    const aa = await createAdmin('appadmin@example.com');
    const sc = await createAdmin('scoped@example.com');
    const ag = await createAdmin('agent@example.com');
    const org1 = await createOrg('Org One', o1._id);
    const org2 = await createOrg('Org Two', o2._id);
    org1Id = String(org1._id);
    org2Id = String(org2._id);
    owner1 = await login(ctx.app, 'owner1@example.com');
    owner2 = await login(ctx.app, 'owner2@example.com');
    app1a = await createAppVia(owner1, org1Id, { name: 'App One A' });
    app1b = await createAppVia(owner1, org1Id, { name: 'App One B' });
    app2 = await createAppVia(owner2, org2Id, { name: 'App Two' });
    await addMember(org1._id, aa._id, 'app_admin');
    await addMember(org1._id, sc._id, 'app_admin', [app1a.id]);
    await addMember(org1._id, ag._id, 'support_agent');
    appAdmin = await login(ctx.app, 'appadmin@example.com');
    scoped = await login(ctx.app, 'scoped@example.com');
    agent = await login(ctx.app, 'agent@example.com');
  });

  describe('cross-organization', () => {
    it('hides other organizations entirely', async () => {
      expect((await owner2.get(`/api/v1/organizations/${org1Id}`)).status).toBe(404);
      expect((await owner2.get(`/api/v1/organizations/${org1Id}/members`)).status).toBe(404);
      expect(
        (await owner2.post(`/api/v1/organizations/${org1Id}/invitations`, { email: 'x@example.com', role: 'owner' })).status,
      ).toBe(404);
      const list = await owner2.get('/api/v1/organizations');
      expect(list.body.data.map((o: { id: string }) => o.id)).toEqual([org2Id]);
    });

    it('denies every app-scoped endpoint for apps in another organization', async () => {
      const base = `/api/v1/apps/${app1a.id}`;
      const reads = [
        '',
        '/configs',
        '/features',
        '/users',
        '/campaigns',
        '/releases',
        '/analytics',
        '/audit-logs',
        '/integrations',
      ];
      for (const path of reads) {
        const res = await owner2.get(base + path);
        expect(res.status, `GET ${path}`).toBe(404);
      }
      expect((await owner2.patch(base, { name: 'Hijacked' })).status).toBe(404);
      expect((await owner2.put(`${base}/configs/draft`, { content: {} })).status).toBe(404);
      expect((await owner2.post(`${base}/configs/publish`, {})).status).toBe(404);
      expect((await owner2.post(`${base}/features`, { key: 'x' })).status).toBe(404);
      expect((await owner2.post(`${base}/integrations/api-keys`, { name: 'steal' })).status).toBe(404);
    });

    it('cannot create an app in an organization it does not belong to', async () => {
      const res = await owner2.post('/api/v1/apps', {
        orgId: org1Id,
        name: 'Injected',
        platforms: ['android'],
        androidPackageId: 'com.evil.app',
      });
      expect(res.status).toBe(404);
    });

    it('lists only apps from accessible organizations, even when filtering by another org id', async () => {
      const all = await owner2.get('/api/v1/apps');
      expect(all.body.data.map((a: { id: string }) => a.id)).toEqual([app2.id]);
      const spoofed = await owner2.get(`/api/v1/apps?orgId=${org1Id}`);
      expect(spoofed.body.data).toEqual([]);
    });

    it('scopes the overview to accessible organizations', async () => {
      const res = await owner2.get('/api/v1/overview');
      expect(res.status).toBe(200);
      expect(res.body.data.apps.total).toBe(1);
      expect((await owner2.get(`/api/v1/overview?orgId=${org1Id}`)).status).toBe(404);
    });

    it('cannot read another organization audit trail', async () => {
      expect((await owner2.get(`/api/v1/organizations/${org1Id}/audit-logs`)).status).toBe(404);
    });
  });

  describe('cross-app within an organization', () => {
    it('restricts app-scoped members to their assigned apps', async () => {
      expect((await scoped.get(`/api/v1/apps/${app1a.id}`)).status).toBe(200);
      expect((await scoped.get(`/api/v1/apps/${app1b.id}`)).status).toBe(404);
      expect((await scoped.get(`/api/v1/apps/${app1b.id}/configs`)).status).toBe(404);
      const list = await scoped.get('/api/v1/apps');
      expect(list.body.data.map((a: { id: string }) => a.id)).toEqual([app1a.id]);
    });

    it('filters the organization audit log to assigned apps', async () => {
      await scoped.patch(`/api/v1/apps/${app1a.id}`, { description: 'mine' });
      await appAdmin.patch(`/api/v1/apps/${app1b.id}`, { description: 'other' });
      const res = await scoped.get(`/api/v1/organizations/${org1Id}/audit-logs`);
      expect(res.status).toBe(200);
      const appIds = new Set(res.body.data.map((l: { appId: string }) => l.appId));
      expect(appIds.has(app1b.id)).toBe(false);
      expect(appIds.has(app1a.id)).toBe(true);
      const spoof = await scoped.get(`/api/v1/organizations/${org1Id}/audit-logs?appId=${app1b.id}`);
      expect(spoof.body.data).toEqual([]);
    });

    it('does not resolve a user id that belongs to a different app', async () => {
      const keyA = (await owner1.post(`/api/v1/apps/${app1a.id}/integrations/api-keys`, { name: 'k' })).body.data.apiKey;
      const appA = (await owner1.get(`/api/v1/apps/${app1a.id}`)).body.data;
      const up = await request(ctx.app)
        .put(`/api/v1/ingest/apps/${appA.appKey}/users/u-1`)
        .set('Authorization', `Bearer ${keyA}`)
        .send({ email: 'u1@example.com' });
      const userId = up.body.data.id;
      expect((await owner1.get(`/api/v1/apps/${app1a.id}/users/${userId}`)).status).toBe(200);
      expect((await owner1.get(`/api/v1/apps/${app1b.id}/users/${userId}`)).status).toBe(404);
      expect((await owner1.patch(`/api/v1/apps/${app1b.id}/users/${userId}/status`, { status: 'suspended' })).status).toBe(404);
    });
  });

  describe('role permissions', () => {
    it('support agents can read but not change configuration, flags, apps or campaigns', async () => {
      expect((await agent.get(`/api/v1/apps/${app1a.id}/configs`)).status).toBe(200);
      expect((await agent.post(`/api/v1/apps/${app1a.id}/configs/publish`, {})).status).toBe(403);
      expect((await agent.post(`/api/v1/apps/${app1a.id}/features`, { key: 'beta' })).status).toBe(403);
      expect((await agent.patch(`/api/v1/apps/${app1a.id}`, { name: 'Renamed' })).status).toBe(403);
      expect((await agent.post(`/api/v1/apps/${app1a.id}/campaigns`, {})).status).toBe(403);
      expect((await agent.get(`/api/v1/apps/${app1a.id}/audit-logs`)).status).toBe(403);
      expect((await agent.get(`/api/v1/apps/${app1a.id}/integrations`)).status).toBe(403);
      expect((await agent.get(`/api/v1/organizations/${org1Id}/members`)).status).toBe(403);
    });

    it('app admins manage apps but not members, org settings or integrations secrets', async () => {
      expect((await appAdmin.patch(`/api/v1/apps/${app1a.id}`, { description: 'ok' })).status).toBe(200);
      expect(
        (await appAdmin.post(`/api/v1/organizations/${org1Id}/invitations`, { email: 'n@example.com', role: 'support_agent' }))
          .status,
      ).toBe(403);
      expect((await appAdmin.patch(`/api/v1/organizations/${org1Id}`, { name: 'Renamed' })).status).toBe(403);
      expect((await appAdmin.post(`/api/v1/apps/${app1a.id}/integrations/api-keys`, { name: 'x' })).status).toBe(403);
      expect((await appAdmin.get(`/api/v1/apps/${app1a.id}/integrations`)).status).toBe(200);
      const create = await appAdmin.post('/api/v1/apps', {
        orgId: org1Id,
        name: 'New',
        platforms: ['ios'],
        iosBundleId: 'com.x.y',
      });
      expect(create.status).toBe(403);
    });

    it('owners can manage members and the last owner cannot be removed or demoted', async () => {
      const members = await owner1.get(`/api/v1/organizations/${org1Id}/members?pageSize=50`);
      expect(members.status).toBe(200);
      expect(members.body.meta.total).toBe(4);
      const ownerMembership = members.body.data.find((m: { email: string }) => m.email === 'owner1@example.com');
      expect(
        (await owner1.patch(`/api/v1/organizations/${org1Id}/members/${ownerMembership.id}`, { role: 'app_admin' })).status,
      ).toBe(409);
      expect((await owner1.del(`/api/v1/organizations/${org1Id}/members/${ownerMembership.id}`)).status).toBe(409);
      const agentMembership = members.body.data.find((m: { email: string }) => m.email === 'agent@example.com');
      const promote = await owner1.patch(`/api/v1/organizations/${org1Id}/members/${agentMembership.id}`, {
        role: 'app_admin',
        appIds: [app1b.id],
      });
      expect(promote.status).toBe(200);
      expect(promote.body.data.appIds).toEqual([app1b.id]);
      const foreignApp = await owner1.patch(`/api/v1/organizations/${org1Id}/members/${agentMembership.id}`, {
        appIds: [app2.id],
      });
      expect(foreignApp.status).toBe(400);
      expect((await owner1.del(`/api/v1/organizations/${org1Id}/members/${agentMembership.id}`)).status).toBe(200);
      // Access is re-checked on every request, so removal is immediate.
      expect((await agent.get(`/api/v1/apps/${app1a.id}`)).status).toBe(404);
    });

    it('super admins can access every organization', async () => {
      await createAdmin('root@example.com', { superAdmin: true });
      const root = await login(ctx.app, 'root@example.com');
      expect((await root.get(`/api/v1/apps/${app2.id}`)).status).toBe(200);
      expect((await root.get(`/api/v1/organizations/${org1Id}/members`)).status).toBe(200);
      const orgs = await root.get('/api/v1/organizations');
      expect(orgs.body.meta.total).toBe(2);
    });
  });

  describe('invitations', () => {
    it('invites a new person who creates an account and joins with the invited role', async () => {
      const inv = await owner1.post(`/api/v1/organizations/${org1Id}/invitations`, {
        email: 'new@example.com',
        role: 'app_admin',
        appIds: [app1a.id],
      });
      expect(inv.status).toBe(201);
      const token = inv.body.data.inviteToken;
      const preview = await request(ctx.app).get(`/api/v1/invitations/${token}`);
      expect(preview.body.data).toMatchObject({ email: 'new@example.com', role: 'app_admin', accountExists: false });
      const accept = await request(ctx.app)
        .post('/api/v1/invitations/accept')
        .send({ token, name: 'Newbie', password: 'a-very-secure-password' });
      expect(accept.status).toBe(200);
      expect(accept.body.data.createdAccount).toBe(true);
      const m = await Membership.findOne({ orgId: org1Id }).sort({ createdAt: -1 }).lean();
      expect(m!.role).toBe('app_admin');
      expect(m!.appIds.map(String)).toEqual([app1a.id]);
      // Tokens are single-use.
      const again = await request(ctx.app)
        .post('/api/v1/invitations/accept')
        .send({ token, name: 'Again', password: 'a-very-secure-password' });
      expect(again.status).toBe(404);
    });

    it('requires an existing account to be signed in as the invited email', async () => {
      const inv = await owner2.post(`/api/v1/organizations/${org2Id}/invitations`, {
        email: 'agent@example.com',
        role: 'support_agent',
      });
      const token = inv.body.data.inviteToken;
      const anonymous = await request(ctx.app).post('/api/v1/invitations/accept').send({ token });
      expect(anonymous.status).toBe(401);
      const wrongUser = await owner1.post('/api/v1/invitations/accept', { token });
      expect(wrongUser.status).toBe(401);
      const res = await agent.post('/api/v1/invitations/accept', { token });
      expect(res.status).toBe(200);
      expect((await agent.get(`/api/v1/apps/${app2.id}`)).status).toBe(200);
    });

    it('rejects duplicate membership invitations and app ids from other orgs', async () => {
      expect(
        (await owner1.post(`/api/v1/organizations/${org1Id}/invitations`, { email: 'agent@example.com', role: 'support_agent' }))
          .status,
      ).toBe(409);
      expect(
        (
          await owner1.post(`/api/v1/organizations/${org1Id}/invitations`, {
            email: 'z@example.com',
            role: 'support_agent',
            appIds: [app2.id],
          })
        ).status,
      ).toBe(400);
    });

    it('revoked invitations cannot be accepted', async () => {
      const inv = await owner1.post(`/api/v1/organizations/${org1Id}/invitations`, {
        email: 'late@example.com',
        role: 'support_agent',
      });
      expect((await owner1.del(`/api/v1/organizations/${org1Id}/invitations/${inv.body.data.invitation.id}`)).status).toBe(200);
      const res = await request(ctx.app)
        .post('/api/v1/invitations/accept')
        .send({ token: inv.body.data.inviteToken, name: 'Late', password: 'a-very-secure-password' });
      expect(res.status).toBe(404);
    });
  });
});
