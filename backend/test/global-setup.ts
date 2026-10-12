import { MongoMemoryServer } from 'mongodb-memory-server';

let server: MongoMemoryServer | undefined;

export async function setup({ provide }: { provide: (key: string, value: string) => void }) {
  server = await MongoMemoryServer.create();
  provide('mongoUri', server.getUri());
}

export async function teardown() {
  await server?.stop();
}

declare module 'vitest' {
  export interface ProvidedContext {
    mongoUri: string;
  }
}
