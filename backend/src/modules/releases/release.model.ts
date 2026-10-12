import { Schema, model, type InferSchemaType } from 'mongoose';
import { APP_PLATFORMS } from '../apps/app.model.js';

export const RELEASE_STATUSES = ['planned', 'in_review', 'rolling_out', 'released', 'halted'] as const;

/**
 * Release metadata and history. This module does not distribute binaries; store
 * submission happens through the stores' own tooling.
 */
const releaseSchema = new Schema(
  {
    appId: { type: Schema.Types.ObjectId, ref: 'App', required: true },
    orgId: { type: Schema.Types.ObjectId, ref: 'Organization', required: true },
    platform: { type: String, enum: APP_PLATFORMS, required: true },
    version: { type: String, required: true, maxlength: 32 },
    buildNumber: { type: Number, required: true, min: 0 },
    releaseNotes: { type: String, default: '', maxlength: 5000 },
    status: { type: String, enum: RELEASE_STATUSES, default: 'planned' },
    // Staged rollout percentage as configured in the store (informational).
    rolloutPercentage: { type: Number, min: 0, max: 100, default: 100 },
    isMandatory: { type: Boolean, default: false },
    storeUrl: { type: String, default: null, maxlength: 2048 },
    releasedAt: { type: Date, default: null },
    createdBy: { type: Schema.Types.ObjectId, ref: 'Admin', required: true },
    updatedBy: { type: Schema.Types.ObjectId, ref: 'Admin', default: null },
  },
  { timestamps: true },
);
releaseSchema.index({ appId: 1, platform: 1, version: 1 }, { unique: true });
releaseSchema.index({ appId: 1, createdAt: -1 });

export type ReleaseAttrs = InferSchemaType<typeof releaseSchema>;
export const AppRelease = model('AppRelease', releaseSchema);
