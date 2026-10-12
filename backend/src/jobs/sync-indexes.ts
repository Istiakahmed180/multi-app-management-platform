import mongoose from 'mongoose';
import { logger } from '../config/logger.js';
import '../modules/auth/auth.models.js';
import '../modules/organizations/organization.models.js';
import '../modules/apps/app.model.js';
import '../modules/app-users/app-user.models.js';
import '../modules/configurations/config.model.js';
import '../modules/feature-flags/feature-flag.model.js';
import '../modules/campaigns/campaign.model.js';
import '../modules/releases/release.model.js';
import '../modules/integrations/integration.model.js';
import '../modules/audit-logs/audit-log.model.js';
import '../modules/metrics/api-metric.model.js';

/** Creates missing indexes and drops ones no longer declared in the schemas. */
export async function syncAllIndexes(): Promise<void> {
  for (const name of mongoose.modelNames()) {
    const dropped = await mongoose.model(name).syncIndexes();
    logger.info({ model: name, dropped }, 'Indexes synced');
  }
}
