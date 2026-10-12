# API guide

The full contract, covering every endpoint's validation, responses, permissions and errors, is in [`openapi.yaml`](openapi.yaml) (OpenAPI 3.1). `backend/test/openapi.test.ts` checks that every documented operation is implemented.

You can browse the spec with any OpenAPI viewer, for example:

```bash
npx @redocly/cli preview-docs docs/openapi.yaml
```

## Conventions

- **Base path:** `/api/v1`
- **Success responses:** `{ "data": … }`. List endpoints add `"meta": { page, pageSize, total, totalPages }`.
- **Error responses:** `{ "error": { "code", "message", "details"?, "requestId" } }`. Validation errors (`422`) list `details: [{ path, message }]`.
- **Pagination:** `?page=1&pageSize=20`, with a maximum of 100. Sorting is restricted to whitelisted fields (`sort=-createdAt`).
- **Request ids:** every response carries `X-Request-Id`, which also appears in logs and audit entries.

## Status codes

| Status | Meaning |
|---|---|
| 401 | Not signed in, or the session expired. The client should call `/auth/refresh` once, then retry. |
| 403 | CSRF failure, or a missing permission on a resource you can see. |
| 404 | Not found, or belongs to a tenant you can't access. These two cases are deliberately indistinguishable. |
| 409 | Conflict: duplicate, stale draft, or invalid state transition. |
| 422 | Validation failure. |
| 423 | Account locked. |
| 429 | Rate limited. |
| 503 | Integration not configured (FCM, object storage). |

## Dashboard authentication flow

```http
POST /api/v1/auth/login              {"email":"…","password":"…"}
→ 200 Set-Cookie: amp_at (HttpOnly, 15 min) · amp_rt (HttpOnly, 7 days, path /api/v1/auth) · amp_csrf
  { "data": { "admin": {…}, "organizations": [{ id, role, permissions[] }], "csrfToken": "…" } }

PATCH /api/v1/apps/:appId            X-CSRF-Token: <csrfToken>     (all unsafe methods)
POST  /api/v1/auth/refresh           (on 401; rotates both tokens, returns a new csrfToken)
GET   /api/v1/auth/me                (after a page reload: restores profile + csrfToken)
```

## Server ingest API (app backend → platform)

Create a key under **Integrations → Server API keys**. Use it only from your server.

```bash
# Upsert a user (call on sign-up / login / profile change)
curl -X PUT "$API/api/v1/ingest/apps/$APP_KEY/users/user-42" \
  -H "Authorization: Bearer $AMP_SERVER_KEY" -H 'content-type: application/json' \
  -d '{"email":"jane@example.com","platform":"ios","appVersion":"1.4.0","pushOptIn":true,
       "pushTokens":[{"token":"<fcm-token>","platform":"ios"}]}'

# Record activity (powers active users / last seen / version distribution)
curl -X POST "$API/api/v1/ingest/apps/$APP_KEY/events" \
  -H "Authorization: Bearer $AMP_SERVER_KEY" -H 'content-type: application/json' \
  -d '{"events":[{"externalUserId":"user-42","type":"session.start","occurredAt":"2026-10-12T10:00:00Z"}]}'

# Enforce suspensions server-side
curl "$API/api/v1/ingest/apps/$APP_KEY/users/user-42/status" -H "Authorization: Bearer $AMP_SERVER_KEY"
```

## Webhooks (platform → app backend)

Events: `user.status_changed` and `ping`. The body is `{ "event", "sentAt", "data" }`.

Verify every request by checking the signature header:

```
X-AMP-Signature: t=<unix seconds>,v1=<hex HMAC-SHA256(signingSecret, "<t>.<raw body>")>
```

Reject the request if:
- the signature doesn't match (compare in constant time), or
- `t` is more than 5 minutes old.

## Public configuration (Flutter app → platform)

```http
GET /api/v1/public/apps/{appKey}/config?platform=android
If-None-Match: "v3-…"
→ 200 (ETag, Cache-Control: public, max-age=60) | 304 | 404
```

The response contains only the public projection: no `internalNotes`, no disabled flags, and no expired or inactive banners. Use the Dart SDK in `packages/app_management_sdk`, which handles caching, ETags, offline fallback and flag evaluation.
