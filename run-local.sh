#!/usr/bin/env bash
# Runs the whole platform locally without Docker:
#   MongoDB (port 27999) + API (port 4000) + Dashboard (port 8080)
# Usage:  ./run-local.sh          start everything (Ctrl+C stops all)
#         ./run-local.sh --fresh  wipe local data first
#         ./run-local.sh stop     stop leftovers from a previous run
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
LOCAL="$ROOT/.local"
mkdir -p "$LOCAL"

# Stops processes from an earlier run of this script (matched by this project's paths only).
stop_leftovers() {
  pkill -f -- "--dbpath $LOCAL/db" 2>/dev/null || true
  pkill -f -- "$ROOT/infra/local/mongo.mjs" 2>/dev/null || true
  pkill -f -- "--directory $LOCAL/web" 2>/dev/null || true
  for pid in $(lsof -tiTCP:4000 -sTCP:LISTEN 2>/dev/null); do
    ps -o command= -p "$pid" | grep -q "dist/server.js" && kill "$pid" 2>/dev/null || true
  done
  sleep 2
}

if [[ "${1:-}" == "stop" ]]; then stop_leftovers; echo "Stopped."; exit 0; fi

need() { command -v "$1" >/dev/null || { echo "Missing '$1'. Install it first."; exit 1; }; }
need node; need npm; need flutter; need python3

stop_leftovers
for port in 4000 8080; do
  if lsof -iTCP:$port -sTCP:LISTEN >/dev/null 2>&1; then
    echo "Port $port is already in use. Stop whatever runs there (or a previous run) and retry."; exit 1
  fi
done

if [[ "${1:-}" == "--fresh" ]]; then rm -rf "$LOCAL/db"; echo "Local data wiped."; fi

# 1. Backend dependencies and config
cd "$ROOT/backend"
[[ -d node_modules ]] || { echo "Installing backend dependencies..."; npm ci; }
if [[ ! -f .env ]]; then
  KEY=$(node -e "console.log(require('crypto').randomBytes(32).toString('base64'))")
  PW=$(node -e "console.log('Dev-'+require('crypto').randomBytes(9).toString('base64url'))")
  cat > .env <<ENV
# Local development config (git-ignored). Created by run-local.sh.
NODE_ENV=development
PORT=4000
LOG_LEVEL=info
MONGODB_URI=mongodb://127.0.0.1:27999/app_management
CORS_ORIGINS=http://localhost:8080
ENCRYPTION_KEY=$KEY
DASHBOARD_URL=http://localhost:8080
SYNC_INDEXES_ON_START=true
CAMPAIGN_POLL_INTERVAL_MS=5000
SEED_ADMIN_EMAIL=admin@example.com
SEED_ADMIN_PASSWORD=$PW
ENV
  echo "Created backend/.env"
fi

PIDS=()
cleanup() {
  echo; echo "Stopping..."
  for pid in "${PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
  wait 2>/dev/null || true
  echo "Stopped."
}
trap cleanup EXIT INT TERM

# 2. MongoDB: start a local one only when backend/.env points at it.
MONGO_URI_LINE=$(grep '^MONGODB_URI=' .env | cut -d= -f2- || true)
USE_LOCAL_MONGO=false
[[ "$MONGO_URI_LINE" == *"127.0.0.1:27999"* || "$MONGO_URI_LINE" == *"localhost:27999"* ]] && USE_LOCAL_MONGO=true
if $USE_LOCAL_MONGO; then
  echo "Starting local MongoDB..."
  node "$ROOT/infra/local/mongo.mjs" > "$LOCAL/mongo.log" 2>&1 &
  PIDS+=($!)
  for _ in $(seq 1 120); do grep -q "MongoDB ready" "$LOCAL/mongo.log" 2>/dev/null && break; sleep 1; done
  grep -q "MongoDB ready" "$LOCAL/mongo.log" || { echo "MongoDB failed to start:"; cat "$LOCAL/mongo.log"; exit 1; }
else
  echo "Using the MongoDB from backend/.env (MONGODB_URI). No local MongoDB started."
fi

# 3. API (seed is idempotent: creates the admin only once)
echo "Building API..."
npm run build >/dev/null
# The dev seed only runs against the local database; it never touches a remote one.
if $USE_LOCAL_MONGO; then npm run seed >/dev/null 2>&1 || echo "Seed failed (see: npm run seed)"; fi
node dist/server.js > "$LOCAL/api.log" 2>&1 &
PIDS+=($!)
for _ in $(seq 1 30); do curl -sf http://localhost:4000/api/v1/health >/dev/null && break; sleep 1; done
curl -sf http://localhost:4000/api/v1/health >/dev/null || { echo "API failed to start:"; tail -20 "$LOCAL/api.log"; exit 1; }

# 4. Dashboard
cd "$ROOT/dashboard"
echo "Building dashboard (first time takes ~30s)..."
flutter build web --release --no-wasm-dry-run --dart-define=API_BASE_URL=http://localhost:4000/api/v1 -o "$LOCAL/web" >/dev/null
python3 -m http.server 8080 --bind 127.0.0.1 --directory "$LOCAL/web" > "$LOCAL/web.log" 2>&1 &
PIDS+=($!)

ADMIN_PW=$(grep '^SEED_ADMIN_PASSWORD=' "$ROOT/backend/.env" | cut -d= -f2- || true)
if $USE_LOCAL_MONGO && [[ -n "$ADMIN_PW" ]]; then LOGIN="admin@example.com / $ADMIN_PW"; else LOGIN="your existing admin account"; fi
cat <<MSG

============================================================
  Dashboard : http://localhost:8080
  API       : http://localhost:4000/api/v1
  Login     : $LOGIN
  Logs      : .local/api.log
  Press Ctrl+C to stop everything.
============================================================
MSG
wait
