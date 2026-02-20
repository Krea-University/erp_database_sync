#!/usr/bin/env bash
# =============================================================================
#  setup.sh  –  Bootstrap local MySQL and sync schedule
#    1. Start local MySQL via Docker Compose
#    2. Create MySQL users from MYSQL_USERS_JSON in .env
#    3. Register cron job for sync.sh every 2-3 hours
#    4. Run first sync immediately
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "[ERROR] .env not found. Copy .env.example → .env and fill it in."
  exit 1
fi
# shellcheck disable=SC1090
source "$ENV_FILE"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# ── 1. Dependency checks ──────────────────────────────────────────────────────
log "Checking dependencies …"
for cmd in docker docker-compose jq mysqldump; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "[ERROR] Required command not found: $cmd"
    exit 1
  fi
done
log "All dependencies OK."

# ── 2. Start local MySQL ──────────────────────────────────────────────────────
log "Starting local MySQL container …"
docker-compose -f "${SCRIPT_DIR}/docker-compose.yml" up -d mysql_local

log "Waiting for MySQL to be ready …"
RETRIES=30
until docker exec mysql_local \
    mysqladmin ping -uroot -p"${MYSQL_ROOT_PASSWORD}" --silent 2>/dev/null; do
  RETRIES=$((RETRIES - 1))
  if [[ $RETRIES -eq 0 ]]; then
    log "[ERROR] MySQL did not become ready. Check: docker-compose logs mysql_local"
    exit 1
  fi
  sleep 2
done
log "MySQL is ready."

# ── 3. Create MySQL users from MYSQL_USERS_JSON ───────────────────────────────
log "Creating MySQL users …"

if ! echo "${MYSQL_USERS_JSON}" | jq empty 2>/dev/null; then
  log "[ERROR] MYSQL_USERS_JSON in .env is not valid JSON."
  exit 1
fi

USER_COUNT=$(echo "${MYSQL_USERS_JSON}" | jq 'length')
log "Found ${USER_COUNT} user(s) to create."

for i in $(seq 0 $((USER_COUNT - 1))); do
  DB_USER=$(echo  "${MYSQL_USERS_JSON}" | jq -r ".[$i].user")
  DB_PASS=$(echo  "${MYSQL_USERS_JSON}" | jq -r ".[$i].password")
  DB_HOST=$(echo  "${MYSQL_USERS_JSON}" | jq -r ".[$i].host")
  DB_PRIVS=$(echo "${MYSQL_USERS_JSON}" | jq -r ".[$i].privileges")

  log "  → '${DB_USER}'@'${DB_HOST}'  [${DB_PRIVS}]"

  docker exec mysql_local mysql \
    -uroot -p"${MYSQL_ROOT_PASSWORD}" \
    -e "
      CREATE USER IF NOT EXISTS '${DB_USER}'@'${DB_HOST}'
        IDENTIFIED WITH mysql_native_password BY '${DB_PASS}';
      GRANT ${DB_PRIVS} ON \`${MYSQL_DATABASE}\`.* TO '${DB_USER}'@'${DB_HOST}';
      FLUSH PRIVILEGES;
    " 2>&1
done

log "Users created."

# ── 4. Register cron job ──────────────────────────────────────────────────────
SYNC_SCRIPT="${SCRIPT_DIR}/sync.sh"
chmod +x "$SYNC_SCRIPT"

if [[ -n "${SYNC_CRON_OVERRIDE:-}" ]]; then
  CRON_EXPR="${SYNC_CRON_OVERRIDE}"
else
  HOURS="${SYNC_INTERVAL_HOURS:-2}"
  CRON_EXPR="0 */${HOURS} * * *"
fi

CRON_LOG="${LOG_DIR:-/var/log/erp_sync}/cron.log"
mkdir -p "$(dirname "$CRON_LOG")"

CRON_LINE="${CRON_EXPR} /usr/bin/env bash ${SYNC_SCRIPT} >> ${CRON_LOG} 2>&1"
CRON_MARKER="# erp_database_sync"

(
  crontab -l 2>/dev/null | grep -v "$CRON_MARKER" || true
  echo "${CRON_MARKER}"
  echo "${CRON_LINE}"
) | crontab -

log "Cron registered: ${CRON_LINE}"

# ── 5. First sync ─────────────────────────────────────────────────────────────
log "Running initial sync …"
bash "$SYNC_SCRIPT"

log ""
log "╔══════════════════════════════════════════════════════╗"
log "║            Setup Complete                            ║"
log "╠══════════════════════════════════════════════════════╣"
log "║  Local MySQL  : localhost:${MYSQL_LOCAL_PORT:-3306}                  ║"
log "║  Database     : ${MYSQL_DATABASE}                          ║"
log "║  Sync cron    : ${CRON_EXPR}                    ║"
log "║  Logs         : ${LOG_DIR:-/var/log/erp_sync}                ║"
log "╚══════════════════════════════════════════════════════╝"
