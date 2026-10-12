import { Schema, model, type InferSchemaType } from 'mongoose';
import { APP_PLATFORMS } from '../apps/app.model.js';

const pushTokenSchema = new Schema(
  {
    token: { type: String, required: true, maxlength: 4096 },
    platform: { type: String, enum: APP_PLATFORMS, required: true },
    updatedAt: { type: Date, default: () => new Date() },
  },
  { _id: false },
);

/**
 * The platform's registry of an app's end users. This is NOT the app's own user
 * database; records arrive only through the authenticated server ingest API.
 */
const appUserSchema = new Schema(
  {
    appId: { type: Schema.Types.ObjectId, ref: 'App', required: true },
    orgId: { type: Schema.Types.ObjectId, ref: 'Organization', required: true },
    externalUserId: { type: String, required: true, maxlength: 128 },
    email: { type: String, default: null, lowercase: true, trim: true, maxlength: 254 },
    displayName: { type: String, default: null, maxlength: 120 },
    status: { type: String, enum: ['active', 'suspended'], default: 'active' },
    statusReason: { type: String, default: null, maxlength: 500 },
    statusChangedAt: { type: Date, default: null },
    statusChangedBy: { type: Schema.Types.ObjectId, ref: 'Admin', default: null },
    platform: { type: String, enum: [...APP_PLATFORMS, null], default: null },
    appVersion: { type: String, default: null, maxlength: 32 },
    locale: { type: String, default: null, maxlength: 16 },
    pushOptIn: { type: Boolean, default: false },
    pushTokens: { type: [pushTokenSchema], default: [] },
    attributes: { type: Map, of: Schema.Types.Mixed, default: {} },
    firstSeenAt: { type: Date, default: () => new Date() },
    lastSeenAt: { type: Date, default: null },
  },
  { timestamps: true },
);
appUserSchema.index({ appId: 1, externalUserId: 1 }, { unique: true });
appUserSchema.index({ appId: 1, createdAt: -1 });
appUserSchema.index({ appId: 1, lastSeenAt: -1 });
appUserSchema.index({ appId: 1, status: 1, createdAt: -1 });
appUserSchema.index({ appId: 1, platform: 1, appVersion: 1 });
appUserSchema.index({ appId: 1, email: 1 });

appUserSchema.set('toJSON', {
  versionKey: false,
  flattenMaps: true,
  transform: (_doc, ret: Record<string, unknown>) => {
    ret.id = String(ret._id);
    delete ret._id;
    // Raw push tokens are device identifiers; only expose counts.
    const tokens = (ret.pushTokens as { platform: string }[] | undefined) ?? [];
    ret.pushTokenCount = tokens.length;
    delete ret.pushTokens;
    return ret;
  },
});

export type AppUserAttrs = InferSchemaType<typeof appUserSchema>;
export const AppUser = model('AppUser', appUserSchema);

const appUserEventSchema = new Schema(
  {
    appId: { type: Schema.Types.ObjectId, ref: 'App', required: true },
    orgId: { type: Schema.Types.ObjectId, ref: 'Organization', required: true },
    appUserId: { type: Schema.Types.ObjectId, ref: 'AppUser', required: true },
    type: { type: String, required: true, match: /^[a-z][a-z0-9_.]{0,63}$/ },
    occurredAt: { type: Date, required: true },
    platform: { type: String, enum: [...APP_PLATFORMS, null], default: null },
    appVersion: { type: String, default: null, maxlength: 32 },
    properties: { type: Schema.Types.Mixed, default: {} },
  },
  { timestamps: { createdAt: true, updatedAt: false } },
);
appUserEventSchema.index({ appId: 1, appUserId: 1, occurredAt: -1 });
appUserEventSchema.index({ appId: 1, occurredAt: -1 });
appUserEventSchema.index({ occurredAt: 1 });

export const AppUserEvent = model('AppUserEvent', appUserEventSchema);
