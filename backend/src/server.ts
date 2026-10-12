import { createApp } from './app.js';
import { env } from './config/env.js';
import { logger } from './config/logger.js';
import type { Deps } from './deps.js';
import { scheduleRetention } from './jobs/retention.js';
import { syncAllIndexes } from './jobs/sync-indexes.js';
import { S3StorageService } from './modules/apps/storage.service.js';
import { AuthService } from './modules/auth/auth.service.js';
import { CampaignWorker } from './modules/campaigns/campaign.worker.js';
import { FcmPushProviderFactory } from './modules/campaigns/push.provider.js';
import { PublicConfigCache } from './modules/configurations/public-config.cache.js';
import { IntegrationService } from './modules/integrations/integration.service.js';
import { HttpWebhookSender } from './modules/integrations/webhook.sender.js';
import { MetricsRecorder } from './modules/metrics/metrics.recorder.js';
import { connectDatabase, disconnectDatabase } from './shared/db.js';

async function main() {
  const config = env();
  await connectDatabase(config.MONGODB_URI);
  if (config.SYNC_INDEXES_ON_START) await syncAllIndexes();

  const push = new FcmPushProviderFactory();
  const deps: Deps = {
    env: config,
    auth: new AuthService(config),
    push,
    webhooks: new HttpWebhookSender(),
    storage: new S3StorageService(config),
    metrics: new MetricsRecorder(),
    publicConfigCache: new PublicConfigCache(30_000),
  };
  deps.metrics.start();

  const worker = new CampaignWorker(new IntegrationService(config, push, deps.webhooks));
  let retention: NodeJS.Timeout | undefined;
  if (config.WORKERS_ENABLED) {
    worker.start(config.CAMPAIGN_POLL_INTERVAL_MS);
    retention = scheduleRetention(config);
  }

  const server = createApp(deps).listen(config.PORT, () => {
    logger.info({ port: config.PORT, env: config.NODE_ENV, workers: config.WORKERS_ENABLED }, 'API listening');
  });
  server.keepAliveTimeout = 65_000;

  let shuttingDown = false;
  const shutdown = async (signal: string) => {
    if (shuttingDown) return;
    shuttingDown = true;
    logger.info({ signal }, 'Shutting down');
    const force = setTimeout(() => {
      logger.error('Forced shutdown after timeout');
      process.exit(1);
    }, 20_000);
    force.unref();
    server.close();
    if (retention) clearInterval(retention);
    await worker.stop();
    await deps.metrics.stop();
    await push.close();
    await disconnectDatabase();
    logger.info('Shutdown complete');
    process.exit(0);
  };
  process.on('SIGTERM', () => void shutdown('SIGTERM'));
  process.on('SIGINT', () => void shutdown('SIGINT'));
  process.on('unhandledRejection', (err) => logger.error({ err }, 'Unhandled promise rejection'));
}

main().catch((err) => {
  logger.fatal({ err }, 'Failed to start');
  process.exit(1);
});
