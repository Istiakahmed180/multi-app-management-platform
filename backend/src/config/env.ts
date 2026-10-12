import 'dotenv/config';
import { z } from 'zod';

const bool = z.enum(['true', 'false', '1', '0']).transform((v) => v === 'true' || v === '1');

const csv = z
  .string()
  .default('')
  .transform((v) =>
    v
      .split(',')
      .map((s) => s.trim())
      .filter(Boolean),
  );

const schema = z.object({
  NODE_ENV: z.enum(['development', 'test', 'staging', 'production']).default('development'),
  PORT: z.coerce.number().int().positive().default(4000),
  LOG_LEVEL: z.enum(['fatal', 'error', 'warn', 'info', 'debug', 'trace', 'silent']).default('info'),
  MONGODB_URI: z.string().min(1),
  CORS_ORIGINS: csv,
  TRUST_PROXY: z.coerce.number().int().min(0).default(0),
  COOKIE_SECURE: bool.optional(),
  COOKIE_DOMAIN: z.string().optional(),
  // 32-byte key, base64 encoded. Used to encrypt integration secrets at rest.
  ENCRYPTION_KEY: z
    .string()
    .refine((v) => Buffer.from(v, 'base64').length === 32, 'ENCRYPTION_KEY must be 32 bytes, base64 encoded'),
  ACCESS_TOKEN_TTL_MINUTES: z.coerce.number().int().positive().default(15),
  REFRESH_TOKEN_TTL_DAYS: z.coerce.number().int().positive().default(7),
  LOGIN_MAX_FAILED_ATTEMPTS: z.coerce.number().int().positive().default(5),
  LOGIN_LOCKOUT_MINUTES: z.coerce.number().int().positive().default(15),
  RATE_LIMIT_WINDOW_MS: z.coerce.number().int().positive().default(60_000),
  RATE_LIMIT_MAX: z.coerce.number().int().positive().default(300),
  AUTH_RATE_LIMIT_MAX: z.coerce.number().int().positive().default(20),
  PUBLIC_RATE_LIMIT_MAX: z.coerce.number().int().positive().default(120),
  BODY_LIMIT: z.string().default('256kb'),
  PUBLIC_CONFIG_CACHE_SECONDS: z.coerce.number().int().min(0).default(60),
  AUDIT_RETENTION_DAYS: z.coerce.number().int().positive().default(365),
  METRICS_RETENTION_DAYS: z.coerce.number().int().positive().default(90),
  EVENTS_RETENTION_DAYS: z.coerce.number().int().positive().default(90),
  INVITATION_TTL_DAYS: z.coerce.number().int().positive().default(7),
  DASHBOARD_URL: z.string().url().optional(),
  WORKERS_ENABLED: bool.default(true),
  SYNC_INDEXES_ON_START: bool.default(false),
  CAMPAIGN_POLL_INTERVAL_MS: z.coerce.number().int().positive().default(15_000),
  S3_ENDPOINT: z.string().url().optional(),
  S3_REGION: z.string().default('us-east-1'),
  S3_BUCKET: z.string().optional(),
  S3_ACCESS_KEY_ID: z.string().optional(),
  S3_SECRET_ACCESS_KEY: z.string().optional(),
  S3_PUBLIC_BASE_URL: z.string().url().optional(),
  S3_FORCE_PATH_STYLE: bool.default(false),
  ERROR_TRACKING_DSN: z.string().optional(),
});

export type Env = z.infer<typeof schema>;

export function loadEnv(source: NodeJS.ProcessEnv = process.env): Env {
  // Blank values (e.g. `S3_ENDPOINT=` copied from .env.example) mean "not set".
  const cleaned = Object.fromEntries(Object.entries(source).filter(([, v]) => v !== undefined && v.trim() !== ''));
  const parsed = schema.safeParse(cleaned);
  if (!parsed.success) {
    const issues = parsed.error.issues.map((i) => `  - ${i.path.join('.')}: ${i.message}`).join('\n');
    throw new Error(`Invalid environment configuration:\n${issues}`);
  }
  const env = parsed.data;
  if (env.NODE_ENV === 'production' && env.CORS_ORIGINS.length === 0) {
    throw new Error('CORS_ORIGINS must be set in production');
  }
  return env;
}

let cached: Env | undefined;

export function env(): Env {
  cached ??= loadEnv();
  return cached;
}

export function cookieSecure(e: Env = env()): boolean {
  return e.COOKIE_SECURE ?? (e.NODE_ENV === 'production' || e.NODE_ENV === 'staging');
}
