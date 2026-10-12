import type { Env } from '../config/env.js';
import { logger } from '../config/logger.js';
import { AppUserEvent } from '../modules/app-users/app-user.models.js';
import { AuditLog } from '../modules/audit-logs/audit-log.model.js';
import { ApiMetric } from '../modules/metrics/api-metric.model.js';

const DAY = 86_400_000;

/** Deletes data older than the configured retention windows. Safe to run on every instance. */
export async function runRetention(
  env: Pick<Env, 'AUDIT_RETENTION_DAYS' | 'METRICS_RETENTION_DAYS' | 'EVENTS_RETENTION_DAYS'>,
  now = new Date(),
) {
  const [audit, metrics, events] = await Promise.all([
    AuditLog.deleteMany({ createdAt: { $lt: new Date(now.getTime() - env.AUDIT_RETENTION_DAYS * DAY) } }),
    ApiMetric.deleteMany({ bucket: { $lt: new Date(now.getTime() - env.METRICS_RETENTION_DAYS * DAY) } }),
    AppUserEvent.deleteMany({ occurredAt: { $lt: new Date(now.getTime() - env.EVENTS_RETENTION_DAYS * DAY) } }),
  ]);
  const result = { auditLogs: audit.deletedCount, apiMetrics: metrics.deletedCount, userEvents: events.deletedCount };
  logger.info(result, 'Retention cleanup finished');
  return result;
}

export function scheduleRetention(env: Env, intervalMs = 6 * 3600_000): NodeJS.Timeout {
  const timer = setInterval(() => {
    runRetention(env).catch((err) => logger.error({ err }, 'Retention cleanup failed'));
  }, intervalMs);
  timer.unref();
  return timer;
}
