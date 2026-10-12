/** Creates/updates every collection's indexes to match the Mongoose schemas. Run on deploy. */
import { loadEnv } from '../config/env.js';
import { syncAllIndexes } from '../jobs/sync-indexes.js';
import { connectDatabase, disconnectDatabase } from '../shared/db.js';

async function main() {
  const env = loadEnv();
  await connectDatabase(env.MONGODB_URI);
  await syncAllIndexes();
  await disconnectDatabase();
}

main().catch(async (err) => {
  console.error(err);
  await disconnectDatabase().catch(() => undefined);
  process.exit(1);
});
