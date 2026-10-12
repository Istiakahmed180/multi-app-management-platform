import { logger } from '../config/logger.js';

/**
 * Integration point for an external error tracker (Sentry, Rollbar, ...).
 * Install the vendor SDK, call it from `captureException`, and set ERROR_TRACKING_DSN.
 */
export interface ErrorReporter {
  captureException(err: unknown, context?: Record<string, unknown>): void;
}

export const logErrorReporter: ErrorReporter = {
  captureException(err, context) {
    logger.error({ err, ...context }, 'Unhandled error');
  },
};

let reporter: ErrorReporter = logErrorReporter;

export function setErrorReporter(r: ErrorReporter): void {
  reporter = r;
}

export function captureException(err: unknown, context?: Record<string, unknown>): void {
  reporter.captureException(err, context);
}
