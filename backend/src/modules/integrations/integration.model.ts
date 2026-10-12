import { Schema, model, type InferSchemaType } from 'mongoose';

export const INTEGRATION_TYPES = ['fcm', 'server_api_key', 'webhook'] as const;
export type IntegrationType = (typeof INTEGRATION_TYPES)[number];

const encryptedSchema = new Schema({ iv: String, tag: String, data: String }, { _id: false });

const integrationSchema = new Schema(
  {
    orgId: { type: Schema.Types.ObjectId, ref: 'Organization', required: true },
    appId: { type: Schema.Types.ObjectId, ref: 'App', required: true },
    type: { type: String, enum: INTEGRATION_TYPES, required: true },
    name: { type: String, required: true, maxlength: 120 },
    status: { type: String, enum: ['active', 'revoked'], default: 'active' },
    // Non-secret settings (e.g. FCM project id, webhook URL). Safe to return to the dashboard.
    publicConfig: { type: Schema.Types.Mixed, default: {} },
    // AES-256-GCM encrypted secret (FCM service account JSON, webhook signing secret).
    secret: { type: encryptedSchema, default: null, select: false },
    // Server API keys: only a hash and a display prefix are stored.
    keyHash: { type: String, default: null, select: false },
    keyPrefix: { type: String, default: null },
    lastUsedAt: { type: Date, default: null },
    lastDeliveryAt: { type: Date, default: null },
    lastDeliveryStatus: { type: String, default: null },
    createdBy: { type: Schema.Types.ObjectId, ref: 'Admin', required: true },
    revokedAt: { type: Date, default: null },
  },
  { timestamps: true, minimize: false },
);
integrationSchema.index({ appId: 1, type: 1, status: 1 });
integrationSchema.index({ keyHash: 1 }, { unique: true, partialFilterExpression: { keyHash: { $type: 'string' } } });
// At most one active FCM and one active webhook integration per app.
integrationSchema.index(
  { appId: 1, type: 1 },
  {
    unique: true,
    partialFilterExpression: { status: 'active', type: { $in: ['fcm', 'webhook'] } },
    name: 'one_active_fcm_webhook_per_app',
  },
);

integrationSchema.set('toJSON', {
  versionKey: false,
  transform: (_doc, ret: Record<string, unknown>) => {
    ret.id = String(ret._id);
    delete ret._id;
    delete ret.secret;
    delete ret.keyHash;
    return ret;
  },
});

export type IntegrationAttrs = InferSchemaType<typeof integrationSchema>;
export const Integration = model('Integration', integrationSchema);
