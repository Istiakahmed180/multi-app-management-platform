import type { Types } from 'mongoose';
import { conflict, isDuplicateKeyError, notFound, AppError } from '../../shared/errors.js';
import { escapeRegex, pageMeta, skip, type PaginationQuery } from '../../shared/pagination.js';
import { AppUser } from '../app-users/app-user.models.js';
import { Integration } from '../integrations/integration.model.js';
import { audienceFilter } from './audience.js';
import { NotificationCampaign } from './campaign.model.js';
import type { Audience } from './campaign.schemas.js';

type CampaignInput = {
  name: string;
  title: string;
  body: string;
  imageUrl: string | null;
  data: Record<string, string>;
  audience: Audience;
  scheduledAt?: string;
};

export class CampaignService {
  async list(appId: Types.ObjectId, q: PaginationQuery & { status?: string; search?: string }) {
    const filter: Record<string, unknown> = { appId };
    if (q.status) filter.status = q.status;
    if (q.search) filter.name = { $regex: escapeRegex(q.search), $options: 'i' };
    const [items, total] = await Promise.all([
      NotificationCampaign.find(filter).sort({ createdAt: -1, _id: -1 }).skip(skip(q)).limit(q.pageSize),
      NotificationCampaign.countDocuments(filter),
    ]);
    return { items: items.map((c) => c.toJSON()), meta: pageMeta(q, total) };
  }

  async get(appId: Types.ObjectId, id: string) {
    const c = await NotificationCampaign.findOne({ _id: id, appId });
    if (!c) throw notFound('Campaign');
    return c;
  }

  private async assertPushConfigured(appId: Types.ObjectId) {
    if (!(await Integration.exists({ appId, type: 'fcm', status: 'active' }))) {
      throw new AppError('not_configured', 'Configure Firebase Cloud Messaging for this app before scheduling campaigns');
    }
  }

  private static scheduleTime(raw?: string): Date {
    const now = Date.now();
    const at = raw ? new Date(raw) : new Date(now);
    if (at.getTime() < now - 60_000) {
      throw new AppError('validation_failed', 'Request validation failed', [
        { path: 'scheduledAt', message: 'Must not be in the past' },
      ]);
    }
    if (at.getTime() > now + 365 * 86_400_000) {
      throw new AppError('validation_failed', 'Request validation failed', [
        { path: 'scheduledAt', message: 'Must be within one year' },
      ]);
    }
    return at;
  }

  /** Returns `replayed: true` when the Idempotency-Key matched an existing campaign. */
  async create(
    appId: Types.ObjectId,
    orgId: Types.ObjectId,
    adminId: Types.ObjectId,
    input: CampaignInput,
    idempotencyKey?: string,
  ) {
    if (idempotencyKey) {
      const existing = await NotificationCampaign.findOne({ appId, idempotencyKey });
      if (existing) return { campaign: existing, replayed: true };
    }
    const scheduled = input.scheduledAt !== undefined;
    if (scheduled) await this.assertPushConfigured(appId);
    try {
      const campaign = await NotificationCampaign.create({
        appId,
        orgId,
        name: input.name,
        title: input.title,
        body: input.body,
        imageUrl: input.imageUrl,
        data: input.data,
        audience: input.audience,
        status: scheduled ? 'scheduled' : 'draft',
        scheduledAt: scheduled ? CampaignService.scheduleTime(input.scheduledAt) : null,
        idempotencyKey: idempotencyKey ?? null,
        createdBy: adminId,
      });
      return { campaign, replayed: false };
    } catch (err) {
      if (idempotencyKey && isDuplicateKeyError(err)) {
        const existing = await NotificationCampaign.findOne({ appId, idempotencyKey });
        if (existing) return { campaign: existing, replayed: true };
      }
      throw err;
    }
  }

  async update(appId: Types.ObjectId, id: string, patch: Partial<CampaignInput>) {
    const c = await this.get(appId, id);
    if (c.status !== 'draft') throw conflict('Only draft campaigns can be edited');
    c.set(patch);
    await c.save();
    return c;
  }

  async schedule(appId: Types.ObjectId, id: string, scheduledAt?: string) {
    const at = CampaignService.scheduleTime(scheduledAt);
    await this.get(appId, id);
    await this.assertPushConfigured(appId);
    // Status-guarded update so a campaign can only be scheduled from draft/scheduled.
    const c = await NotificationCampaign.findOneAndUpdate(
      { _id: id, appId, status: { $in: ['draft', 'scheduled'] } },
      { $set: { status: 'scheduled', scheduledAt: at } },
      { returnDocument: 'after' },
    );
    if (!c) throw conflict('Only draft or scheduled campaigns can be scheduled');
    return c;
  }

  async cancel(appId: Types.ObjectId, id: string, adminId: Types.ObjectId) {
    await this.get(appId, id);
    const c = await NotificationCampaign.findOneAndUpdate(
      { _id: id, appId, status: { $in: ['draft', 'scheduled'] } },
      { $set: { status: 'cancelled', cancelledAt: new Date(), cancelledBy: adminId } },
      { returnDocument: 'after' },
    );
    if (!c) throw conflict('Only draft or scheduled campaigns can be cancelled');
    return c;
  }

  async estimate(appId: Types.ObjectId, audience: Audience) {
    const [eligibleUsers, totalUsers] = await Promise.all([
      AppUser.countDocuments(audienceFilter(appId, audience)),
      AppUser.countDocuments({ appId }),
    ]);
    return { eligibleUsers, totalUsers };
  }

  async stats(appId: Types.ObjectId) {
    const rows = await NotificationCampaign.aggregate<{ _id: string; n: number; sent: number; failed: number }>([
      { $match: { appId } },
      { $group: { _id: '$status', n: { $sum: 1 }, sent: { $sum: '$stats.sent' }, failed: { $sum: '$stats.failed' } } },
    ]);
    return rows;
  }
}
