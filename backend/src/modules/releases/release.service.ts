import type { Types } from 'mongoose';
import { conflict, isDuplicateKeyError, notFound } from '../../shared/errors.js';
import { pageMeta, skip, type PaginationQuery } from '../../shared/pagination.js';
import type { ConfigContent } from '../configurations/config.content.js';
import { AppConfig } from '../configurations/config.model.js';
import { App } from '../apps/app.model.js';
import { AppRelease, RELEASE_STATUSES } from './release.model.js';

type ReleaseInput = {
  platform: 'android' | 'ios';
  version: string;
  buildNumber: number;
  releaseNotes: string;
  status: (typeof RELEASE_STATUSES)[number];
  rolloutPercentage: number;
  isMandatory: boolean;
  storeUrl: string | null;
};

export class ReleaseService {
  async list(appId: Types.ObjectId, q: PaginationQuery & { platform?: string; status?: string }) {
    const filter: Record<string, unknown> = { appId };
    if (q.platform) filter.platform = q.platform;
    if (q.status) filter.status = q.status;
    const [items, total] = await Promise.all([
      AppRelease.find(filter).sort({ createdAt: -1, _id: -1 }).skip(skip(q)).limit(q.pageSize),
      AppRelease.countDocuments(filter),
    ]);
    return { items: items.map((r) => r.toJSON()), meta: pageMeta(q, total) };
  }

  /** Current enforcement policy (from published config) next to the draft and the latest releases. */
  async summary(appId: Types.ObjectId) {
    const [published, draft, latest] = await Promise.all([
      AppConfig.findOne({ appId, state: 'published' }).sort({ version: -1 }).select('version content.updatePolicy').lean(),
      AppConfig.findOne({ appId, state: 'draft' }).select('content.updatePolicy').lean(),
      AppRelease.aggregate([
        { $match: { appId, status: 'released' } },
        { $sort: { releasedAt: -1, createdAt: -1 } },
        { $group: { _id: '$platform', release: { $first: '$$ROOT' } } },
      ]),
    ]);
    return {
      publishedPolicy: published
        ? { configVersion: published.version, ...(published.content as ConfigContent).updatePolicy }
        : null,
      draftPolicy: draft ? (draft.content as ConfigContent).updatePolicy : null,
      latestReleased: Object.fromEntries(
        latest.map((l: { _id: string; release: { version: string; buildNumber: number; releasedAt: Date } }) => [
          l._id,
          { version: l.release.version, buildNumber: l.release.buildNumber, releasedAt: l.release.releasedAt },
        ]),
      ),
    };
  }

  async create(appId: Types.ObjectId, orgId: Types.ObjectId, adminId: Types.ObjectId, input: ReleaseInput) {
    const app = await App.findById(appId).select('platforms').lean();
    if (app && !(app.platforms as string[]).includes(input.platform)) {
      throw conflict(`This app is not registered for ${input.platform}`);
    }
    try {
      return await AppRelease.create({
        ...input,
        appId,
        orgId,
        releasedAt: input.status === 'released' ? new Date() : null,
        createdBy: adminId,
      });
    } catch (err) {
      if (isDuplicateKeyError(err))
        throw conflict(`Release ${input.version} already exists for ${input.platform}`, { fields: ['version'] });
      throw err;
    }
  }

  async get(appId: Types.ObjectId, id: string) {
    const r = await AppRelease.findOne({ _id: id, appId });
    if (!r) throw notFound('Release');
    return r;
  }

  async update(appId: Types.ObjectId, id: string, adminId: Types.ObjectId, patch: Partial<ReleaseInput>) {
    const r = await this.get(appId, id);
    const previousStatus = r.status;
    r.set({ ...patch, updatedBy: adminId });
    if (patch.status === 'released' && previousStatus !== 'released') r.releasedAt = new Date();
    await r.save();
    return { release: r, previousStatus };
  }

  /**
   * Copies a release into the draft update policy. Nothing reaches clients until
   * the draft is published through the normal configuration workflow.
   */
  async applyToDraft(appId: Types.ObjectId, id: string, adminId: Types.ObjectId) {
    const r = await this.get(appId, id);
    const draft = await AppConfig.findOne({ appId, state: 'draft' });
    if (!draft) throw notFound('Draft configuration');
    const content = structuredClone(draft.content) as ConfigContent;
    const policy = content.updatePolicy[r.platform as 'android' | 'ios'];
    policy.latestVersion = r.version;
    if (r.isMandatory) policy.minimumVersion = r.version;
    if (r.storeUrl) policy.updateUrl = r.storeUrl;
    await AppConfig.updateOne({ _id: draft._id, state: 'draft' }, { $set: { content, updatedBy: adminId } });
    return content.updatePolicy;
  }
}
