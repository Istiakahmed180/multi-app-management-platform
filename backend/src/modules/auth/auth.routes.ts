import { Router } from 'express';
import { rateLimit } from 'express-rate-limit';
import type { Deps } from '../../deps.js';
import { AppError } from '../../shared/errors.js';
import { authenticate, csrfProtection } from '../../shared/middleware/auth.js';
import { authController } from './auth.controller.js';

export function authRouter(deps: Deps): Router {
  const router = Router();
  const c = authController(deps);
  const session = authenticate(deps.auth);

  const authLimiter = rateLimit({
    windowMs: 15 * 60_000,
    limit: deps.env.AUTH_RATE_LIMIT_MAX,
    standardHeaders: 'draft-8',
    legacyHeaders: false,
    handler: (_req, _res, next) => next(new AppError('rate_limited', 'Too many attempts. Try again later.')),
  });

  router.post('/login', authLimiter, c.login);
  // No CSRF header here: the refresh cookie is SameSite=Strict and path-scoped, and
  // CORS prevents cross-origin pages from reading the response.
  router.post('/refresh', authLimiter, c.refresh);
  router.post('/logout', csrfProtection, c.logout);
  router.get('/me', session, c.me);
  router.patch('/me', session, csrfProtection, c.updateProfile);
  router.post('/change-password', session, csrfProtection, c.changePassword);
  router.get('/sessions', session, c.listSessions);
  router.delete('/sessions/:sessionId', session, csrfProtection, c.revokeSession);
  router.post('/sessions/revoke-others', session, csrfProtection, c.revokeOtherSessions);
  return router;
}
