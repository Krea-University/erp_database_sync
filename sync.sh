#!/usr/bin/env bash
# =============================================================================
#  sync.sh  –  Dump ALL remote MySQL databases (excluding system DBs)
#              → restore into local Docker MySQL
#  Uses the mysql_local Docker container as the MySQL client —
#  no mysql/mysqldump install required on the host.
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

# ── Prune function — always runs on EXIT (success or failure) ─────────────────
prune_on_exit() {
  local keep_days="${BACKUP_KEEP_DAYS:-1}"
  local keep_count="${BACKUP_KEEP_COUNT:-3}"
  local log_keep="${LOG_KEEP_COUNT:-14}"
  local _log="${LOG_FILE:-/dev/stderr}"

  # ── Prune backups ──────────────────────────────────────────────────────────
  if [[ -n "${BACKUP_DIR:-}" && -d "$BACKUP_DIR" ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Pruning backups (keep last ${keep_days}d / max ${keep_count} files) …" | tee -a "$_log"
    local before; before=$(du -sh "${BACKUP_DIR}" 2>/dev/null | cut -f1)

    # Age-based: delete files older than KEEP_DAYS days
    find "${BACKUP_DIR}" -name "dump_all_*.sql.gz" -mtime "+${keep_days}" -delete 2>/dev/null || true

    # Count-based: keep only the newest KEEP_COUNT files
    local extras
    extras=$(ls -t "${BACKUP_DIR}"/dump_all_*.sql.gz 2>/dev/null | tail -n "+$((keep_count + 1))")
    if [[ -n "$extras" ]]; then
      echo "$extras" | xargs rm -f
    fi

    local after; after=$(du -sh "${BACKUP_DIR}" 2>/dev/null | cut -f1)
    local remaining; remaining=$(ls "${BACKUP_DIR}"/dump_all_*.sql.gz 2>/dev/null | wc -l | tr -d ' ')
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Backup dir: ${before} → ${after}  (${remaining} file(s) kept)" | tee -a "$_log"
  fi

  # ── Prune logs: keep newest LOG_KEEP_COUNT sync logs ──────────────────────
  if [[ -n "${LOG_DIR:-}" && -d "$LOG_DIR" ]]; then
    local log_extras
    log_extras=$(ls -t "${LOG_DIR}"/sync_*.log 2>/dev/null | tail -n "+$((log_keep + 1))")
    if [[ -n "$log_extras" ]]; then
      local log_count; log_count=$(echo "$log_extras" | wc -l | tr -d ' ')
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] Removing ${log_count} old log file(s)" | tee -a "$_log"
      echo "$log_extras" | xargs rm -f
    fi
  fi
}
trap prune_on_exit EXIT

log "========== ERP DB Sync Started (ALL databases) =========="
log "Source : ${PROD_DB_USER}@${PROD_DB_HOST}:${PROD_DB_PORT}"
log "Target : local Docker mysql_local"

# ── Verify container is running ───────────────────────────────────────────────
MYSQL_CONTAINER=$(docker ps --filter "name=mysql_local" --format "{{.Names}}" | head -1)
if [[ -z "$MYSQL_CONTAINER" ]]; then
  log "[ERROR] Container 'mysql_local' is not running. Run: docker compose up -d"
  exit 1
fi

# ── Discover all user databases via Docker container client ───────────────────
log "Querying remote database list …"

SYSTEM_DBS="^(information_schema|performance_schema|mysql|sys)$"

DB_LIST=$(docker exec "$MYSQL_CONTAINER" \
  mysql \
  --host="${PROD_DB_HOST}" \
  --port="${PROD_DB_PORT}" \
  --user="${PROD_DB_USER}" \
  --password="${PROD_DB_PASS}" \
  --batch \
  --skip-column-names \
  -e "SHOW DATABASES;" 2>> "$LOG_FILE" \
  | grep -Ev "${SYSTEM_DBS}" \
  || true)

if [[ -z "$DB_LIST" ]]; then
  log "[ERROR] No user databases found. Check PROD_DB_* credentials in .env"
  log "        See log for details: ${LOG_FILE}"
  exit 1
fi

DB_COUNT=$(echo "$DB_LIST" | wc -l | tr -d ' ')
log "Found ${DB_COUNT} database(s) to sync:"
while IFS= read -r db; do
  log "  · ${db}"
done <<< "$DB_LIST"

# ── Dump all databases via Docker container client ────────────────────────────
log "Dumping ${DB_COUNT} database(s) …"

DB_ARGS=$(echo "$DB_LIST" | tr '\n' ' ')

# shellcheck disable=SC2086
docker exec "$MYSQL_CONTAINER" \
  mysqldump \
  --host="${PROD_DB_HOST}" \
  --port="${PROD_DB_PORT}" \
  --user="${PROD_DB_USER}" \
  --password="${PROD_DB_PASS}" \
  --single-transaction \
  --quick \
  --lock-tables=false \
  --routines \
  --triggers \
  --events \
  --set-gtid-purged=OFF \
  --databases ${DB_ARGS} \
  2>> "$LOG_FILE" \
  | gzip > "$DUMP_FILE"

DUMP_SIZE=$(du -sh "$DUMP_FILE" | cut -f1)
log "Dump complete → ${DUMP_FILE} (${DUMP_SIZE})"

# ── Restore into local MySQL container ───────────────────────────────────────
log "Restoring all databases into '${MYSQL_CONTAINER}' …"

gunzip < "$DUMP_FILE" | docker exec -i "$MYSQL_CONTAINER" \
  mysql --force -uroot -p"${MYSQL_ROOT_PASSWORD}" >> "$LOG_FILE" 2>&1 || true

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
log "Local MySQL now has ${LOCAL_COUNT} user database(s):"
while IFS= read -r db; do
  [[ -z "$db" ]] && continue
  log "  · ${db}"
done <<< "$LOCAL_DBS"

log "========== Sync Finished =========="
log "Log: ${LOG_FILE}"
# prune_on_exit fires automatically via trap EXIT
