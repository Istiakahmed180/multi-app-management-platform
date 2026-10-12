import { Schema, model, type InferSchemaType } from 'mongoose';
import { APP_PLATFORMS } from '../apps/app.model.js';

const featureFlagSchema = new Schema(
  {
    appId: { type: Schema.Types.ObjectId, ref: 'App', required: true },
    orgId: { type: Schema.Types.ObjectId, ref: 'Organization', required: true },
    key: { type: String, required: true, match: /^[a-z][a-z0-9_.-]{0,63}$/, immutable: true },
    description: { type: String, default: '', maxlength: 500 },
    enabled: { type: Boolean, default: false },
    // Percentage of installs (0-100) that see the feature when enabled.
    rolloutPercentage: { type: Number, min: 0, max: 100, default: 100 },
    // Empty = all platforms.
    platforms: { type: [{ type: String, enum: APP_PLATFORMS }], default: [] },
    minAppVersion: { type: String, default: null },
    updatedBy: { type: Schema.Types.ObjectId, ref: 'Admin', default: null },
  },
  { timestamps: true },
);
featureFlagSchema.index({ appId: 1, key: 1 }, { unique: true });

export type FeatureFlagAttrs = InferSchemaType<typeof featureFlagSchema>;
export const FeatureFlag = model('FeatureFlag', featureFlagSchema);
