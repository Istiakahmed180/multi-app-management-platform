import { pino } from 'pino';

// Paths are redacted wherever they appear in a log object. Keep this list in sync
// with any new secret-bearing field names.
export const REDACT_PATHS = [
  'password',
  '*.password',
  'currentPassword',
  '*.currentPassword',
  'newPassword',
  '*.newPassword',
  'token',
  '*.token',
  'secret',
  '*.secret',
  'apiKey',
  '*.apiKey',
  'serviceAccountJson',
  '*.serviceAccountJson',
  'req.headers.authorization',
  'req.headers.cookie',
  'req.headers["x-csrf-token"]',
  'res.headers["set-cookie"]',
];

export const logger = pino({
  level: process.env.LOG_LEVEL ?? (process.env.NODE_ENV === 'test' ? 'silent' : 'info'),
  redact: { paths: REDACT_PATHS, censor: '[REDACTED]' },
  base: { service: 'amp-backend' },
  timestamp: pino.stdTimeFunctions.isoTime,
});

export type Logger = typeof logger;
