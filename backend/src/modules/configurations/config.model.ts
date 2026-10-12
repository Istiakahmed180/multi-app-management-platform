import { Schema, model, type InferSchemaType, type Query } from 'mongoose';

const appConfigSchema = new Schema(
  {
    appId: { type: Schema.Types.ObjectId, ref: 'App', required: true },
    orgId: { type: Schema.Types.ObjectId, ref: 'Organization', required: true },
    state: { type: String, enum: ['draft', 'published'], required: true, immutable: true },
    // Set only on published documents; monotonically increasing per app.
    version: { type: Number, default: null, immutable: true },
    // Validated with `configContentSchema` in the service layer.
    content: { type: Schema.Types.Mixed, required: true },
    changeNote: { type: String, default: '', maxlength: 500 },
    rollbackOfVersion: { type: Number, default: null, immutable: true },
    baseVersion: { type: Number, default: null },
    publishedAt: { type: Date, default: null, immutable: true },
    publishedBy: { type: Schema.Types.ObjectId, ref: 'Admin', default: null, immutable: true },
    updatedBy: { type: Schema.Types.ObjectId, ref: 'Admin', default: null },
  },
  { timestamps: true, minimize: false },
);

appConfigSchema.index({ appId: 1, version: -1 }, { unique: true, partialFilterExpression: { state: 'published' } });
appConfigSchema.index({ appId: 1 }, { unique: true, partialFilterExpression: { state: 'draft' }, name: 'one_draft_per_app' });

// Published versions are immutable: updates can only ever match draft documents.
function onlyDrafts(this: Query<unknown, unknown>) {
  this.where({ state: 'draft' });
}
appConfigSchema.pre(['updateOne', 'updateMany', 'findOneAndUpdate', 'replaceOne', 'findOneAndReplace'], onlyDrafts);
appConfigSchema.pre(['deleteOne', 'deleteMany', 'findOneAndDelete'], { document: false, query: true }, onlyDrafts);
appConfigSchema.pre('save', function () {
  if (!this.isNew && this.state === 'published') {
    throw new Error('Published configuration versions are immutable');
  }
});

export type AppConfigAttrs = InferSchemaType<typeof appConfigSchema>;
export const AppConfig = model('AppConfig', appConfigSchema);
