import { Schema, model, type InferSchemaType } from 'mongoose';
import { APP_PLATFORMS } from '../apps/app.model.js';

export const CAMPAIGN_STATUSES = ['draft', 'scheduled', 'sending', 'sent', 'partially_failed', 'failed', 'cancelled'] as const;
export type CampaignStatus = (typeof CAMPAIGN_STATUSES)[number];
export const AUDIENCE_TYPES = ['all', 'platform', 'active_recently', 'users'] as const;

const campaignSchema = new Schema(
  {
    appId: { type: Schema.Types.ObjectId, ref: 'App', required: true },
    orgId: { type: Schema.Types.ObjectId, ref: 'Organization', required: true },
    name: { type: String, required: true, maxlength: 120 },
    title: { type: String, required: true, maxlength: 120 },
    body: { type: String, required: true, maxlength: 1000 },
    imageUrl: { type: String, default: null, maxlength: 2048 },
    data: { type: Map, of: String, default: {} },
    audience: {
      type: { type: String, enum: AUDIENCE_TYPES, required: true },
      platforms: { type: [{ type: String, enum: APP_PLATFORMS }], default: [] },
      activeWithinDays: { type: Number, default: null },
      externalUserIds: { type: [String], default: [] },
    },
    status: { type: String, enum: CAMPAIGN_STATUSES, default: 'draft' },
    scheduledAt: { type: Date, default: null },
    startedAt: { type: Date, default: null },
    completedAt: { type: Date, default: null },
    cancelledAt: { type: Date, default: null },
    cancelledBy: { type: Schema.Types.ObjectId, ref: 'Admin', default: null },
    idempotencyKey: { type: String, default: null, maxlength: 128 },
    stats: {
      targeted: { type: Number, default: 0 },
      sent: { type: Number, default: 0 },
      failed: { type: Number, default: 0 },
      invalidTokens: { type: Number, default: 0 },
    },
    errorSummary: { type: Map, of: Number, default: {} },
    lastError: { type: String, default: null, maxlength: 1000 },
    attempts: { type: Number, default: 0 },
    // Worker lease + resume cursor (last AppUser _id processed) for crash-safe, non-duplicating sends.
    lockedUntil: { type: Date, default: null },
    cursor: { type: Schema.Types.ObjectId, default: null },
    createdBy: { type: Schema.Types.ObjectId, ref: 'Admin', required: true },
  },
  { timestamps: true },
);
campaignSchema.index({ appId: 1, createdAt: -1 });
campaignSchema.index({ appId: 1, status: 1, createdAt: -1 });
campaignSchema.index({ status: 1, scheduledAt: 1 });
campaignSchema.index(
  { appId: 1, idempotencyKey: 1 },
  { unique: true, partialFilterExpression: { idempotencyKey: { $type: 'string' } } },
);

campaignSchema.set('toJSON', {
  versionKey: false,
  flattenMaps: true,
  transform: (_doc, ret: Record<string, unknown>) => {
    ret.id = String(ret._id);
    delete ret._id;
    delete ret.lockedUntil;
    delete ret.cursor;
    return ret;
  },
});

export type CampaignAttrs = InferSchemaType<typeof campaignSchema>;
export const NotificationCampaign = model('NotificationCampaign', campaignSchema);
