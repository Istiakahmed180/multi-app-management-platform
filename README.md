# App Management Platform

A multi-tenant platform for managing many Flutter apps from one Flutter Web dashboard. It covers:
- organizations, roles and members
- app registry
- remote configuration with draft, publish and rollback
- feature flags
- an app-user registry
- Firebase push campaigns
- release metadata
- analytics built only from collected data
- audit logs

| Path | What |
|---|---|
| [`backend/`](backend) | Node.js, Express 5, TypeScript, MongoDB (Mongoose 9), zod. Modular monolith at `/api/v1`. |
| [`dashboard/`](dashboard) | Flutter Web admin (GetX, Dio). Light and dark themes, responsive. |
| [`packages/app_management_sdk/`](packages/app_management_sdk) | Pure-Dart client for Flutter apps: typed config, ETag cache, offline fallback, flags, update policy. |
| [`infra/`](infra) | Docker Compose (MongoDB, API, dashboard and nginx, optional MinIO). |
| [`docs/`](docs) | [Architecture](docs/ARCHITECTURE.md) · [API guide](docs/API.md) · [OpenAPI](docs/openapi.yaml) · [Database](docs/DATABASE.md) · [Deployment](docs/DEPLOYMENT.md) · [Checklist and status](docs/CHECKLIST.md) |

## Quickest start (no Docker)

Requires Node 22+, Flutter and Python 3. A local MongoDB is started automatically.

```bash
./run-local.sh            # starts MongoDB + API + dashboard; Ctrl+C stops all
./run-local.sh --fresh    # same, but wipes local data first
./run-local.sh stop       # stops leftovers from a previous run
```

It prints the dashboard URL (http://localhost:8080) and the dev login. Local data lives in `.local/` and is git-ignored.

## Quick start (Docker)

Requires Docker with Compose v2.

```bash
cp infra/.env.example infra/.env
# Put a key into ENCRYPTION_KEY in infra/.env:
node -e "console.log(require('crypto').randomBytes(32).toString('base64'))"
docker compose -f infra/docker-compose.yml --env-file infra/.env up --build -d
```

Create the first (development-only) super admin. The seed refuses to run in staging or production:

```bash
docker compose -f infra/docker-compose.yml --env-file infra/.env exec \
  -e SEED_ADMIN_EMAIL=you@example.com -e SEED_ADMIN_PASSWORD='choose-a-long-password' \
  backend node dist/cli/seed.js
```

Then open http://localhost:8080. The API is at http://localhost:4000/api/v1 (health: `/api/v1/health`).

## Local development (without Docker for the app code)

Prerequisites:
- Node 22 or newer (tested with 26.5)
- Flutter 3.47 / Dart 3.13
- a MongoDB 7 or 8 instance. `docker compose -f infra/docker-compose.yml up -d mongo` works, or use a local `mongod`.

```bash
# 1. API
cd backend
npm ci
cp .env.example .env            # set ENCRYPTION_KEY (see the comment in the file) and MONGODB_URI
npm run sync-indexes
SEED_ADMIN_EMAIL=you@example.com SEED_ADMIN_PASSWORD='choose-a-long-password' npm run seed
npm run dev                     # http://localhost:4000/api/v1

# 2. Dashboard (separate terminal)
cd dashboard
flutter pub get
flutter run -d chrome --web-port 8080 --dart-define=API_BASE_URL=http://localhost:4000/api/v1
```

`localhost:8080` and `localhost:4000` count as the same *site*, so `SameSite=Strict` cookies work. `CORS_ORIGINS=http://localhost:8080` lets the dashboard call the API with credentials.

## Connecting a Flutter app

1. Register the app in **Apps → Register app** and copy its **app key**. The key is public and is not a secret.
2. Publish a configuration under **Remote config**.
3. Add the SDK and read config and flags. See [the SDK README](packages/app_management_sdk/README.md).
   ```dart
   final client = AppManagementClient(baseUrl: 'https://admin.example.com', appKey: 'app_…',
       platform: AppPlatform.android, appVersion: '1.4.0', installationId: installId);
   await client.initialize();
   if (client.updateStatus().level == UpdateLevel.required) { /* block and show update screen */ }
   if (client.isFeatureEnabled('new_checkout')) { … }
   ```
4. Optional: from your **app backend**, create a server API key (**Integrations**) to sync users, push tokens and activity. Add the Firebase service account to enable push.

## Tests and checks

```bash
cd backend && npm run typecheck && npm test && npm run build
cd dashboard && dart format --set-exit-if-changed lib test && flutter analyze && flutter test && flutter build web
cd packages/app_management_sdk && dart format --set-exit-if-changed . && dart analyze && dart test
```

The backend tests run against an in-memory MongoDB (`mongodb-memory-server`), which downloads a `mongod` binary on first run.

Latest results are recorded in [docs/CHECKLIST.md](docs/CHECKLIST.md).

## What this platform does not do (by design)

- **Remote config cannot add native functionality or replace an app release.** It only drives behavior the app already implements: branding, theme, banners, maintenance mode, update prompts, flags and copy.
- **It does not publish or distribute APK or IPA files.** Releases are metadata. Force-update is enforced by the client app from the published update policy.
- **App users are not your app's user database.** They enter the registry only through the authenticated server ingest API. Suspension is sent to your backend through a signed webhook (or read back from the status API), and your backend enforces it.
- **No analytics are fabricated.** Sections without collected data show empty states.
