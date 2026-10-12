import { Schema, model, type InferSchemaType } from 'mongoose';

const auditLogSchema = new Schema(
  {
    orgId: { type: Schema.Types.ObjectId, ref: 'Organization', default: null },
    appId: { type: Schema.Types.ObjectId, ref: 'App', default: null },
    actorType: { type: String, enum: ['admin', 'api_key', 'system'], required: true },
    actorId: { type: Schema.Types.ObjectId, default: null },
    actorEmail: { type: String, default: null },
    action: { type: String, required: true, maxlength: 64 },
    targetType: { type: String, default: null, maxlength: 64 },
    targetId: { type: String, default: null, maxlength: 128 },
    // Redacted before persistence (see shared/redact.ts).
    metadata: { type: Schema.Types.Mixed, default: {} },
    ip: { type: String, default: null },
    userAgent: { type: String, default: null },
    requestId: { type: String, default: null },
  },
  { timestamps: { createdAt: true, updatedAt: false }, minimize: false },
);
auditLogSchema.index({ orgId: 1, createdAt: -1 });
auditLogSchema.index({ appId: 1, createdAt: -1 });
auditLogSchema.index({ orgId: 1, action: 1, createdAt: -1 });
auditLogSchema.index({ actorId: 1, createdAt: -1 });
auditLogSchema.index({ createdAt: 1 });

export type AuditLogAttrs = InferSchemaType<typeof auditLogSchema>;
export const AuditLog = model('AuditLog', auditLogSchema);
