# Architecture

## Overview

```
┌──────────────────────┐   cookies + CSRF header    ┌─────────────────────────────┐
│ dashboard/ (Flutter  │ ─────────────────────────▶ │ backend/ (Express 5 + TS)   │
│ Web, GetX, Dio)      │ ◀───────────────────────── │  modular monolith /api/v1   │
└──────────────────────┘        JSON                │                             │
                                                    │  ┌─ auth / sessions / CSRF  │
┌──────────────────────┐  GET public config (ETag)  │  ├─ tenancy (orgs, members) │       ┌─────────┐
│ Flutter apps using   │ ─────────────────────────▶ │  ├─ apps / configs / flags  │ ────▶ │ MongoDB │
│ packages/            │                            │  ├─ app-users / ingest      │       └─────────┘
│ app_management_sdk   │                            │  ├─ campaigns ─▶ FCM        │ ────▶ Firebase (per-app)
└──────────────────────┘                            │  ├─ releases / analytics    │
┌──────────────────────┐  server API key (Bearer)   │  ├─ integrations / webhooks │ ────▶ App backends
│ Existing app backends│ ─────────────────────────▶ │  └─ audit logs / metrics    │ ────▶ S3-compatible storage
└──────────────────────┘                            └─────────────────────────────┘
```

There are three clients and three trust levels:

| Caller | Authentication | What it can do |
|---|---|---|
| Dashboard (browser) | HttpOnly session cookies + double-submit CSRF token | Everything its memberships and role allow |
| App backend (server-to-server) | Per-app **server API key** (`Authorization: Bearer amk_…`), stored hashed | Upsert app users, push tokens and activity events, read user status |
| Flutter app (untrusted device) | None. The `appKey` only identifies the app | Read the **published, public projection** of config and feature flags |

## Key decisions

1. **Modular monolith.** There is one Express process and each module owns its routes, controller, service, schemas and models. No microservices.
2. **Opaque, DB-backed sessions instead of JWTs.**
   - The access cookie lasts 15 minutes and the refresh cookie 7 days. Both are random 256-bit tokens, and only their SHA-256 hashes are stored.
   - Revocation takes effect immediately because every request checks the session.
   - Refresh rotates both tokens. Reusing an old refresh token revokes the session.
3. **CSRF protection uses a double-submit token.**
   - The token is returned in the login, refresh and `/auth/me` response bodies and also set as a cookie.
   - Every unsafe method must send `X-CSRF-Token`, which is compared in constant time with the cookie. Cookies are also `SameSite=Strict`.
4. **Tenant isolation lives in middleware.**
   - `requireApp(permission)` loads the app by id, resolves the caller's membership in the app's organization, checks the role's permissions and the membership's app scope, then attaches `req.app`.
   - Services receive the verified `appId`/`orgId` and never read tenant ids from the request body.
   - A missing app and an app the caller can't access both return **404**, so app ids can't be enumerated.
5. **Remote configuration has one mutable draft and immutable published versions.**
   - Each app has exactly one draft document, which `PUT` updates.
   - Publishing inserts a new immutable `published` document with a monotonically increasing `version`. A unique `{appId, version}` index makes concurrent publishes safe without transactions.
   - Rollback publishes a **new** version whose content copies the target version. History stays linear and ETags always change.
   - Mongoose query middleware forces updates to match `state: 'draft'`, so published documents can't be modified.
6. **Feature flags are not part of the config draft.** They are live, take effect immediately, and every change is audited. The public endpoint returns flag rules (enabled, rollout %, platforms, minimum app version). The SDK evaluates them locally with a stable per-install bucket.
7. **Version policy comes from config, and releases record history.**
   - The minimum supported version, latest version and update URL are part of the remote config, so they get draft, publish and rollback.
   - The Releases module stores release metadata, staged-rollout settings and history. It can copy a release into the draft update policy, but it never publishes a binary.
   - The client app enforces force-update.
8. **Background work runs on MongoDB leases, without Redis or BullMQ.**
   - Campaign dispatch and webhook delivery are claimed with atomic `findOneAndUpdate` leases that have an expiry. This is safe across several API instances, and crashed jobs resume from a stored cursor.
   - At the current scope this replaces Redis and BullMQ, and removes two infrastructure dependencies. The dispatcher is isolated in `modules/campaigns/campaign.worker.ts` if a queue is needed later.
9. **Push goes through each app's own Firebase project.**
   - The FCM service-account JSON is stored in the `Integration` collection, encrypted with AES-256-GCM using `ENCRYPTION_KEY`. It is never returned by any endpoint.
   - The `PushProvider` interface lets tests inject a fake provider.
10. **The app-user registry is separate from each app's business database.**
    - Users enter it only through the server ingest API.
    - Suspending a user is recorded in the registry and sent to the app's backend as an HMAC-signed webhook when one is configured. The API reports whether the change was propagated.
11. **Analytics are never fabricated.**
    - Metrics come from three sources: ingested users and events, request metrics recorded by the API itself, and campaign results.
    - Every analytics response says which sources have data, and the dashboard shows empty states otherwise.
12. **Retention.** A periodic job deletes audit logs, API metrics and user events older than the configured number of days.

## Directory structure

```
app-management-platform/
├── backend/
│   ├── src/
│   │   ├── config/            env parsing (zod), logger
│   │   ├── shared/            errors, http helpers, pagination, crypto, rbac, middleware
│   │   ├── modules/
│   │   │   ├── auth/          login/logout/refresh/me, sessions, password
│   │   │   ├── organizations/ orgs + memberships + invitations
│   │   │   ├── apps/          app registry, status, asset uploads
│   │   │   ├── configurations/draft/publish/rollback + public endpoint
│   │   │   ├── feature-flags/
│   │   │   ├── app-users/     registry, status changes
│   │   │   ├── ingest/        server-to-server API (API keys)
│   │   │   ├── campaigns/     FCM campaigns, scheduler worker
│   │   │   ├── releases/
│   │   │   ├── analytics/     per-app analytics + org overview
│   │   │   ├── integrations/  FCM creds, API keys, webhooks
│   │   │   ├── audit-logs/
│   │   │   └── health/
│   │   ├── jobs/              retention, index sync
│   │   ├── cli/               seed (dev only), sync-indexes
│   │   ├── app.ts             express app factory (DI for tests)
│   │   └── server.ts          bootstrap + graceful shutdown
│   └── test/                  vitest + supertest + mongodb-memory-server
├── dashboard/                 Flutter Web (GetX, Dio)
├── packages/app_management_sdk/  pure-Dart client package
├── infra/                     Dockerfiles, docker-compose, nginx, mongo init
└── docs/                      this file, API (OpenAPI), DB schema, deployment, checklist
```

## Roles and permissions

| Permission | Super Admin | Org Owner | App Admin | Support Agent |
|---|:-:|:-:|:-:|:-:|
| `org:read` | ✓ | ✓ | ✓ | ✓ |
| `org:manage` (rename org) | ✓ | ✓ | | |
| `members:read` | ✓ | ✓ | ✓ | |
| `members:manage` (invite/remove/role) | ✓ | ✓ | | |
| `apps:read` | ✓ | ✓ | ✓ | ✓ |
| `apps:create` | ✓ | ✓ | | |
| `apps:write` (edit, status) | ✓ | ✓ | ✓ | |
| `config:read` / `flags:read` | ✓ | ✓ | ✓ | ✓ |
| `config:write` / `config:publish` / `flags:write` | ✓ | ✓ | ✓ | |
| `users:read` | ✓ | ✓ | ✓ | ✓ |
| `users:write` (suspend/reactivate) | ✓ | ✓ | ✓ | ✓ |
| `campaigns:read` | ✓ | ✓ | ✓ | ✓ |
| `campaigns:write` | ✓ | ✓ | ✓ | |
| `releases:read` | ✓ | ✓ | ✓ | ✓ |
| `releases:write` | ✓ | ✓ | ✓ | |
| `analytics:read` | ✓ | ✓ | ✓ | ✓ |
| `audit:read` | ✓ | ✓ | ✓ | |
| `integrations:read` | ✓ | ✓ | ✓ | |
| `integrations:write` | ✓ | ✓ | | |

- **Super Admin** is a platform-level flag on `Admin` and gives access to all organizations.
- Other roles come from a `Membership` per organization.
- `App Admin` and `Support Agent` memberships can be limited to specific `appIds`. An empty list means every app in the organization.

The single source of truth is `backend/src/shared/rbac.ts`.
