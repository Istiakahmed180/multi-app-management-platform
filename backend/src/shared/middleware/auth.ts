import type { RequestHandler } from 'express';
import { ACCESS_COOKIE, CSRF_COOKIE, CSRF_HEADER } from '../../modules/auth/cookies.js';
import type { AuthService } from '../../modules/auth/auth.service.js';
import { safeEqual } from '../crypto.js';
import { AppError } from '../errors.js';

const SAFE_METHODS = new Set(['GET', 'HEAD', 'OPTIONS']);

/** Requires a valid, unrevoked admin session cookie. */
export function authenticate(auth: AuthService): RequestHandler {
  return async (req, _res, next) => {
    const token: unknown = req.cookies?.[ACCESS_COOKIE];
    if (typeof token !== 'string' || token.length === 0) {
      throw new AppError('unauthenticated', 'Authentication required');
    }
    const { session, admin } = await auth.resolveAccessToken(token);
    req.ctx.auth = {
      adminId: admin._id,
      email: admin.email,
      name: admin.name,
      isSuperAdmin: admin.isSuperAdmin,
      sessionId: session._id,
    };
    next();
  };
}

/**
 * Double-submit CSRF check for cookie-authenticated, state-changing requests.
 * The token is issued at login/refresh and compared with the `amp_csrf` cookie.
 */
export const csrfProtection: RequestHandler = (req, _res, next) => {
  if (SAFE_METHODS.has(req.method)) return next();
  const cookie: unknown = req.cookies?.[CSRF_COOKIE];
  const header = req.get(CSRF_HEADER);
  if (typeof cookie !== 'string' || !header || !safeEqual(cookie, header)) {
    throw new AppError('csrf_failed', 'Missing or invalid CSRF token');
  }
  next();
};

/** Attaches the session when a valid one is present; otherwise continues anonymously. */
export function optionalAuthenticate(auth: AuthService): RequestHandler {
  const required = authenticate(auth);
  return async (req, res, next) => {
    try {
      await required(req, res, () => undefined);
    } catch {
      req.ctx.auth = undefined;
    }
    next();
  };
}
