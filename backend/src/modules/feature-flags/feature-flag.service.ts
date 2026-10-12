import type { Types } from 'mongoose';
import { conflict, isDuplicateKeyError, notFound } from '../../shared/errors.js';
import { escapeRegex } from '../../shared/pagination.js';
import { FeatureFlag } from './feature-flag.model.js';

type FlagInput = {
  description?: string;
  enabled?: boolean;
  rolloutPercentage?: number;
  platforms?: ('android' | 'ios')[];
  minAppVersion?: string | null;
};

export class FeatureFlagService {
  list(appId: Types.ObjectId, q: { search?: string; enabled?: boolean }) {
    const filter: Record<string, unknown> = { appId };
    if (q.search) filter.key = { $regex: escapeRegex(q.search), $options: 'i' };
    if (q.enabled !== undefined) filter.enabled = q.enabled;
    return FeatureFlag.find(filter).sort({ key: 1 }).limit(500);
  }

  async create(appId: Types.ObjectId, orgId: Types.ObjectId, adminId: Types.ObjectId, input: FlagInput & { key: string }) {
    try {
      return await FeatureFlag.create({ ...input, appId, orgId, updatedBy: adminId });
    } catch (err) {
      if (isDuplicateKeyError(err)) throw conflict(`A feature flag with key "${input.key}" already exists`, { fields: ['key'] });
      throw err;
    }
  }

  async update(appId: Types.ObjectId, key: string, adminId: Types.ObjectId, patch: FlagInput) {
    const flag = await FeatureFlag.findOne({ appId, key });
    if (!flag) throw notFound('Feature flag');
    const before = flag.toJSON();
    flag.set({ ...patch, updatedBy: adminId });
    await flag.save();
    return { flag, before };
  }

  async remove(appId: Types.ObjectId, key: string) {
    const flag = await FeatureFlag.findOneAndDelete({ appId, key });
    if (!flag) throw notFound('Feature flag');
    return flag;
  }
}
