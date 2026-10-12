import type { Types } from 'mongoose';
import { notFound } from '../../shared/errors.js';
import { AppUser, AppUserEvent } from '../app-users/app-user.models.js';

type UpsertInput = {
  email?: string | null;
  displayName?: string | null;
  platform?: 'android' | 'ios' | null;
  appVersion?: string | null;
  locale?: string | null;
  pushOptIn?: boolean;
  pushTokens?: { token: string; platform: 'android' | 'ios' }[];
  attributes?: Record<string, string | number | boolean | null>;
  lastSeenAt?: string;
};

type EventInput = {
  externalUserId: string;
  type: string;
  occurredAt: string;
  platform?: 'android' | 'ios' | null;
  appVersion?: string | null;
  properties?: Record<string, string | number | boolean | null>;
};

export class IngestService {
  async upsertUser(appId: Types.ObjectId, orgId: Types.ObjectId, externalUserId: string, input: UpsertInput) {
    const set: Record<string, unknown> = {};
    for (const k of ['email', 'displayName', 'platform', 'appVersion', 'locale', 'pushOptIn'] as const) {
      if (input[k] !== undefined) set[k] = input[k];
    }
    if (input.pushTokens) set.pushTokens = input.pushTokens.map((t) => ({ ...t, updatedAt: new Date() }));
    if (input.lastSeenAt) set.lastSeenAt = new Date(input.lastSeenAt);
    if (input.attributes) {
      for (const [k, v] of Object.entries(input.attributes)) set[`attributes.${k}`] = v;
    }
    const before = await AppUser.exists({ appId, externalUserId });
    const user = await AppUser.findOneAndUpdate(
      { appId, externalUserId },
      { $set: set, $setOnInsert: { orgId, firstSeenAt: new Date() } },
      { upsert: true, returnDocument: 'after', runValidators: true },
    );
    return { user: user!, created: !before };
  }

  async status(appId: Types.ObjectId, externalUserId: string) {
    const user = await AppUser.findOne({ appId, externalUserId }).select('status statusReason statusChangedAt').lean();
    if (!user) throw notFound('User');
    return { externalUserId, status: user.status, reason: user.statusReason, changedAt: user.statusChangedAt };
  }

  async deleteUser(appId: Types.ObjectId, externalUserId: string) {
    const user = await AppUser.findOneAndDelete({ appId, externalUserId });
    if (!user) throw notFound('User');
    const events = await AppUserEvent.deleteMany({ appId, appUserId: user._id });
    return { deletedEvents: events.deletedCount };
  }

  async ingestEvents(appId: Types.ObjectId, orgId: Types.ObjectId, events: EventInput[]) {
    const ids = [...new Set(events.map((e) => e.externalUserId))];
    const users = await AppUser.find({ appId, externalUserId: { $in: ids } })
      .select('_id externalUserId')
      .lean();
    const byExternal = new Map(users.map((u) => [u.externalUserId, u._id]));
    const accepted = events.filter((e) => byExternal.has(e.externalUserId));
    if (accepted.length > 0) {
      await AppUserEvent.insertMany(
        accepted.map((e) => ({
          appId,
          orgId,
          appUserId: byExternal.get(e.externalUserId)!,
          type: e.type,
          occurredAt: new Date(e.occurredAt),
          platform: e.platform ?? null,
          appVersion: e.appVersion ?? null,
          properties: e.properties ?? {},
        })),
        { ordered: false },
      );
      // Latest known platform/version comes from the newest event that carries it, applied
      // only if it is not older than what is already stored; then lastSeenAt advances.
      const latestSeen = new Map<string, EventInput>();
      const latestVersioned = new Map<string, EventInput>();
      for (const e of accepted) {
        const seen = latestSeen.get(e.externalUserId);
        if (!seen || e.occurredAt > seen.occurredAt) latestSeen.set(e.externalUserId, e);
        if (e.appVersion || e.platform) {
          const v = latestVersioned.get(e.externalUserId);
          if (!v || e.occurredAt > v.occurredAt) latestVersioned.set(e.externalUserId, e);
        }
      }
      const notNewerThan = (at: string) => ({ $or: [{ lastSeenAt: null }, { lastSeenAt: { $lte: new Date(at) } }] });
      const ops = [
        ...[...latestVersioned.values()].map((e) => ({
          updateOne: {
            filter: { appId, externalUserId: e.externalUserId, ...notNewerThan(e.occurredAt) },
            update: {
              $set: { ...(e.platform ? { platform: e.platform } : {}), ...(e.appVersion ? { appVersion: e.appVersion } : {}) },
            },
          },
        })),
        ...[...latestSeen.values()].map((e) => ({
          updateOne: {
            filter: { appId, externalUserId: e.externalUserId, ...notNewerThan(e.occurredAt) },
            update: { $set: { lastSeenAt: new Date(e.occurredAt) } },
          },
        })),
      ];
      await AppUser.bulkWrite(ops, { ordered: true });
    }
    return {
      accepted: accepted.length,
      rejected: events.length - accepted.length,
      unknownUsers: ids.filter((id) => !byExternal.has(id)),
    };
  }
}
