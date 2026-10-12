import type { Env } from './config/env.js';
import type { AuthService } from './modules/auth/auth.service.js';
import type { PushProviderFactory } from './modules/campaigns/push.provider.js';
import type { PublicConfigCache } from './modules/configurations/public-config.cache.js';
import type { WebhookSender } from './modules/integrations/webhook.sender.js';
import type { StorageService } from './modules/apps/storage.service.js';
import type { MetricsRecorder } from './modules/metrics/metrics.recorder.js';

/** Explicit dependencies, constructed once in `server.ts` and replaced with fakes in tests. */
export interface Deps {
  env: Env;
  auth: AuthService;
  push: PushProviderFactory;
  webhooks: WebhookSender;
  storage: StorageService;
  metrics: MetricsRecorder;
  publicConfigCache: PublicConfigCache;
}
