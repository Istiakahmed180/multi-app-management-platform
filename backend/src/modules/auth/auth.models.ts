import { Schema, model, type InferSchemaType, type HydratedDocument } from 'mongoose';

const adminSchema = new Schema(
  {
    email: {
      type: String,
      required: true,
      unique: true,
      lowercase: true,
      trim: true,
      maxlength: 254,
      match: /^[^\s@]+@[^\s@]+\.[^\s@]+$/,
    },
    name: { type: String, required: true, trim: true, minlength: 1, maxlength: 120 },
    passwordHash: { type: String, required: true, select: false },
    isSuperAdmin: { type: Boolean, default: false },
    status: { type: String, enum: ['active', 'disabled'], default: 'active' },
    failedLoginCount: { type: Number, default: 0, select: false },
    lockedUntil: { type: Date, default: null, select: false },
    lastLoginAt: { type: Date, default: null },
    passwordChangedAt: { type: Date, default: null },
  },
  { timestamps: true },
);

adminSchema.set('toJSON', {
  versionKey: false,
  transform: (_doc, ret: Record<string, unknown>) => {
    ret.id = String(ret._id);
    delete ret._id;
    delete ret.passwordHash;
    delete ret.failedLoginCount;
    delete ret.lockedUntil;
    return ret;
  },
});

export type AdminAttrs = InferSchemaType<typeof adminSchema>;
export type AdminDoc = HydratedDocument<AdminAttrs>;
export const Admin = model('Admin', adminSchema);

const sessionSchema = new Schema(
  {
    adminId: { type: Schema.Types.ObjectId, ref: 'Admin', required: true, index: true },
    accessTokenHash: { type: String, required: true, unique: true },
    refreshTokenHash: { type: String, required: true, unique: true },
    // Kept to detect reuse of a rotated refresh token (token theft signal).
    previousRefreshTokenHash: { type: String, default: null, index: { sparse: true } },
    rotatedAt: { type: Date, default: null },
    accessExpiresAt: { type: Date, required: true },
    refreshExpiresAt: { type: Date, required: true },
    revokedAt: { type: Date, default: null },
    revokedReason: { type: String, default: null },
    ip: { type: String, default: null },
    userAgent: { type: String, default: null },
    lastUsedAt: { type: Date, default: () => new Date() },
  },
  { timestamps: true },
);
// Expired sessions are removed by MongoDB one day after the refresh token expires.
sessionSchema.index({ refreshExpiresAt: 1 }, { expireAfterSeconds: 24 * 3600 });

export type SessionAttrs = InferSchemaType<typeof sessionSchema>;
export const Session = model('Session', sessionSchema);
