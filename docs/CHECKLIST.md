# Implementation checklist and status

Last verified: 2026-10-12. Toolchain: Node 26.5, TypeScript 7.0, Flutter 3.47.7 / Dart 3.13.5, MongoDB 8.x (in-memory for tests).

## Verification results

| Component | Command | Result |
|---|---|---|
| Backend type check | `npm run typecheck` | ✅ no errors |
| Backend format | `npm run format:check` | ✅ |
| Backend build | `npm run build` | ✅ |
| Backend tests | `npm test` | ✅ **162 passed** across 9 files (auth 16, tenancy/RBAC 17, apps 9, config 9, flags 2, campaigns 12, users/ingest 9, platform 14, OpenAPI contract 74) |
| Dashboard analysis | `flutter analyze` | ✅ no issues |
| Dashboard format | `dart format --set-exit-if-changed lib test` | ✅ |
| Dashboard tests | `flutter test` | ✅ **26 passed** (API client and error mapping, auth states, routing guards, login widget flow, config parsing and diffing, responsive shell, table states) |
| Dashboard build | `flutter build web --release` | ✅ |
| SDK analysis / format | `dart analyze`, `dart format` | ✅ no issues |
| SDK tests | `dart test` | ✅ **99 passed** |
| Compose file | `docker compose config` | ✅ valid. Images **not built or run here** because the Docker daemon was not running. |

### Manual end-to-end check

I ran the compiled API against MongoDB 8 in memory, with a seeded dev admin and the release dashboard build, and drove it in a browser.

- **Sign-in and sessions**
  - Unauthenticated visits redirect to login; sign-in works.
  - The session survives a page reload, and the CSRF header is sent on writes.
- **Screens.** These all rendered real data with no runtime errors:
  - overview, apps, config editor, version history, flags, users, analytics, campaigns, releases, integrations, members, audit logs
  - the phone-width layout
- **Remote config:** toggled maintenance in the editor, saved the draft (`PUT 200`), and published v2. The public endpoint then served v2 without `internalNotes`.
- **Dart SDK:**
  - Fetched v2 from the live API.
  - Evaluated a 25% rollout deterministically.
  - Got `304 notModified` on refresh.
  - Served the cached config when the API was unreachable.
- **Logs:** SIGTERM shut down gracefully, and the password never appeared in the logs.
- **Bug fixed:** sidebar navigation used to keep stale controllers. Sidebar items now replace the route stack.

## Requirement checklist

### Platform and architecture
- [x] Modular monolith with routes, controllers, services, schemas, models, middleware, jobs and tests per module
- [x] `/api/v1` versioning, zod validation, central error handler with a safe error envelope and request ids
- [x] Helmet, CORS allow-list (credentialed for the dashboard; `*` without credentials for public config; none for ingest)
- [x] Rate limits (global, login/refresh, public, per API key), body size limits
- [x] Graceful shutdown, DB connection events, liveness and readiness health checks
- [x] Structured pino logs with secret redaction; no bodies or query strings logged
- [x] Environment validation and `.env.example` files; no secrets or default passwords in code

### A. Authentication and admin management
- [x] Login, logout, refresh (rotation and reuse detection), `/auth/me`, profile update, password change
- [x] HttpOnly, `SameSite=Strict`, `Secure` (non-dev) cookies plus double-submit CSRF
- [x] Argon2id hashing, account lockout, timing-equalized unknown-user logins
- [x] Session list and revocation (single and all others); disabling an admin kills their sessions
- [x] Roles: Super Admin (platform flag), Owner, App Admin, Support Agent; permission map in `shared/rbac.ts`; app-scoped memberships
- [x] Invitations: create, preview, accept (new or existing account), revoke, single use, expiry
- [x] Audit logs for logins, failed logins, member changes, config, flags, campaigns, integrations, user status and releases

### B. Organizations and multi-app
- [x] Organization CRUD (create and rename), membership management, last-owner protection
- [x] App registry: name, slug, public appKey, Android package and iOS bundle validation, environment, status, icon
- [x] Search, filters, pagination, sorting; app switcher in the sidebar (keeps the current section)
- [x] Tenant isolation in middleware. Client-supplied org ids are verified, and inaccessible resources return 404. Cross-org and cross-app tests are in `tenancy.test.ts`.

### C. Dashboard overview
- [x] Apps, users, active users (only when activity was ingested), new registrations, API requests and 5xx rate, campaign stats, app health and integration status, recent admin activity
- [x] No fabricated numbers; explicit "No data" and empty states

### D. Remote configuration
- [x] One draft plus immutable published versions; publish, history, view and diff, rollback (as a new version)
- [x] Maintenance mode, minimum and recommended versions with update URL, branding, theme light/dark palettes, banners with schedule, onboarding, content strings, internal notes
- [x] Strict validation with field-level errors; optimistic concurrency on drafts
- [x] Public read-only endpoint with an explicit public projection, ETag/304, `Cache-Control`, in-process cache invalidated on publish, flag change and status change
- [x] Feature flags: live, rollout %, platforms, minimum app version, audited before/after

### E. App users
- [x] Registry separate from app databases; data enters through the authenticated server ingest API (API key bound to one app)
- [x] List, search (prefix), filter, sort, pagination, details, activity history
- [x] Suspend and reactivate with reason. The change is delivered through an HMAC-signed webhook when configured; the response reports whether it propagated. Status is readable by the backend; GDPR-style erase endpoint.

### F. Push notifications
- [x] Per-app FCM service account (encrypted at rest, never returned); credential test
- [x] Title, body, image, data payload; audiences: all, platform, recently active, specific users; estimate
- [x] Draft, schedule, send now, cancel; history with stats and error summary; invalid tokens pruned
- [x] Retries for transient errors, lease-based multi-instance-safe worker with a resume cursor (no duplicate sends), Idempotency-Key on create
- [x] Audit entries for create, schedule, cancel and completion

### G. Releases
- [x] Android and iOS release metadata, status, staged rollout %, mandatory flag, store URL, history, summary
- [x] "Use in policy" copies a release into the draft update policy (published through config). There is no binary distribution, by design.

### H. Monitoring and audit
- [x] Health endpoints, structured logging, error-tracker integration point, per-minute request metrics (normalized routes, status codes, latency)
- [x] Searchable and paginated audit logs (org and app; filtered for app-scoped members), redacted metadata
- [x] Configurable retention (audit, metrics, events) plus session TTL

### Dashboard (17 screens)
- [x] Login · Overview · Organizations · App list · App register/edit · App details · Users (list and detail) · Remote config editor · Version history · Feature flags · Campaigns · Releases · Analytics · Members and roles · Integrations and settings · Audit logs (org and app) · Profile and security, plus accept-invite
- [x] Persistent sidebar or drawer, breadcrumbs, profile menu, light/dark/system theme, reusable data table, confirmation dialogs (type-to-confirm for archive and delete), loading, empty, error and success states, form validation with server field errors

### SDK, infrastructure and docs
- [x] Pure-Dart SDK: typed models, ETag cache, last-known-good fallback, file and in-memory stores, flags, update policy, banners, tests
- [x] Dockerfiles (API, dashboard with nginx), Compose (MongoDB, API, dashboard, optional MinIO), index sync, dev seed
- [x] README, architecture, API guide, OpenAPI 3.1 (contract-tested), database schema, deployment guide

## Known limitations and next steps

1. **Docker images were not built or run in this environment** (the Docker daemon was off). The Compose file validates; run `docker compose … up --build` once to confirm. The dashboard Dockerfile defaults to `ghcr.io/cirruslabs/flutter:stable`; pin it to your Flutter version.
2. **No email delivery.** Invitations return a one-time link to the inviter. Add an email provider (SES, Postmark) in `OrganizationService.invite`.
3. **Real FCM delivery is untested here** because it needs a Firebase project. The provider is behind an interface and the worker is tested with a fake. Configure a service account under Integrations, use **Test credentials**, then send to a device.
4. **S3 uploads**: presigning is implemented. The dashboard currently accepts image URLs and doesn't yet offer a file picker that uses `/assets/presign`.
5. **Rate limits and the public-config cache are per instance.** For a global limit, add a Redis store (the first real need for Redis). BullMQ was intentionally not added: MongoDB leases cover scheduled campaigns without extra infrastructure.
6. **Webhook SSRF guard** blocks private IP literals but not DNS rebinding. Use an egress proxy in production.
7. **Admin MFA (TOTP/WebAuthn) and SSO** are not implemented. These are recommended before production use by large teams.
8. **Super admin management UI.** The super admin flag is set by the seed or the database only; there is no dashboard screen to grant it, by design.
9. **Flutter widget coverage** focuses on shell, auth and routing. Screen-level widget tests for the editors are a good next addition.
10. **Account deletion for dashboard admins** (self-service) is not implemented.
