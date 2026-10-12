import { createHash } from 'node:crypto';
import { isDeepStrictEqual } from 'node:util';
import type { Types } from 'mongoose';
import { AppError, conflict, isDuplicateKeyError, notFound } from '../../shared/errors.js';
import { pageMeta, skip, type PaginationQuery } from '../../shared/pagination.js';
import { App } from '../apps/app.model.js';
import { Admin } from '../auth/auth.models.js';
import { FeatureFlag } from '../feature-flags/feature-flag.model.js';
import { configContentSchema, toPublicConfig, type ConfigContent } from './config.content.js';
import { AppConfig } from './config.model.js';

export const PUBLIC_SCHEMA_VERSION = 1;

export class ConfigService {
  private async draft(appId: Types.ObjectId) {
    const draft = await AppConfig.findOne({ appId, state: 'draft' });
    if (!draft) throw notFound('Draft configuration');
    return draft;
  }

  private latestPublished(appId: Types.ObjectId) {
    return AppConfig.findOne({ appId, state: 'published' }).sort({ version: -1 });
  }

  async overview(appId: Types.ObjectId, q: PaginationQuery) {
    const [draft, current, versions, total] = await Promise.all([
      this.draft(appId),
      this.latestPublished(appId).lean(),
      AppConfig.find({ appId, state: 'published' })
        .select('version publishedAt publishedBy changeNote rollbackOfVersion')
        .sort({ version: -1 })
        .skip(skip(q))
        .limit(q.pageSize)
        .lean(),
      AppConfig.countDocuments({ appId, state: 'published' }),
    ]);
    const adminIds = [...versions.map((v) => v.publishedBy), draft.updatedBy].filter(Boolean) as Types.ObjectId[];
    const admins = await Admin.find({ _id: { $in: adminIds } })
      .select('email name')
      .lean();
    const who = new Map(admins.map((a) => [String(a._id), { id: String(a._id), email: a.email, name: a.name }]));
    return {
      data: {
        draft: {
          content: draft.content as ConfigContent,
          updatedAt: draft.updatedAt,
          updatedBy: draft.updatedBy ? (who.get(String(draft.updatedBy)) ?? null) : null,
          baseVersion: draft.baseVersion,
          hasUnpublishedChanges: !current || !isDeepStrictEqual(draft.content, current.content),
        },
        current: current ? { version: current.version, publishedAt: current.publishedAt } : null,
        versions: versions.map((v) => ({
          version: v.version,
          publishedAt: v.publishedAt,
          publishedBy: v.publishedBy ? (who.get(String(v.publishedBy)) ?? null) : null,
          changeNote: v.changeNote,
          rollbackOfVersion: v.rollbackOfVersion,
          isCurrent: current?.version === v.version,
        })),
      },
      meta: pageMeta(q, total),
    };
  }

  async getVersion(appId: Types.ObjectId, version: number) {
    const v = await AppConfig.findOne({ appId, state: 'published', version }).lean();
    if (!v) throw notFound('Configuration version');
    return {
      version: v.version,
      content: v.content as ConfigContent,
      publishedAt: v.publishedAt,
      changeNote: v.changeNote,
      rollbackOfVersion: v.rollbackOfVersion,
    };
  }

  async saveDraft(appId: Types.ObjectId, adminId: Types.ObjectId, content: ConfigContent, expectedUpdatedAt?: string) {
    const filter: Record<string, unknown> = { appId, state: 'draft' };
    if (expectedUpdatedAt) filter.updatedAt = new Date(expectedUpdatedAt);
    const updated = await AppConfig.findOneAndUpdate(
      filter,
      { $set: { content, updatedBy: adminId } },
      { returnDocument: 'after' },
    );
    if (!updated) {
      if (expectedUpdatedAt && (await AppConfig.exists({ appId, state: 'draft' }))) {
        throw conflict('The draft was modified by someone else. Reload and re-apply your changes.');
      }
      throw notFound('Draft configuration');
    }
    return updated;
  }

  private async insertPublished(
    appId: Types.ObjectId,
    orgId: Types.ObjectId,
    adminId: Types.ObjectId,
    content: ConfigContent,
    changeNote: string,
    rollbackOfVersion: number | null,
  ) {
    // The unique {appId, version} index arbitrates concurrent publishes; retry on collision.
    for (let attempt = 0; attempt < 3; attempt++) {
      const latest = await this.latestPublished(appId).select('version').lean();
      const version = (latest?.version ?? 0) + 1;
      try {
        const doc = await AppConfig.create({
          appId,
          orgId,
          state: 'published',
          version,
          content,
          changeNote,
          rollbackOfVersion,
          publishedAt: new Date(),
          publishedBy: adminId,
          updatedBy: adminId,
        });
        await App.updateOne(
          { _id: appId, $or: [{ publishedConfigVersion: null }, { publishedConfigVersion: { $lt: version } }] },
          { $set: { publishedConfigVersion: version } },
        );
        await AppConfig.updateOne({ appId, state: 'draft' }, { $set: { baseVersion: version } });
        return doc;
      } catch (err) {
        if (!isDuplicateKeyError(err) || attempt === 2) throw err;
      }
    }
    throw conflict('Could not publish due to concurrent changes. Try again.');
  }

  async publish(appId: Types.ObjectId, orgId: Types.ObjectId, adminId: Types.ObjectId, changeNote: string) {
    const draft = await this.draft(appId);
    // Re-validate: the schema may have evolved since the draft was saved.
    const parsed = configContentSchema.safeParse(draft.content);
    if (!parsed.success) {
      throw new AppError(
        'validation_failed',
        'The draft is not valid and cannot be published',
        parsed.error.issues.map((i) => ({ path: `content.${i.path.join('.')}`, message: i.message })),
      );
    }
    const current = await this.latestPublished(appId).lean();
    if (current && isDeepStrictEqual(current.content, parsed.data)) {
      throw conflict('The draft has no changes compared to the published version');
    }
    return this.insertPublished(appId, orgId, adminId, parsed.data, changeNote, null);
  }

  /** Publishes a new version with the content of an earlier one and resets the draft to it. */
  async rollback(appId: Types.ObjectId, orgId: Types.ObjectId, adminId: Types.ObjectId, version: number, changeNote: string) {
    const target = await AppConfig.findOne({ appId, state: 'published', version }).lean();
    if (!target) throw notFound('Configuration version');
    const current = await this.latestPublished(appId).lean();
    if (current?.version === version) throw conflict('This version is already the current configuration');
    const content = target.content as ConfigContent;
    const doc = await this.insertPublished(appId, orgId, adminId, content, changeNote || `Rollback to v${version}`, version);
    await AppConfig.updateOne({ appId, state: 'draft' }, { $set: { content, updatedBy: adminId } });
    return doc;
  }

  /** Builds the public payload. Returns null when the app is not serving config. */
  async buildPublic(appKey: string, platform?: 'android' | 'ios') {
    const app = await App.findOne({ appKey }).select('_id orgId status platforms').lean();
    if (!app || app.status !== 'active') return null;
    const published = await this.latestPublished(app._id).lean();
    if (!published) return { app, payload: null };
    const flags = await FeatureFlag.find({ appId: app._id, enabled: true }).sort({ key: 1 }).lean();
    const features = Object.fromEntries(
      flags
        .filter((f) => !platform || f.platforms.length === 0 || f.platforms.includes(platform))
        .map((f) => [
          f.key,
          {
            enabled: true,
            rolloutPercentage: f.rolloutPercentage,
            platforms: f.platforms,
            minAppVersion: f.minAppVersion,
          },
        ]),
    );
    const payload = {
      schemaVersion: PUBLIC_SCHEMA_VERSION,
      appKey,
      configVersion: published.version,
      publishedAt: published.publishedAt,
      config: toPublicConfig(published.content as ConfigContent),
      features,
    };
    const body = JSON.stringify(payload);
    const etag = `"v${published.version}-${createHash('sha256').update(body).digest('base64url').slice(0, 16)}"`;
    return { app, payload: { body, etag } };
  }
}
