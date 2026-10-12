import cookieParser from 'cookie-parser';
import cors from 'cors';
import express, { Router, type Express } from 'express';
import { rateLimit } from 'express-rate-limit';
import helmet from 'helmet';
import { randomUUID } from 'node:crypto';
import { pinoHttp } from 'pino-http';
import { logger } from './config/logger.js';
import type { Deps } from './deps.js';
import { analyticsRouter, overviewRouter } from './modules/analytics/analytics.routes.js';
import { appUserRouter } from './modules/app-users/app-user.routes.js';
import { appRouter } from './modules/apps/app.routes.js';
import { appAuditLogRouter, orgAuditLogRouter } from './modules/audit-logs/audit-log.routes.js';
import { authRouter } from './modules/auth/auth.routes.js';
import { campaignRouter } from './modules/campaigns/campaign.routes.js';
import { configRouter, publicConfigRouter } from './modules/configurations/config.routes.js';
import { featureFlagRouter } from './modules/feature-flags/feature-flag.routes.js';
import { healthRouter } from './modules/health/health.routes.js';
import { ingestRouter } from './modules/ingest/ingest.routes.js';
import { integrationRouter } from './modules/integrations/integration.routes.js';
import { invitationRouter, organizationRouter } from './modules/organizations/organization.routes.js';
import { releaseRouter } from './modules/releases/release.routes.js';
import { AppError } from './shared/errors.js';
import { authenticate, csrfProtection } from './shared/middleware/auth.js';
import { errorHandler, notFoundHandler } from './shared/middleware/error-handler.js';

export const API_VERSION = '0.1.0';

export function createApp(deps: Deps): Express {
  const { env } = deps;
  const app = express();
  app.disable('x-powered-by');
  app.set('trust proxy', env.TRUST_PROXY);
  app.set('etag', false);

  app.use((req, res, next) => {
    const incoming = req.get('x-request-id');
    req.ctx = { requestId: incoming && /^[\w.-]{1,64}$/.test(incoming) ? incoming : randomUUID() };
    res.setHeader('X-Request-Id', req.ctx.requestId);
    next();
  });
  app.use(
    pinoHttp({
      logger,
      genReqId: (req) => (req as express.Request).ctx.requestId,
      autoLogging: { ignore: (req) => req.url?.startsWith('/api/v1/health') ?? false },
      // Log route and status only; bodies and query strings may contain personal data.
      serializers: {
        req: (req: { id: string; method: string; url: string }) => ({
          id: req.id,
          method: req.method,
          path: req.url.split('?')[0],
        }),
        res: (res: { statusCode: number }) => ({ statusCode: res.statusCode }),
      },
    }),
  );
  app.use(helmet());
  app.use(deps.metrics.middleware());

  const limited = (limit: number) =>
    rateLimit({
      windowMs: env.RATE_LIMIT_WINDOW_MS,
      limit,
      standardHeaders: 'draft-8',
      legacyHeaders: false,
      handler: (_req, _res, next) => next(new AppError('rate_limited', 'Too many requests')),
    });

  const api = Router();

  // Public, credential-less endpoints consumed by Flutter apps (any origin, no cookies).
  api.use('/health', cors({ origin: false }), healthRouter(API_VERSION), notFoundHandler);
  api.use(
    '/public',
    cors({ origin: '*', methods: ['GET'], exposedHeaders: ['ETag'] }),
    limited(env.PUBLIC_RATE_LIMIT_MAX),
    publicConfigRouter(deps),
    notFoundHandler,
  );

  // Server-to-server ingest API (API key auth, no browser access).
  api.use('/ingest', cors({ origin: false }), express.json({ limit: '1mb' }), ingestRouter(deps), notFoundHandler);

  // Dashboard API: credentialed CORS from the allow-list only.
  const dashboardCors = cors({
    origin: (origin, cb) => cb(null, !origin || env.CORS_ORIGINS.includes(origin)),
    credentials: true,
    methods: ['GET', 'POST', 'PUT', 'PATCH', 'DELETE'],
    allowedHeaders: ['Content-Type', 'X-CSRF-Token', 'Idempotency-Key', 'X-Request-Id'],
    exposedHeaders: ['X-Request-Id', 'Idempotent-Replayed'],
    maxAge: 600,
  });
  const dashboard = Router();
  dashboard.use(dashboardCors, cookieParser(), express.json({ limit: env.BODY_LIMIT }), limited(env.RATE_LIMIT_MAX));
  dashboard.use('/auth', authRouter(deps));
  dashboard.use('/invitations', invitationRouter(deps));

  const authed = Router();
  authed.use(authenticate(deps.auth), csrfProtection);
  authed.use('/overview', overviewRouter());
  authed.use('/organizations', organizationRouter(deps));
  authed.use('/organizations/:orgId/audit-logs', orgAuditLogRouter());
  authed.use('/apps/:appId/configs', configRouter(deps));
  authed.use('/apps/:appId/features', featureFlagRouter(deps));
  authed.use('/apps/:appId/users', appUserRouter(deps));
  authed.use('/apps/:appId/campaigns', campaignRouter(deps));
  authed.use('/apps/:appId/releases', releaseRouter(deps));
  authed.use('/apps/:appId/analytics', analyticsRouter());
  authed.use('/apps/:appId/audit-logs', appAuditLogRouter());
  authed.use('/apps/:appId/integrations', integrationRouter(deps));
  authed.use('/apps', appRouter(deps));
  dashboard.use(authed);

  api.use(dashboard);
  app.use('/api/v1', api);

  app.use(notFoundHandler);
  app.use(errorHandler);
  return app;
}
