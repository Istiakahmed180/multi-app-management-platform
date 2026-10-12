import { readFileSync } from 'node:fs';
import request from 'supertest';
import { beforeEach, describe, expect, it } from 'vitest';
import { parse as parseYaml } from 'yaml';
import { buildTestApp, createAdmin, createOrg, login, type Session } from './helpers.js';

const spec = parseYaml(readFileSync(new URL('../../docs/openapi.yaml', import.meta.url), 'utf8')) as {
  paths: Record<string, Record<string, { security?: unknown[] }>>;
};
const METHODS = ['get', 'post', 'put', 'patch', 'delete'] as const;
const FAKE_ID = '64b7f0f0f0f0f0f0f0f0f0f0';

/** Every documented operation must be routed (no "Route not found" responses). */
describe('OpenAPI contract', () => {
  let ctx: ReturnType<typeof buildTestApp>;
  let s: Session;

  beforeEach(async () => {
    ctx = buildTestApp();
    const admin = await createAdmin('root@example.com', { superAdmin: true });
    await createOrg('Acme', admin._id);
    s = await login(ctx.app, 'root@example.com');
  });

  const operations = Object.entries(spec.paths).flatMap(([path, item]) =>
    METHODS.filter((m) => item[m]).map((m) => ({ path, method: m })),
  );

  it('documents a substantial API surface', () => {
    expect(operations.length).toBeGreaterThan(60);
  });

  it.each(operations)('$method $path is implemented', async ({ path, method }) => {
    const url =
      '/api/v1' +
      path
        .replace('{appKey}', 'app_unknownunknown00')
        .replace('{token}', 'x'.repeat(40))
        .replace('{key}', 'some_flag')
        .replace('{version}', '1')
        .replace('{externalUserId}', 'user-1')
        .replace(/\{[A-Za-z]+\}/g, FAKE_ID);
    const res = method === 'get' ? await s.agent.get(url) : await s.agent[method](url).set('X-CSRF-Token', s.csrf).send({});
    expect(res.body?.error?.message, `${method.toUpperCase()} ${url} -> ${res.status}`).not.toBe('Route not found');
    // Every documented route also returns the standard envelope.
    if (res.status !== 304 && res.status !== 204) {
      expect(res.body.data !== undefined || res.body.error !== undefined).toBe(true);
    }
  });

  it('unknown routes are reported as such', async () => {
    const res = await request(ctx.app).get('/api/v1/public/nothing-here');
    expect(res.body.error.message).toBe('Route not found');
  });
});
