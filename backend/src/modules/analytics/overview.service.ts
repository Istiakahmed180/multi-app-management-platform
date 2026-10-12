import type { Types } from 'mongoose';
import type { AuthContext } from '../../shared/http.js';
import { accessibleAppFilter, accessibleOrgs } from '../../shared/middleware/tenancy.js';
import { ROLE_PERMISSIONS } from '../../shared/rbac.js';
import { App } from '../apps/app.model.js';
import { AppUser } from '../app-users/app-user.models.js';
import { AuditLog } from '../audit-logs/audit-log.model.js';
import { NotificationCampaign } from '../campaigns/campaign.model.js';
import { Integration } from '../integrations/integration.model.js';
import { ApiMetric } from '../metrics/api-metric.model.js';
import { apiMetricsSummary } from './analytics.service.js';

const DAY = 86_400_000;

/** Organization-wide (or all accessible orgs) dashboard overview built only from stored data. */
export class OverviewService {
  async build(auth: AuthContext, orgId?: Types.ObjectId, now = new Date()) {
    const appFilter = await accessibleAppFilter(auth, orgId);
    if (!appFilter) return null;
    const apps = await App.find({ ...appFilter, status: { $ne: 'archived' } })
      .select('_id name slug status platforms environment publishedConfigVersion orgId iconUrl')
      .sort({ name: 1 })
      .limit(500)
      .lean();
    const appIds = apps.map((a) => a._id);
    const since24h = new Date(now.getTime() - DAY);

    const [totalUsers, new7d, new30d, withActivity, active7d, campaignRows, integrations, metricsByApp, api24h] =
      await Promise.all([
        AppUser.countDocuments({ appId: { $in: appIds } }),
        AppUser.countDocuments({ appId: { $in: appIds }, createdAt: { $gte: new Date(now.getTime() - 7 * DAY) } }),
        AppUser.countDocuments({ appId: { $in: appIds }, createdAt: { $gte: new Date(now.getTime() - 30 * DAY) } }),
        AppUser.countDocuments({ appId: { $in: appIds }, lastSeenAt: { $ne: null } }),
        AppUser.countDocuments({ appId: { $in: appIds }, lastSeenAt: { $gte: new Date(now.getTime() - 7 * DAY) } }),
        NotificationCampaign.aggregate<{ _id: string; count: number; sent: number; failed: number }>([
          { $match: { appId: { $in: appIds } } },
          { $group: { _id: '$status', count: { $sum: 1 }, sent: { $sum: '$stats.sent' }, failed: { $sum: '$stats.failed' } } },
        ]),
        Integration.find({ appId: { $in: appIds }, status: 'active' })
          .select('appId type lastUsedAt')
          .lean(),
        ApiMetric.aggregate<{ _id: Types.ObjectId; requests: number; errors: number }>([
          { $match: { appId: { $in: appIds }, bucket: { $gte: since24h } } },
          { $group: { _id: '$appId', requests: { $sum: '$count' }, errors: { $sum: '$serverErrors' } } },
        ]),
        apiMetricsSummary({ appId: { $in: appIds } }, since24h),
      ]);

    const integrationsByApp = new Map<string, { fcm: boolean; apiKey: boolean; webhook: boolean; lastIngestAt: Date | null }>();
    for (const i of integrations) {
      const k = String(i.appId);
      const cur = integrationsByApp.get(k) ?? { fcm: false, apiKey: false, webhook: false, lastIngestAt: null };
      if (i.type === 'fcm') cur.fcm = true;
      if (i.type === 'webhook') cur.webhook = true;
      if (i.type === 'server_api_key') {
        cur.apiKey = true;
        if (i.lastUsedAt && (!cur.lastIngestAt || i.lastUsedAt > cur.lastIngestAt)) cur.lastIngestAt = i.lastUsedAt;
      }
      integrationsByApp.set(k, cur);
    }
    const metrics = new Map(metricsByApp.map((m) => [String(m._id), m]));

    // Recent activity only from orgs where the admin may read audit logs.
    const orgs = (await accessibleOrgs(auth)).filter(
      (o) => (!orgId || o.orgId.equals(orgId)) && (o.role === 'super_admin' || ROLE_PERMISSIONS[o.role].has('audit:read')),
    );
    const recentActivity = orgs.length
      ? await AuditLog.find({
          $or: orgs.map((o) => (o.appIds ? { orgId: o.orgId, appId: { $in: o.appIds } } : { orgId: o.orgId })),
          actorType: { $ne: 'system' },
        })
          .sort({ createdAt: -1 })
          .limit(10)
          .lean()
      : [];

    return {
      apps: {
        total: apps.length,
        byStatus: apps.reduce<Record<string, number>>((acc, a) => ({ ...acc, [a.status]: (acc[a.status] ?? 0) + 1 }), {}),
      },
      users: {
        total: totalUsers,
        new7d,
        new30d,
        activity: { available: withActivity > 0, active7d: withActivity > 0 ? active7d : null },
      },
      api: { window: '24h', ...api24h },
      campaigns: {
        total: campaignRows.reduce((s, r) => s + r.count, 0),
        byStatus: Object.fromEntries(campaignRows.map((r) => [r._id, r.count])),
        delivered: campaignRows.reduce((s, r) => s + r.sent, 0),
        failed: campaignRows.reduce((s, r) => s + r.failed, 0),
      },
      appHealth: apps.map((a) => {
        const m = metrics.get(String(a._id));
        const integ = integrationsByApp.get(String(a._id)) ?? { fcm: false, apiKey: false, webhook: false, lastIngestAt: null };
        return {
          id: String(a._id),
          orgId: String(a.orgId),
          name: a.name,
          slug: a.slug,
          iconUrl: a.iconUrl,
          status: a.status,
          environment: a.environment,
          platforms: a.platforms,
          publishedConfigVersion: a.publishedConfigVersion,
          integrations: integ,
          requests24h: m?.requests ?? 0,
          errorRate24h: m && m.requests > 0 ? m.errors / m.requests : null,
        };
      }),
      recentActivity: recentActivity.map((l) => ({
        id: String(l._id),
        action: l.action,
        actorEmail: l.actorEmail,
        actorType: l.actorType,
        appId: l.appId ? String(l.appId) : null,
        targetType: l.targetType,
        targetId: l.targetId,
        createdAt: l.createdAt,
      })),
    };
  }
}
