import { Schema, model, type InferSchemaType } from 'mongoose';

export const APP_PLATFORMS = ['android', 'ios'] as const;
export type AppPlatform = (typeof APP_PLATFORMS)[number];
export const APP_ENVIRONMENTS = ['development', 'staging', 'production'] as const;
export const APP_STATUSES = ['active', 'inactive', 'archived'] as const;
export type AppStatus = (typeof APP_STATUSES)[number];

const appSchema = new Schema(
  {
    orgId: { type: Schema.Types.ObjectId, ref: 'Organization', required: true },
    name: { type: String, required: true, trim: true, minlength: 2, maxlength: 120 },
    slug: { type: String, required: true, lowercase: true, match: /^[a-z0-9]+(?:-[a-z0-9]+)*$/, maxlength: 64 },
    // Public, non-secret identifier embedded in the Flutter app. Identifies, never authorizes.
    appKey: { type: String, required: true, unique: true, immutable: true },
    description: { type: String, default: '', maxlength: 1000 },
    platforms: {
      type: [{ type: String, enum: APP_PLATFORMS }],
      validate: [(v: string[]) => v.length > 0, 'At least one platform is required'],
    },
    androidPackageId: { type: String, default: null, maxlength: 255 },
    iosBundleId: { type: String, default: null, maxlength: 255 },
    environment: { type: String, enum: APP_ENVIRONMENTS, default: 'production' },
    status: { type: String, enum: APP_STATUSES, default: 'active' },
    iconUrl: { type: String, default: null, maxlength: 2048 },
    publishedConfigVersion: { type: Number, default: null },
    createdBy: { type: Schema.Types.ObjectId, ref: 'Admin', required: true },
  },
  { timestamps: true },
);
appSchema.index({ orgId: 1, slug: 1 }, { unique: true });
appSchema.index({ orgId: 1, status: 1, name: 1 });
appSchema.index({ orgId: 1, createdAt: -1 });

export type AppAttrs = InferSchemaType<typeof appSchema>;
export const App = model('App', appSchema);
