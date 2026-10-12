export type ErrorCode =
  | 'bad_request'
  | 'validation_failed'
  | 'unauthenticated'
  | 'session_expired'
  | 'csrf_failed'
  | 'forbidden'
  | 'not_found'
  | 'conflict'
  | 'account_locked'
  | 'rate_limited'
  | 'payload_too_large'
  | 'not_configured'
  | 'upstream_failed'
  | 'internal_error';

const STATUS: Record<ErrorCode, number> = {
  bad_request: 400,
  validation_failed: 422,
  unauthenticated: 401,
  session_expired: 401,
  csrf_failed: 403,
  forbidden: 403,
  not_found: 404,
  conflict: 409,
  account_locked: 423,
  rate_limited: 429,
  payload_too_large: 413,
  not_configured: 503,
  upstream_failed: 502,
  internal_error: 500,
};

export class AppError extends Error {
  readonly status: number;

  constructor(
    readonly code: ErrorCode,
    message: string,
    readonly details?: unknown,
  ) {
    super(message);
    this.name = 'AppError';
    this.status = STATUS[code];
  }
}

export const notFound = (what = 'Resource') => new AppError('not_found', `${what} not found`);
export const forbidden = (message = 'You do not have permission to perform this action') => new AppError('forbidden', message);
export const conflict = (message: string, details?: unknown) => new AppError('conflict', message, details);
export const badRequest = (message: string, details?: unknown) => new AppError('bad_request', message, details);

export function isDuplicateKeyError(err: unknown): err is { code: 11000; keyPattern?: Record<string, unknown> } {
  return typeof err === 'object' && err !== null && (err as { code?: unknown }).code === 11000;
}
