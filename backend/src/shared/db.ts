import mongoose from 'mongoose';
import { logger } from '../config/logger.js';

// Query operator injection is prevented by validating every request input with zod
// (ids and filters are parsed as primitives), so `sanitizeFilter` is not enabled.
mongoose.set('strictQuery', true);
// Serialize `_id` as `id` and drop internal fields in every API response.
mongoose.set('toJSON', {
  virtuals: false,
  versionKey: false,
  transform: (_doc, ret: Record<string, unknown>) => {
    if (ret._id !== undefined) {
      ret.id = String(ret._id);
      delete ret._id;
    }
    return ret;
  },
});

export async function connectDatabase(uri: string): Promise<typeof mongoose> {
  mongoose.connection.on('disconnected', () => logger.warn('MongoDB disconnected'));
  mongoose.connection.on('reconnected', () => logger.info('MongoDB reconnected'));
  mongoose.connection.on('error', (err) => logger.error({ err }, 'MongoDB error'));
  // Indexes are managed explicitly (SYNC_INDEXES_ON_START or `npm run sync-indexes`), not on model load.
  await mongoose.connect(uri, { serverSelectionTimeoutMS: 10_000, maxPoolSize: 20, autoIndex: false });
  logger.info('MongoDB connected');
  return mongoose;
}

export async function disconnectDatabase(): Promise<void> {
  await mongoose.disconnect();
}

export function databaseState(): 'connected' | 'connecting' | 'disconnected' | 'disconnecting' | 'unknown' {
  switch (mongoose.connection.readyState) {
    case 1:
      return 'connected';
    case 2:
      return 'connecting';
    case 0:
      return 'disconnected';
    case 3:
      return 'disconnecting';
    default:
      return 'unknown';
  }
}

export const toObjectId = (id: string) => new mongoose.Types.ObjectId(id);
export const isObjectId = (id: unknown): id is string => typeof id === 'string' && /^[a-f0-9]{24}$/i.test(id);
