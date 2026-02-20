#!/usr/bin/env bash
# =============================================================================
#  sync.sh  –  Dump remote MySQL → restore into local Docker MySQL
#  Runs on-demand or via cron every 2-3 hours.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "[ERROR] .env not found at $ENV_FILE"
  exit 1
fi
# shellcheck disable=SC1090
source "$ENV_FILE"

# ── Validate required variables ───────────────────────────────────────────────
for var in PROD_DB_HOST PROD_DB_PORT PROD_DB_NAME PROD_DB_USER PROD_DB_PASS \
           MYSQL_ROOT_PASSWORD MYSQL_DATABASE BACKUP_DIR LOG_DIR; do
  if [[ -z "${!var:-}" ]]; then
    echo "[ERROR] \$$var is not set in .env"
    exit 1
  fi
done

# ── Setup directories & logging ───────────────────────────────────────────────
mkdir -p "$BACKUP_DIR" "$LOG_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="${LOG_DIR}/sync_${TIMESTAMP}.log"
DUMP_FILE="${BACKUP_DIR}/dump_${TIMESTAMP}.sql.gz"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

log "========== ERP DB Sync Started =========="
log "Source : ${PROD_DB_USER}@${PROD_DB_HOST}:${PROD_DB_PORT}/${PROD_DB_NAME}"
log "Target : localhost:${MYSQL_LOCAL_PORT:-3306}/${MYSQL_DATABASE}"

# ── Dump remote database directly ────────────────────────────────────────────
log "Dumping remote database …"

# Password with special characters — pass via env var to avoid shell quoting issues
MYSQL_PWD="${PROD_DB_PASS}" mysqldump \
  --host="${PROD_DB_HOST}" \
  --port="${PROD_DB_PORT}" \
  --user="${PROD_DB_USER}" \
  --single-transaction \
  --quick \
  --lock-tables=false \
  --skip-add-drop-database \
  --routines \
  --triggers \
  --events \
  "${PROD_DB_NAME}" \
  | gzip > "$DUMP_FILE" 2>> "$LOG_FILE"

DUMP_SIZE=$(du -sh "$DUMP_FILE" | cut -f1)
log "Dump complete → ${DUMP_FILE} (${DUMP_SIZE})"

# ── Restore into local MySQL container ───────────────────────────────────────
MYSQL_CONTAINER=$(docker ps --filter "name=mysql_local" --format "{{.Names}}" | head -1)

if [[ -z "$MYSQL_CONTAINER" ]]; then
  log "[ERROR] Container 'mysql_local' is not running. Run: docker-compose up -d"
  exit 1
fi

log "Restoring into '${MYSQL_CONTAINER}' …"

docker exec "$MYSQL_CONTAINER" \
  mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" \
  -e "CREATE DATABASE IF NOT EXISTS \`${MYSQL_DATABASE}\`;" >> "$LOG_FILE" 2>&1

gunzip < "$DUMP_FILE" | docker exec -i "$MYSQL_CONTAINER" \
  mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" "${MYSQL_DATABASE}" >> "$LOG_FILE" 2>&1

log "Restore complete."

# ── Prune old backups (keep last 10) ─────────────────────────────────────────
log "Pruning old backups …"
ls -tp "${BACKUP_DIR}"/dump_*.sql.gz 2>/dev/null \
  | tail -n +11 \
  | xargs -r rm --

log "========== Sync Finished =========="
log "Log: ${LOG_FILE}"
