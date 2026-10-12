# Deployment guide

## Topology (recommended)

```
            https://admin.example.com
Browser ───────────────▶ nginx (dashboard image) ── /api/* ──▶ API containers (N) ──▶ MongoDB (replica set / Atlas)
Flutter apps ──────────▶ https://admin.example.com/api/v1/public/... (or a dedicated api host)
App backends ──────────▶ https://admin.example.com/api/v1/ingest/...
```

Serve the dashboard and the API from **the same origin**. The dashboard image's nginx proxies `/api` to the API, which brings three benefits:
- `SameSite=Strict` cookies work.
- No credentialed CORS is needed.
- The CSP stays tight.

If you must use separate hosts, they have to be on the same *site* (for example `admin.example.com` and `api.example.com`). In that case:
- set `CORS_ORIGINS` to the dashboard origin;
- set `COOKIE_DOMAIN=.example.com` if needed;
- build the dashboard with `--dart-define=API_BASE_URL=https://api.example.com/api/v1`.

## Environments

| Variable | development | staging | production |
|---|---|---|---|
| `NODE_ENV` | development | staging | production |
| `COOKIE_SECURE` | false (plain http) | default true | default true |
| `CORS_ORIGINS` | http://localhost:8080 | staging dashboard origin | **required** |
| `TRUST_PROXY` | 0 | number of proxies | number of proxies (e.g. 1 behind nginx/LB) |
| `SYNC_INDEXES_ON_START` | true | true, or run `npm run sync-indexes` in the release step | same as staging |
| `LOG_LEVEL` | debug/info | info | info |

The API refuses to start if any of these hold:
- `ENCRYPTION_KEY` isn't 32 base64 bytes;
- `MONGODB_URI` is missing;
- `CORS_ORIGINS` is empty in production.

The seed script refuses to run in staging or production.

## Secrets

| Secret | Where | Notes |
|---|---|---|
| `ENCRYPTION_KEY` | API env (secret manager) | Encrypts FCM service accounts and webhook secrets at rest (AES-256-GCM). See **Rotating `ENCRYPTION_KEY`** below. |
| `MONGODB_URI` | API env | Use a dedicated DB user with readWrite on one database. |
| `S3_*` | API env | Optional. Grant the IAM key `s3:PutObject` on the asset prefix only. |
| FCM service accounts | Entered per app in the dashboard | Never in env files, the browser or apps. |
| Server API keys | Your app backends' secret stores | Shown once and stored hashed. Revoke from Integrations. |

Never commit `.env` files. Only `.env.example` files are tracked.

### Rotating `ENCRYPTION_KEY`

1. Re-enter the FCM credentials and webhook for each app after switching the key.
2. Or write a one-off script that decrypts with the old key and re-encrypts with the new one.

## Build and release

```bash
# API image
docker build -t registry.example.com/amp-backend:$(git rev-parse --short HEAD) backend

# Dashboard image (pin the Flutter image you develop with)
docker build -t registry.example.com/amp-dashboard:$(git rev-parse --short HEAD) \
  --build-arg FLUTTER_IMAGE=ghcr.io/cirruslabs/flutter:3.47.7 dashboard
```

Release steps:
1. Run the tests: `cd backend && npm ci && npm run typecheck && npm test`, and `cd dashboard && flutter analyze && flutter test`.
2. Apply indexes: `npm run sync-indexes`, or set `SYNC_INDEXES_ON_START=true` on one instance.
3. Roll out the API instances.
   - Health checks:
     - liveness `GET /api/v1/health/live`
     - readiness `GET /api/v1/health`, which returns 503 when the DB is unreachable
   - Shutdown: SIGTERM drains HTTP, stops workers and flushes metrics, with a 20 s grace period.
4. Roll out the dashboard (static files plus nginx). `index.html` is served `no-cache`.

## Scaling notes

- **Workers.** The campaign dispatcher and retention job run in every API instance.
  - Campaign claims are atomic leases in MongoDB, so sends are never duplicated across instances.
  - You can set `WORKERS_ENABLED=false` on most replicas and keep a single worker deployment.
- **Rate limits.** These use an in-memory store per instance, so effective limits multiply by the number of instances.
  - If you need global limits, plug a Redis store into `express-rate-limit` (`rate-limit-redis`). This is the first place Redis would be needed.
- **Public config cache.** It is per instance with a 30 s TTL, and publish invalidates it locally.
  - Other instances converge within 30 s. Clients also revalidate with ETags.
  - Put a CDN in front of `/api/v1/public/*` if traffic is high. Responses are `Cache-Control: public, max-age=60`.
- **Metrics** are buffered per instance and flushed every 10 s with `$inc` upserts.

## Observability

- **Logs.** Structured JSON logs (pino) go to stdout and include `requestId`.
  - Redacted: `authorization`, `cookie`, `x-csrf-token`, `set-cookie`, and any `password`/`token`/`secret`/`apiKey`/`serviceAccountJson` fields.
  - Never logged: request bodies and query strings.
- **Error tracking.** Implement `ErrorReporter` in `backend/src/shared/error-reporter.ts` for Sentry, Rollbar or similar, call `setErrorReporter()` in `server.ts`, and set `ERROR_TRACKING_DSN`.
- **Request metrics.** `ApiMetric` holds per-minute aggregates per app and route, shown on the Overview and Analytics pages.
- **Audit logs.** These are searchable in the dashboard, and their retention is configurable.

## Backups

- Back up MongoDB with Atlas backups or `mongodump` on a schedule.
- Published config versions are immutable history, and rollback is a normal publish, so restoring a backup never needs special handling.

## Hardening checklist

- [ ] HTTPS everywhere. HSTS is set by helmet on the API; add it at your load balancer for the dashboard.
- [ ] `TRUST_PROXY` matches your proxy chain. Otherwise rate limits key on the proxy IP.
- [ ] Egress proxy or firewall for webhooks. The SSRF guard blocks private IP literals but can't see DNS rebinding.
- [ ] MongoDB is not publicly reachable and authentication is enabled.
- [ ] A secret manager supplies `ENCRYPTION_KEY`, `MONGODB_URI` and the `S3_*` credentials.
- [ ] Regular dependency updates (`npm audit`, `flutter pub outdated`).
