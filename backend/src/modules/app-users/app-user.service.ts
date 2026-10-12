import type { Types } from 'mongoose';
import { isObjectId } from '../../shared/db.js';
import { conflict, notFound } from '../../shared/errors.js';
import { escapeRegex, pageMeta, skip, type PaginationQuery } from '../../shared/pagination.js';
import type { IntegrationService } from '../integrations/integration.service.js';
import { AppUser, AppUserEvent } from './app-user.models.js';

interface ListQuery extends PaginationQuery {
  search?: string;
  status?: string;
  platform?: string;
  appVersion?: string;
  sort: Record<string, 1 | -1>;
}

export class AppUserService {
  constructor(private readonly integrations: IntegrationService) {}

  async list(appId: Types.ObjectId, q: ListQuery) {
    const filter: Record<string, unknown> = { appId };
    if (q.status) filter.status = q.status;
    if (q.platform) filter.platform = q.platform;
    if (q.appVersion) filter.appVersion = q.appVersion;
    if (q.search) {
      // Prefix match keeps the query index-friendly on {appId, email}.
      const rx = { $regex: `^${escapeRegex(q.search)}`, $options: 'i' };
      filter.$or = [{ email: rx }, { externalUserId: rx }, { displayName: rx }];
    }
    const [items, total] = await Promise.all([
      AppUser.find(filter).sort(q.sort).skip(skip(q)).limit(q.pageSize),
      AppUser.countDocuments(filter),
    ]);
    return { items: items.map((u) => u.toJSON()), meta: pageMeta(q, total) };
  }

  private async find(appId: Types.ObjectId, userId: string) {
    // Always scoped by appId, so a user id from another app resolves to 404.
    const user = isObjectId(userId) ? await AppUser.findOne({ _id: userId, appId }) : null;
    if (!user) throw notFound('User');
    return user;
  }

  async get(appId: Types.ObjectId, userId: string) {
    const user = await this.find(appId, userId);
    const [recentActivity, eventCount] = await Promise.all([
      AppUserEvent.find({ appId, appUserId: user._id }).sort({ occurredAt: -1 }).limit(20).lean(),
      AppUserEvent.countDocuments({ appId, appUserId: user._id }),
    ]);
    return {
      ...user.toJSON(),
      activity: {
        available: eventCount > 0,
        total: eventCount,
        recent: recentActivity.map((e) => ({
          id: String(e._id),
          type: e.type,
          occurredAt: e.occurredAt,
          platform: e.platform,
          appVersion: e.appVersion,
          properties: e.properties,
        })),
      },
    };
  }

  async activity(appId: Types.ObjectId, userId: string, q: PaginationQuery) {
    const user = await this.find(appId, userId);
    const filter = { appId, appUserId: user._id };
    const [items, total] = await Promise.all([
      AppUserEvent.find(filter).sort({ occurredAt: -1 }).skip(skip(q)).limit(q.pageSize).lean(),
      AppUserEvent.countDocuments(filter),
    ]);
    return {
      items: items.map((e) => ({
        id: String(e._id),
        type: e.type,
        occurredAt: e.occurredAt,
        platform: e.platform,
        appVersion: e.appVersion,
        properties: e.properties,
      })),
      meta: pageMeta(q, total),
    };
  }

  async setStatus(
    appId: Types.ObjectId,
    userId: string,
    adminId: Types.ObjectId,
    status: 'active' | 'suspended',
    reason?: string,
  ) {
    const user = await this.find(appId, userId);
    if (user.status === status) throw conflict(`User is already ${status}`);
    const previous = user.status;
    user.status = status;
    user.statusReason = reason ?? null;
    user.statusChangedAt = new Date();
    user.statusChangedBy = adminId;
    await user.save();
    // Enforcement lives in the app's own backend; notify it when a webhook is configured.
    const delivery = await this.integrations.deliverWebhook(appId, 'user.status_changed', {
      externalUserId: user.externalUserId,
      status,
      previousStatus: previous,
      reason: reason ?? null,
      changedAt: user.statusChangedAt.toISOString(),
    });
    return {
      user,
      previous,
      propagation: delivery
        ? { attempted: true, delivered: delivery.ok, httpStatus: delivery.status, error: delivery.error ?? null }
        : {
            attempted: false,
            delivered: false,
            httpStatus: null,
            error: 'No webhook configured; the change is recorded in the registry and exposed via the ingest status API only.',
          },
    };
  }
}
