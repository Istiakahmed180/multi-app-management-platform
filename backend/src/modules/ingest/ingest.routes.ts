import { Router } from 'express';
import { rateLimit } from 'express-rate-limit';
import type { Deps } from '../../deps.js';
import { sha256 } from '../../shared/crypto.js';
import { AppError } from '../../shared/errors.js';
import { requireApiKey } from './ingest.auth.js';
import { ingestController } from './ingest.controller.js';

/** Server-to-server API for app backends. Mounted at /ingest; no cookies or CSRF involved. */
export function ingestRouter(deps: Deps): Router {
  const r = Router();
  const c = ingestController();
  const limiter = rateLimit({
    windowMs: deps.env.RATE_LIMIT_WINDOW_MS,
    limit: deps.env.RATE_LIMIT_MAX * 4,
    standardHeaders: 'draft-8',
    legacyHeaders: false,
    // Limit per API key (keys are 256-bit, so unauthenticated callers share one bucket).
    keyGenerator: (req) => sha256(req.get('authorization') ?? 'anonymous'),
    handler: (_req, _res, next) => next(new AppError('rate_limited', 'Rate limit exceeded')),
  });
  r.use('/apps/:appKey', limiter, requireApiKey);
  r.put('/apps/:appKey/users/:externalUserId', c.upsertUser);
  r.get('/apps/:appKey/users/:externalUserId/status', c.status);
  r.delete('/apps/:appKey/users/:externalUserId', c.deleteUser);
  r.post('/apps/:appKey/events', c.events);
  return r;
}
