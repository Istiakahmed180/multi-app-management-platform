import { Schema, model, type InferSchemaType } from 'mongoose';

/** Per-minute request aggregates recorded by the API itself. */
const apiMetricSchema = new Schema(
  {
    bucket: { type: Date, required: true },
    appId: { type: Schema.Types.ObjectId, ref: 'App', default: null },
    orgId: { type: Schema.Types.ObjectId, ref: 'Organization', default: null },
    route: { type: String, required: true, maxlength: 200 },
    method: { type: String, required: true, maxlength: 10 },
    count: { type: Number, default: 0 },
    clientErrors: { type: Number, default: 0 },
    serverErrors: { type: Number, default: 0 },
    totalDurationMs: { type: Number, default: 0 },
    maxDurationMs: { type: Number, default: 0 },
    statusCodes: { type: Map, of: Number, default: {} },
  },
  { minimize: false },
);
apiMetricSchema.index({ bucket: 1, appId: 1, route: 1, method: 1 }, { unique: true });
apiMetricSchema.index({ appId: 1, bucket: -1 });
apiMetricSchema.index({ orgId: 1, bucket: -1 });

export type ApiMetricAttrs = InferSchemaType<typeof apiMetricSchema>;
export const ApiMetric = model('ApiMetric', apiMetricSchema);
