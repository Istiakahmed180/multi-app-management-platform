import type { ErrorRequestHandler, RequestHandler } from 'express';
import mongoose from 'mongoose';
import { AppError, isDuplicateKeyError, type ErrorCode } from '../errors.js';
import { captureException } from '../error-reporter.js';

const EXPECTED_CODES: ReadonlySet<ErrorCode> = new Set(['not_configured']);

export const notFoundHandler: RequestHandler = (_req, _res, next) => {
  next(new AppError('not_found', 'Route not found'));
};

function normalize(err: unknown): AppError {
  if (err instanceof AppError) return err;
  if (err instanceof mongoose.Error.ValidationError) {
    return new AppError(
      'validation_failed',
      'Request validation failed',
      Object.values(err.errors).map((e) => ({ path: e.path, message: e.message })),
    );
  }
  if (err instanceof mongoose.Error.CastError) {
    return new AppError('bad_request', `Invalid value for ${err.path}`);
  }
  if (isDuplicateKeyError(err)) {
    return new AppError('conflict', 'A resource with the same unique value already exists', {
      fields: Object.keys(err.keyPattern ?? {}),
    });
  }
  const bodyErr = err as { type?: string; status?: number };
  if (bodyErr?.type === 'entity.too.large') return new AppError('payload_too_large', 'Request body too large');
  if (bodyErr?.type === 'entity.parse.failed') return new AppError('bad_request', 'Malformed JSON body');
  if (bodyErr?.type === 'charset.unsupported' || bodyErr?.type === 'encoding.unsupported') {
    return new AppError('bad_request', 'Unsupported request encoding');
  }
  return new AppError('internal_error', 'An unexpected error occurred');
}

export const errorHandler: ErrorRequestHandler = (err, req, res, _next) => {
  const appErr = normalize(err);
  // A missing integration is an expected, admin-fixable state: it keeps its honest 503
  // status but is not reported, logged or counted as a server failure.
  const expected = EXPECTED_CODES.has(appErr.code);
  if (expected) res.locals.expectedError = true;
  if (appErr.status >= 500 && !expected) {
    captureException(err, { requestId: req.ctx?.requestId, path: req.path, method: req.method });
  }
  if (res.headersSent) return;
  res.status(appErr.status).json({
    error: {
      code: appErr.code,
      message: appErr.message,
      ...(appErr.details !== undefined ? { details: appErr.details } : {}),
      requestId: req.ctx?.requestId,
    },
  });
};
