import type { RequestHandler } from 'express';
import { sha256 } from '../../shared/crypto.js';
import { AppError } from '../../shared/errors.js';
import { App } from '../apps/app.model.js';
import { Integration } from '../integrations/integration.model.js';
import { API_KEY_PREFIX } from '../integrations/integration.service.js';

declare global {
  // eslint-disable-next-line @typescript-eslint/no-namespace
  namespace Express {
    interface Locals {
      /** Set by the error handler for expected, admin-fixable failures (see EXPECTED_CODES). */
      expectedError?: boolean;
      ingest?: {
        appId: import('mongoose').Types.ObjectId;
        orgId: import('mongoose').Types.ObjectId;
        keyId: import('mongoose').Types.ObjectId;
      };
    }
  }
}

/**
 * Authenticates app backends with a per-app server API key. The key is bound to
 * one app: using it against another app's appKey is rejected.
 */
export const requireApiKey: RequestHandler = async (req, res, next) => {
  const header = req.get('authorization') ?? '';
  const match = /^Bearer\s+(\S+)$/i.exec(header);
  const key = match?.[1];
  if (!key || !key.startsWith(API_KEY_PREFIX)) throw new AppError('unauthenticated', 'A server API key is required');
  const integ = await Integration.findOne({ keyHash: sha256(key), type: 'server_api_key', status: 'active' }).lean();
  if (!integ) throw new AppError('unauthenticated', 'Invalid or revoked API key');
  const app = await App.findById(integ.appId).select('appKey orgId status').lean();
  if (!app || app.appKey !== req.params.appKey) throw new AppError('forbidden', 'This API key is not valid for this app');
  if (app.status === 'archived') throw new AppError('forbidden', 'This app is archived');
  res.locals.ingest = { appId: app._id, orgId: app.orgId, keyId: integ._id };
  req.ctx.metricsAppId = app._id;
  // Throttled bookkeeping; never blocks the request.
  if (!integ.lastUsedAt || Date.now() - integ.lastUsedAt.getTime() > 60_000) {
    void Integration.updateOne({ _id: integ._id }, { $set: { lastUsedAt: new Date() } }).exec();
  }
  next();
};
