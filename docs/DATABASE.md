# Database schema

MongoDB with Mongoose. All documents use `ObjectId` `_id`s, which API responses serialize as `id`. Every collection has `createdAt` and `updatedAt` timestamps, except the append-only ones (`AuditLog`, `AppUserEvent`), which have `createdAt` only.

Indexes are declared in the schemas and applied explicitly, not on model load (`autoIndex: false`). There are two ways to apply them:
- `npm run sync-indexes`
- `SYNC_INDEXES_ON_START=true`

Sync creates missing indexes and drops ones no longer declared.

## Tenancy model

```
Organization 1─* Membership *─1 Admin            (role per org; optional appIds scope)
Organization 1─* App
App 1─* AppConfig (1 draft + N immutable published versions)
App 1─* FeatureFlag | AppUser | AppUserEvent | NotificationCampaign | AppRelease | Integration
AuditLog / ApiMetric reference orgId + appId
```

Every app-scoped document stores both `appId` and `orgId`. Queries are always filtered by the `appId` that the authorization middleware verified. The `orgId` copy supports org-wide reporting and retention.

## Collections

| Model (collection) | Purpose | Key fields | Indexes |
|---|---|---|---|
| **Admin** (`admins`) | Dashboard accounts | `email` (unique, lowercase), `name`, `passwordHash` (Argon2id, `select:false`), `isSuperAdmin`, `status`, `failedLoginCount`, `lockedUntil`, `lastLoginAt` | `email` unique |
| **Session** (`sessions`) | DB-backed sessions | `adminId`, `accessTokenHash`, `refreshTokenHash` (SHA-256 of random tokens), `previousRefreshTokenHash`, `rotatedAt`, expiries, `revokedAt`, `ip`, `userAgent` | unique on both hashes; `adminId`; TTL on `refreshExpiresAt` (+1 day) |
| **Organization** | Tenant | `name`, `slug` (unique), `status`, `createdBy` | `slug` unique; `name` |
| **Membership** | Admin ↔ org role | `orgId`, `adminId`, `role` (`owner`/`app_admin`/`support_agent`), `appIds` | `{orgId, adminId}` unique; `adminId`; `{orgId, createdAt}` |
| **Invitation** | Pending invites | `orgId`, `email`, `role`, `appIds`, `tokenHash` (unique), `expiresAt`, `acceptedAt`, `revokedAt` | `tokenHash` unique; `{orgId, email, createdAt}` |
| **App** | Registered Flutter app | `orgId`, `name`, `slug`, `appKey` (public, immutable, unique), `platforms`, `androidPackageId`, `iosBundleId`, `environment`, `status`, `iconUrl`, `publishedConfigVersion` | `appKey` unique; `{orgId, slug}` unique; `{orgId, status, name}`; `{orgId, createdAt}` |
| **AppConfig** | Remote configuration | `appId`, `orgId`, `state` (`draft`/`published`, immutable), `version`, `content` (validated by `configContentSchema`), `changeNote`, `rollbackOfVersion`, `publishedAt/By` | `{appId, version}` unique where `state=published`; `{appId}` unique where `state=draft` |
| **FeatureFlag** | Live flags | `appId`, `orgId`, `key` (immutable), `enabled`, `rolloutPercentage`, `platforms`, `minAppVersion` | `{appId, key}` unique |
| **AppUser** | App-user registry, separate from each app's own user database | `appId`, `orgId`, `externalUserId`, `email`, `displayName`, `status`, `statusReason`, `platform`, `appVersion`, `pushOptIn`, `pushTokens[]`, `attributes`, `firstSeenAt`, `lastSeenAt` | `{appId, externalUserId}` unique; `{appId, createdAt}`; `{appId, lastSeenAt}`; `{appId, status, createdAt}`; `{appId, platform, appVersion}`; `{appId, email}` |
| **AppUserEvent** | Activity events | `appId`, `orgId`, `appUserId`, `type`, `occurredAt`, `platform`, `appVersion`, `properties` | `{appId, appUserId, occurredAt}`; `{appId, occurredAt}`; `{occurredAt}` (retention) |
| **NotificationCampaign** | Push campaigns | `appId`, `orgId`, message fields, `audience`, `status`, `scheduledAt`, `stats{targeted,sent,failed,invalidTokens}`, `errorSummary`, `idempotencyKey`, `attempts`, `lockedUntil`, `cursor` | `{appId, createdAt}`; `{appId, status, createdAt}`; `{status, scheduledAt}` (worker); `{appId, idempotencyKey}` unique (partial) |
| **AppRelease** | Release history | `appId`, `orgId`, `platform`, `version`, `buildNumber`, `status`, `rolloutPercentage`, `isMandatory`, `storeUrl`, `releasedAt` | `{appId, platform, version}` unique; `{appId, createdAt}` |
| **Integration** | Per-app credentials | `appId`, `orgId`, `type` (`fcm`/`server_api_key`/`webhook`), `status`, `publicConfig`, `secret` (AES-256-GCM, `select:false`), `keyHash` (`select:false`), `keyPrefix`, `lastUsedAt`, `lastDeliveryAt/Status` | `{appId, type, status}`; `keyHash` unique (partial); one active `fcm`/`webhook` per app (partial unique) |
| **AuditLog** | Sensitive-action trail | `orgId`, `appId`, `actorType` (`admin`/`api_key`/`system`), `actorId`, `actorEmail`, `action`, `targetType`, `targetId`, `metadata` (redacted), `ip`, `userAgent`, `requestId` | `{orgId, createdAt}`; `{appId, createdAt}`; `{orgId, action, createdAt}`; `{actorId, createdAt}`; `{createdAt}` |
| **ApiMetric** | Per-minute request aggregates | `bucket`, `appId`, `orgId`, `route` (normalized), `method`, `count`, `clientErrors`, `serverErrors`, `totalDurationMs`, `maxDurationMs`, `statusCodes` | `{bucket, appId, route, method}` unique; `{appId, bucket}`; `{orgId, bucket}` |

## Integrity rules enforced in the data layer

- **Published configs are immutable.**
  - Query middleware on `updateOne`, `updateMany`, `findOneAndUpdate`, `replaceOne` and the delete operations forces `state: 'draft'` into the filter. A published document therefore never matches a write.
  - `save()` on an existing published document throws.
  - Covered by `test/config.test.ts`.
- **Version allocation** uses the unique partial index, with retry on collision. No transactions are needed, so a standalone MongoDB works.
- **Idempotent campaign creation** relies on the partial unique index on `{appId, idempotencyKey}`.
- **Secrets are never selectable by default.** `passwordHash`, `secret` and `keyHash` are `select: false` and stripped in `toJSON`. Push tokens are replaced by `pushTokenCount` in API output.

## Retention

`src/jobs/retention.ts` runs every 6 hours on each API instance (it is idempotent):

| Data | Env var | Default |
|---|---|---|
| Audit logs | `AUDIT_RETENTION_DAYS` | 365 |
| API metrics | `METRICS_RETENTION_DAYS` | 90 |
| App-user events | `EVENTS_RETENTION_DAYS` | 90 |
| Sessions | TTL index (refresh expiry + 1 day) | — |

App backends can erase an individual user and their events with `DELETE /ingest/apps/{appKey}/users/{externalUserId}`.

## Transactions

The code does not use transactions. Every multi-document write is either:
- guarded by a unique index (versions, idempotency), or
- an atomic single-document compare-and-set (refresh-token rotation, campaign leases, invitation claims).

So the platform runs on a standalone `mongod` as well as on replica sets or Atlas.
