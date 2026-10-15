// Local MongoDB without Docker or a system install (dev only).
// Uses the mongod binary downloaded by mongodb-memory-server; data persists in .local/db.
import { mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { MongoMemoryServer } from '../../backend/node_modules/mongodb-memory-server/index.js';

const dbPath = fileURLToPath(new URL('../../.local/db', import.meta.url));
mkdirSync(dbPath, { recursive: true });
const port = Number(process.env.MONGO_PORT ?? 27999);
const server = await MongoMemoryServer.create({ instance: { port, dbPath, storageEngine: 'wiredTiger' } });
console.log(`MongoDB ready at ${server.getUri()} (data: ${dbPath})`);

const stop = async () => {
  await server.stop({ doCleanup: false });
  process.exit(0);
};
process.on('SIGINT', stop);
process.on('SIGTERM', stop);
setInterval(() => {}, 1 << 30);
