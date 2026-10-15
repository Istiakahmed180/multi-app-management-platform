import type { RequestHandler } from 'express';
import type { Types } from 'mongoose';
import { logger } from '../../config/logger.js';
import { ApiMetric } from './api-metric.model.js';

export function normalizePath(url: string): string {
  return (url.split('?')[0] ?? '')
    .replace(/\/[a-f0-9]{24}(?=\/|$)/gi, '/:id')
    .replace(/\/app_[A-Za-z0-9_-]+(?=\/|$)/g, '/:appKey')
    .replace(/(\/ingest\/.*\/users)\/[^/]+(?=\/status$|$)/, '$1/:externalUserId')
    .slice(0, 200);
}

interface Aggregate {
  bucket: Date;
  appId: Types.ObjectId | null;
  orgId: Types.ObjectId | null;
  route: string;
  method: string;
  count: number;
  clientErrors: number;
  serverErrors: number;
  totalDurationMs: number;
  maxDurationMs: number;
  statusCodes: Map<string, number>;
}

/**
 * Aggregates request metrics in memory per (minute, app, route, method) and
 * flushes them to MongoDB with `$inc` upserts, keeping writes off the hot path.
 */
export class MetricsRecorder {
  private buffer = new Map<string, Aggregate>();
  private timer: NodeJS.Timeout | undefined;

  middleware(): RequestHandler {
    return (req, res, next) => {
      const start = process.hrtime.bigint();
      res.on('finish', () => {
        // Ids are replaced with placeholders to keep cardinality bounded; requests that
        // matched no route (scanners, typos) are grouped together.
        const route = req.route ? normalizePath(req.originalUrl) : 'unmatched';
        const durationMs = Number(process.hrtime.bigint() - start) / 1e6;
        this.record({
          route,
          method: req.method,
          status: res.statusCode,
          expectedError: res.locals.expectedError === true,
          durationMs,
          appId: req.ctx?.metricsAppId ?? null,
          orgId: req.ctx?.tenant?.orgId ?? null,
        });
      });
      next();
    };
  }

  record(m: {
    route: string;
    method: string;
    status: number;
    /** Expected failures (e.g. integration not configured) count as client errors. */
    expectedError?: boolean;
    durationMs: number;
    appId: Types.ObjectId | null;
    orgId: Types.ObjectId | null;
  }) {
    const bucket = new Date(Math.floor(Date.now() / 60_000) * 60_000);
    const key = `${bucket.getTime()}|${m.appId ?? '-'}|${m.route}|${m.method}`;
    let agg = this.buffer.get(key);
    if (!agg) {
      agg = {
        bucket,
        appId: m.appId,
        orgId: m.orgId,
        route: m.route,
        method: m.method,
        count: 0,
        clientErrors: 0,
        serverErrors: 0,
        totalDurationMs: 0,
        maxDurationMs: 0,
        statusCodes: new Map(),
      };
      this.buffer.set(key, agg);
    }
    agg.count += 1;
    if (m.status >= 500 && !m.expectedError) agg.serverErrors += 1;
    else if (m.status >= 400) agg.clientErrors += 1;
    agg.totalDurationMs += m.durationMs;
    agg.maxDurationMs = Math.max(agg.maxDurationMs, m.durationMs);
    agg.orgId ??= m.orgId;
    const code = String(m.status);
    agg.statusCodes.set(code, (agg.statusCodes.get(code) ?? 0) + 1);
  }

  async flush(): Promise<void> {
    if (this.buffer.size === 0) return;
    const items = [...this.buffer.values()];
    this.buffer = new Map();
    const ops = items.map((a) => ({
      updateOne: {
        filter: { bucket: a.bucket, appId: a.appId, route: a.route, method: a.method },
        update: {
          $setOnInsert: { orgId: a.orgId },
          $inc: {
            count: a.count,
            clientErrors: a.clientErrors,
            serverErrors: a.serverErrors,
            totalDurationMs: Math.round(a.totalDurationMs),
            ...Object.fromEntries([...a.statusCodes].map(([code, n]) => [`statusCodes.${code}`, n])),
          },
          $max: { maxDurationMs: Math.round(a.maxDurationMs) },
        },
        upsert: true,
      },
    }));
    try {
      await ApiMetric.bulkWrite(ops, { ordered: false });
    } catch (err) {
      logger.warn({ err }, 'Failed to flush API metrics');
    }
  }

  start(intervalMs = 10_000): void {
    this.timer = setInterval(() => void this.flush(), intervalMs);
    this.timer.unref();
  }

  async stop(): Promise<void> {
    if (this.timer) clearInterval(this.timer);
    await this.flush();
  }
}
