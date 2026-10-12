import { Router } from 'express';
import { databaseState } from '../../shared/db.js';

const startedAt = new Date();

export function healthRouter(version: string): Router {
  const r = Router();
  // Liveness: the process is up and serving requests.
  r.get('/live', (_req, res) => {
    res.json({ data: { status: 'ok' } });
  });
  // Readiness/health: dependencies are reachable.
  r.get('/', (_req, res) => {
    const db = databaseState();
    const healthy = db === 'connected';
    res.status(healthy ? 200 : 503).json({
      data: {
        status: healthy ? 'ok' : 'degraded',
        version,
        uptimeSeconds: Math.round(process.uptime()),
        startedAt,
        checks: { database: db },
      },
    });
  });
  return r;
}
