#!/usr/bin/env bash
# =============================================================================
#  sync.sh  –  Dump ALL remote MySQL databases (excluding system DBs)
#              → restore into local Docker MySQL
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
for var in PROD_DB_HOST PROD_DB_PORT PROD_DB_USER PROD_DB_PASS \
           MYSQL_ROOT_PASSWORD BACKUP_DIR LOG_DIR; do
  if [[ -z "${!var:-}" ]]; then
    echo "[ERROR] \$$var is not set in .env"
    exit 1
  fi
done

# ── Setup directories & logging ───────────────────────────────────────────────
mkdir -p "$BACKUP_DIR" "$LOG_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="${LOG_DIR}/sync_${TIMESTAMP}.log"
DUMP_FILE="${BACKUP_DIR}/dump_all_${TIMESTAMP}.sql.gz"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

log "========== ERP DB Sync Started (ALL databases) =========="
log "Source : ${PROD_DB_USER}@${PROD_DB_HOST}:${PROD_DB_PORT}"
log "Target : local Docker mysql_local"

# ── Discover all user databases (exclude system DBs) ─────────────────────────
log "Querying remote database list …"

SYSTEM_DBS="^(information_schema|performance_schema|mysql|sys)$"

# Use MYSQL_PWD so the password (with special chars) is never on the command line
DB_LIST=$(MYSQL_PWD="${PROD_DB_PASS}" mysql \
  --host="${PROD_DB_HOST}" \
  --port="${PROD_DB_PORT}" \
  --user="${PROD_DB_USER}" \
  --batch \
  --skip-column-names \
  -e "SHOW DATABASES;" 2>> "$LOG_FILE" \
  | grep -Ev "${SYSTEM_DBS}" \
  || true)

if [[ -z "$DB_LIST" ]]; then
  log "[ERROR] No user databases found on remote server. Check credentials and host."
  exit 1
fi

DB_COUNT=$(echo "$DB_LIST" | wc -l | tr -d ' ')
log "Found ${DB_COUNT} database(s) to sync:"
while IFS= read -r db; do
  log "  · ${db}"
done <<< "$DB_LIST"

# ── Dump all user databases in one pass ──────────────────────────────────────
log "Dumping ${DB_COUNT} database(s) …"

# Build space-separated list for --databases flag
DB_ARGS=$(echo "$DB_LIST" | tr '\n' ' ')

# shellcheck disable=SC2086
MYSQL_PWD="${PROD_DB_PASS}" mysqldump \
  --host="${PROD_DB_HOST}" \
  --port="${PROD_DB_PORT}" \
  --user="${PROD_DB_USER}" \
  --single-transaction \
  --quick \
  --lock-tables=false \
  --routines \
  --triggers \
  --events \
  --databases ${DB_ARGS} \
  | gzip > "$DUMP_FILE" 2>> "$LOG_FILE"

DUMP_SIZE=$(du -sh "$DUMP_FILE" | cut -f1)
log "Dump complete → ${DUMP_FILE} (${DUMP_SIZE})"

# ── Restore into local MySQL container ───────────────────────────────────────
MYSQL_CONTAINER=$(docker ps --filter "name=mysql_local" --format "{{.Names}}" | head -1)

if [[ -z "$MYSQL_CONTAINER" ]]; then
  log "[ERROR] Container 'mysql_local' is not running. Run: docker-compose up -d"
  exit 1
fi

log "Restoring all databases into '${MYSQL_CONTAINER}' …"

# --databases dump includes CREATE DATABASE IF NOT EXISTS + USE statements,
# so no need to specify a target database — pipe directly into MySQL
gunzip < "$DUMP_FILE" | docker exec -i "$MYSQL_CONTAINER" \
  mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" >> "$LOG_FILE" 2>&1

log "Restore complete."

# ── Verify restored databases ─────────────────────────────────────────────────
log "Verifying local databases …"
LOCAL_DBS=$(docker exec "$MYSQL_CONTAINER" \
  mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" \
  --batch --skip-column-names \
  -e "SHOW DATABASES;" 2>/dev/null \
  | grep -Ev "${SYSTEM_DBS}" \
  || true)

LOCAL_COUNT=$(echo "$LOCAL_DBS" | grep -c . || true)
log "Local MySQL now contains ${LOCAL_COUNT} user database(s):"
while IFS= read -r db; do
  [[ -z "$db" ]] && continue
  log "  · ${db}"
done <<< "$LOCAL_DBS"

# ── Prune old backups (keep last 10) ─────────────────────────────────────────
log "Pruning old backups (keeping last 10) …"
ls -tp "${BACKUP_DIR}"/dump_all_*.sql.gz 2>/dev/null \
  | tail -n +11 \
  | xargs -r rm --

log "========== Sync Finished =========="
log "Log: ${LOG_FILE}"
