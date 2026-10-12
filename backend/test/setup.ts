import mongoose from 'mongoose';
import { afterAll, beforeAll, beforeEach, inject } from 'vitest';
import '../src/shared/db.js';
import '../src/modules/auth/auth.models.js';
import '../src/modules/organizations/organization.models.js';
import '../src/modules/apps/app.model.js';
import '../src/modules/app-users/app-user.models.js';
import '../src/modules/configurations/config.model.js';
import '../src/modules/feature-flags/feature-flag.model.js';
import '../src/modules/campaigns/campaign.model.js';
import '../src/modules/releases/release.model.js';
import '../src/modules/integrations/integration.model.js';
import '../src/modules/audit-logs/audit-log.model.js';
import '../src/modules/metrics/api-metric.model.js';

// Each test file gets its own database so files cannot interfere with each other.
beforeAll(async () => {
  const uri = inject('mongoUri');
  const dbName = `amp_test_${process.pid}_${Math.random().toString(36).slice(2, 8)}`;
  await mongoose.connect(uri, { dbName });
  await Promise.all(mongoose.modelNames().map((n) => mongoose.model(n).syncIndexes()));
});

beforeEach(async () => {
  await Promise.all(mongoose.modelNames().map((n) => mongoose.model(n).deleteMany({}).setOptions({ strictQuery: false })));
});

afterAll(async () => {
  await mongoose.connection.dropDatabase();
  await mongoose.disconnect();
});
