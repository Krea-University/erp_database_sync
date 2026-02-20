#!/usr/bin/env bash
# =============================================================================
#  sync.sh  –  Pull Cloud SQL → restore into local MySQL (Docker)
#  Runs on-demand or via cron every 2-3 hours.
# =============================================================================
set -euo pipefail

# ── 0. Locate .env relative to this script ───────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "[ERROR] .env not found at $ENV_FILE – copy .env.example and fill it in."
  exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

# ── 1. Validate required variables ───────────────────────────────────────────
REQUIRED_VARS=(
  CLOUD_SQL_INSTANCE CLOUD_SQL_DB CLOUD_SQL_USER CLOUD_SQL_PASSWORD
  MYSQL_ROOT_PASSWORD MYSQL_DATABASE MYSQL_PORT
  BACKUP_DIR LOG_DIR
)
for var in "${REQUIRED_VARS[@]}"; do
  if [[ -z "${!var:-}" ]]; then
    echo "[ERROR] Required variable \$$var is not set in .env"
    exit 1
  fi
done

# ── 2. Setup directories & logging ───────────────────────────────────────────
mkdir -p "$BACKUP_DIR" "$LOG_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="${LOG_DIR}/sync_${TIMESTAMP}.log"
DUMP_FILE="${BACKUP_DIR}/dump_${TIMESTAMP}.sql.gz"
PROXY_PID_FILE="/tmp/cloud_sql_proxy.pid"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

log "========== ERP Cloud SQL Sync Started =========="
log "Source : ${CLOUD_SQL_INSTANCE}/${CLOUD_SQL_DB}"
log "Target : localhost:${MYSQL_PORT}/${MYSQL_DATABASE}"

# ── 3. Authenticate with Google Cloud ────────────────────────────────────────
if [[ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" && -f "$GOOGLE_APPLICATION_CREDENTIALS" ]]; then
  log "Activating service account from $GOOGLE_APPLICATION_CREDENTIALS"
  gcloud auth activate-service-account \
    --key-file="$GOOGLE_APPLICATION_CREDENTIALS" >> "$LOG_FILE" 2>&1
else
  log "GOOGLE_APPLICATION_CREDENTIALS not set – assuming gcloud is already authenticated."
fi

# ── 4. Start Cloud SQL Auth Proxy ─────────────────────────────────────────────
PROXY_PORT="${CLOUD_SQL_PROXY_PORT:-3307}"
log "Starting Cloud SQL Auth Proxy on 127.0.0.1:${PROXY_PORT} …"

# Support both v1 (cloud_sql_proxy) and v2 (cloud-sql-proxy) binaries
if command -v cloud-sql-proxy &>/dev/null; then
  PROXY_CMD="cloud-sql-proxy"
  cloud-sql-proxy \
    "${CLOUD_SQL_INSTANCE}=tcp:127.0.0.1:${PROXY_PORT}" \
    >> "$LOG_FILE" 2>&1 &
elif command -v cloud_sql_proxy &>/dev/null; then
  PROXY_CMD="cloud_sql_proxy"
  cloud_sql_proxy \
    -instances="${CLOUD_SQL_INSTANCE}=tcp:127.0.0.1:${PROXY_PORT}" \
    >> "$LOG_FILE" 2>&1 &
else
  log "[ERROR] Neither cloud-sql-proxy nor cloud_sql_proxy found in PATH."
  exit 1
fi

PROXY_PID=$!
echo "$PROXY_PID" > "$PROXY_PID_FILE"
log "Proxy PID: $PROXY_PID – waiting for it to be ready …"
sleep 5   # give proxy time to establish IAM connection

# Ensure proxy is killed on any exit
cleanup() {
  log "Stopping Cloud SQL Auth Proxy (PID $PROXY_PID) …"
  kill "$PROXY_PID" 2>/dev/null || true
  rm -f "$PROXY_PID_FILE"
}
trap cleanup EXIT

# ── 5. Dump production database ───────────────────────────────────────────────
log "Dumping ${CLOUD_SQL_DB} via proxy port ${PROXY_PORT} …"
mysqldump \
  --host=127.0.0.1 \
  --port="$PROXY_PORT" \
  --user="$CLOUD_SQL_USER" \
  --password="$CLOUD_SQL_PASSWORD" \
  --single-transaction \
  --quick \
  --lock-tables=false \
  --skip-add-drop-database \
  --routines \
  --triggers \
  --events \
  "$CLOUD_SQL_DB" \
  | gzip > "$DUMP_FILE" 2>> "$LOG_FILE"

DUMP_SIZE=$(du -sh "$DUMP_FILE" | cut -f1)
log "Dump complete – ${DUMP_FILE} (${DUMP_SIZE})"

# ── 6. Restore into local MySQL (Docker container) ───────────────────────────
MYSQL_CONTAINER=$(docker ps --filter "name=mysql_local" --format "{{.Names}}" | head -1)

if [[ -z "$MYSQL_CONTAINER" ]]; then
  log "[ERROR] Local MySQL container (mysql_local) is not running. Run setup.sh first."
  exit 1
fi

log "Restoring dump into local container '${MYSQL_CONTAINER}' …"

# Create target DB if it doesn't exist
docker exec "$MYSQL_CONTAINER" \
  mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" \
  -e "CREATE DATABASE IF NOT EXISTS \`${MYSQL_DATABASE}\`;" >> "$LOG_FILE" 2>&1

# Pipe compressed dump directly into container
gunzip < "$DUMP_FILE" | docker exec -i "$MYSQL_CONTAINER" \
  mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" "${MYSQL_DATABASE}" >> "$LOG_FILE" 2>&1

log "Restore complete."

# ── 7. Clean up old backups (keep last 10) ────────────────────────────────────
log "Purging old backups (keeping last 10) …"
ls -tp "${BACKUP_DIR}"/dump_*.sql.gz 2>/dev/null \
  | tail -n +11 \
  | xargs -r rm --

log "========== Sync Finished Successfully =========="
log "Log: $LOG_FILE"
