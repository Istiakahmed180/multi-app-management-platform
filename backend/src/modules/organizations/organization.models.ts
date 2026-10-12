import { Schema, model, type InferSchemaType } from 'mongoose';
import { ORG_ROLES } from '../../shared/rbac.js';

const organizationSchema = new Schema(
  {
    name: { type: String, required: true, trim: true, minlength: 2, maxlength: 120 },
    slug: {
      type: String,
      required: true,
      unique: true,
      lowercase: true,
      match: /^[a-z0-9]+(?:-[a-z0-9]+)*$/,
      maxlength: 64,
    },
    status: { type: String, enum: ['active', 'suspended'], default: 'active' },
    createdBy: { type: Schema.Types.ObjectId, ref: 'Admin', required: true },
  },
  { timestamps: true },
);
organizationSchema.index({ name: 1 });

export type OrganizationAttrs = InferSchemaType<typeof organizationSchema>;
export const Organization = model('Organization', organizationSchema);

const membershipSchema = new Schema(
  {
    orgId: { type: Schema.Types.ObjectId, ref: 'Organization', required: true },
    adminId: { type: Schema.Types.ObjectId, ref: 'Admin', required: true },
    role: { type: String, enum: ORG_ROLES, required: true },
    // Restricts app-scoped roles to specific apps. Empty = every app in the organization.
    appIds: { type: [Schema.Types.ObjectId], ref: 'App', default: [] },
    createdBy: { type: Schema.Types.ObjectId, ref: 'Admin', default: null },
  },
  { timestamps: true },
);
membershipSchema.index({ orgId: 1, adminId: 1 }, { unique: true });
membershipSchema.index({ adminId: 1 });
membershipSchema.index({ orgId: 1, createdAt: -1 });

export type MembershipAttrs = InferSchemaType<typeof membershipSchema>;
export const Membership = model('Membership', membershipSchema);

const invitationSchema = new Schema(
  {
    orgId: { type: Schema.Types.ObjectId, ref: 'Organization', required: true },
    email: { type: String, required: true, lowercase: true, trim: true, maxlength: 254 },
    role: { type: String, enum: ORG_ROLES, required: true },
    appIds: { type: [Schema.Types.ObjectId], ref: 'App', default: [] },
    tokenHash: { type: String, required: true, unique: true, select: false },
    invitedBy: { type: Schema.Types.ObjectId, ref: 'Admin', required: true },
    expiresAt: { type: Date, required: true },
    acceptedAt: { type: Date, default: null },
    revokedAt: { type: Date, default: null },
  },
  { timestamps: true },
);
invitationSchema.index({ orgId: 1, email: 1, createdAt: -1 });

export type InvitationAttrs = InferSchemaType<typeof invitationSchema>;
export const Invitation = model('Invitation', invitationSchema);
