import type { Types } from 'mongoose';
import { AppUser, AppUserEvent } from '../app-users/app-user.models.js';
import { NotificationCampaign } from '../campaigns/campaign.model.js';
import { ApiMetric } from '../metrics/api-metric.model.js';

const DAY = 86_400_000;

function startOfUtcDay(d: Date): Date {
  return new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate()));
}

/** Fills missing days with zeros so charts have a continuous axis. */
function series<T extends Record<string, number>>(from: Date, days: number, rows: Map<string, T>, empty: T) {
  const out: ({ date: string } & T)[] = [];
  for (let i = 0; i < days; i++) {
    const date = new Date(from.getTime() + i * DAY).toISOString().slice(0, 10);
    out.push({ date, ...(rows.get(date) ?? empty) });
  }
  return out;
}

export async function apiMetricsSummary(match: Record<string, unknown>, since: Date) {
  const [totals] = await ApiMetric.aggregate<{ requests: number; clientErrors: number; serverErrors: number; duration: number }>([
    { $match: { ...match, bucket: { $gte: since } } },
    {
      $group: {
        _id: null,
        requests: { $sum: '$count' },
        clientErrors: { $sum: '$clientErrors' },
        serverErrors: { $sum: '$serverErrors' },
        duration: { $sum: '$totalDurationMs' },
      },
    },
  ]);
  const requests = totals?.requests ?? 0;
  return {
    available: requests > 0,
    requests,
    clientErrors: totals?.clientErrors ?? 0,
    serverErrors: totals?.serverErrors ?? 0,
    // Error rate counts server-side failures (5xx); 4xx are client mistakes reported separately.
    errorRate: requests > 0 ? totals!.serverErrors / requests : null,
    avgLatencyMs: requests > 0 ? Math.round(totals!.duration / requests) : null,
  };
}

export class AnalyticsService {
  async forApp(appId: Types.ObjectId, days: number, now = new Date()) {
    const to = now;
    const from = startOfUtcDay(new Date(now.getTime() - (days - 1) * DAY));

    const [total, newInRange, newByDayRows, byStatus, byPlatform, versions, lastSeenCount] = await Promise.all([
      AppUser.countDocuments({ appId }),
      AppUser.countDocuments({ appId, createdAt: { $gte: from } }),
      AppUser.aggregate<{ _id: string; count: number }>([
        { $match: { appId, createdAt: { $gte: from } } },
        { $group: { _id: { $dateToString: { format: '%Y-%m-%d', date: '$createdAt' } }, count: { $sum: 1 } } },
      ]),
      AppUser.aggregate<{ _id: string; count: number }>([
        { $match: { appId } },
        { $group: { _id: '$status', count: { $sum: 1 } } },
      ]),
      AppUser.aggregate<{ _id: string | null; count: number }>([
        { $match: { appId } },
        { $group: { _id: '$platform', count: { $sum: 1 } } },
      ]),
      AppUser.aggregate<{ _id: { platform: string | null; appVersion: string }; count: number }>([
        { $match: { appId, appVersion: { $ne: null } } },
        { $group: { _id: { platform: '$platform', appVersion: '$appVersion' }, count: { $sum: 1 } } },
        { $sort: { count: -1 } },
        { $limit: 50 },
      ]),
      AppUser.countDocuments({ appId, lastSeenAt: { $ne: null } }),
    ]);

    const activityAvailable = lastSeenCount > 0;
    const [dau, wau, mau, activeByDayRows] = activityAvailable
      ? await Promise.all([
          AppUser.countDocuments({ appId, lastSeenAt: { $gte: new Date(now.getTime() - DAY) } }),
          AppUser.countDocuments({ appId, lastSeenAt: { $gte: new Date(now.getTime() - 7 * DAY) } }),
          AppUser.countDocuments({ appId, lastSeenAt: { $gte: new Date(now.getTime() - 30 * DAY) } }),
          AppUserEvent.aggregate<{ _id: string; count: number }>([
            { $match: { appId, occurredAt: { $gte: from, $lte: to } } },
            { $group: { _id: { d: { $dateToString: { format: '%Y-%m-%d', date: '$occurredAt' } }, u: '$appUserId' } } },
            { $group: { _id: '$_id.d', count: { $sum: 1 } } },
          ]),
        ])
      : [null, null, null, []];

    const apiByDayRows = await ApiMetric.aggregate<{ _id: string; requests: number; errors: number }>([
      { $match: { appId, bucket: { $gte: from } } },
      {
        $group: {
          _id: { $dateToString: { format: '%Y-%m-%d', date: '$bucket' } },
          requests: { $sum: '$count' },
          errors: { $sum: '$serverErrors' },
        },
      },
    ]);
    const topRoutes = await ApiMetric.aggregate<{ _id: { route: string; method: string }; requests: number; errors: number }>([
      { $match: { appId, bucket: { $gte: from } } },
      {
        $group: { _id: { route: '$route', method: '$method' }, requests: { $sum: '$count' }, errors: { $sum: '$serverErrors' } },
      },
      { $sort: { requests: -1 } },
      { $limit: 10 },
    ]);
    const api = await apiMetricsSummary({ appId }, from);

    const campaignRows = await NotificationCampaign.aggregate<{ _id: string; count: number; sent: number; failed: number }>([
      { $match: { appId } },
      { $group: { _id: '$status', count: { $sum: 1 }, sent: { $sum: '$stats.sent' }, failed: { $sum: '$stats.failed' } } },
    ]);

    return {
      range: { from, to, days },
      users: {
        total,
        newInRange,
        newByDay: series(from, days, new Map(newByDayRows.map((r) => [r._id, { count: r.count }])), { count: 0 }),
        byStatus: Object.fromEntries(byStatus.map((r) => [r._id, r.count])),
        byPlatform: byPlatform.map((r) => ({ platform: r._id ?? 'unknown', count: r.count })),
      },
      activity: {
        available: activityAvailable,
        dau,
        wau,
        mau,
        activeByDay: activityAvailable
          ? series(from, days, new Map(activeByDayRows.map((r) => [r._id, { count: r.count }])), { count: 0 })
          : [],
      },
      versions: {
        available: versions.length > 0,
        distribution: versions.map((v) => ({
          platform: v._id.platform ?? 'unknown',
          appVersion: v._id.appVersion,
          count: v.count,
        })),
      },
      api: {
        ...api,
        byDay: series(from, days, new Map(apiByDayRows.map((r) => [r._id, { requests: r.requests, errors: r.errors }])), {
          requests: 0,
          errors: 0,
        }),
        topRoutes: topRoutes.map((r) => ({ route: r._id.route, method: r._id.method, requests: r.requests, errors: r.errors })),
      },
      campaigns: {
        total: campaignRows.reduce((s, r) => s + r.count, 0),
        byStatus: Object.fromEntries(campaignRows.map((r) => [r._id, r.count])),
        delivered: campaignRows.reduce((s, r) => s + r.sent, 0),
        failed: campaignRows.reduce((s, r) => s + r.failed, 0),
      },
    };
  }
}
