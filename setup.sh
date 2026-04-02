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
if ! command -v docker &>/dev/null; then
  echo "[ERROR] 'docker' not found. Install Docker Desktop and try again."
  exit 1
fi

# Detect docker compose (v2 plugin) vs docker-compose (v1 standalone)
if docker compose version &>/dev/null 2>&1; then
  COMPOSE="docker compose"
elif command -v docker-compose &>/dev/null; then
  COMPOSE="docker-compose"
else
  echo "[ERROR] Neither 'docker compose' nor 'docker-compose' found."
  echo "        Install Docker Desktop (includes compose plugin) or run:"
  echo "        sudo apt install docker-compose-plugin"
  exit 1
fi
log "Using compose command: ${COMPOSE}"

# Detect jq — fall back to Docker image if not installed on host
if command -v jq &>/dev/null; then
  JQ="jq"
else
  log "jq not found on host — using Docker fallback (ghcr.io/jqlang/jq)"
  JQ="docker run --rm -i ghcr.io/jqlang/jq:latest"
fi

log "All dependencies OK."

# ── 2. Start local MySQL ──────────────────────────────────────────────────────
log "Starting local MySQL container …"
${COMPOSE} -f "${SCRIPT_DIR}/docker-compose.yml" up -d mysql_local

log "Waiting for MySQL to be ready …"
RETRIES=30
until docker exec mysql_local \
    mysqladmin ping -uroot -p"${MYSQL_ROOT_PASSWORD}" --silent 2>/dev/null; do
  RETRIES=$((RETRIES - 1))
  if [[ $RETRIES -eq 0 ]]; then
    log "[ERROR] MySQL did not become ready. Check: ${COMPOSE} logs mysql_local"
    exit 1
  fi
  sleep 2
done
log "MySQL is ready."

# ── 2b. Force root to mysql_native_password (required for SQLyog / old clients) ─
log "Setting root authentication to mysql_native_password …"
docker exec mysql_local mysql \
  -uroot -p"${MYSQL_ROOT_PASSWORD}" \
  -e "
    ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${MYSQL_ROOT_PASSWORD}';
    ALTER USER 'root'@'%'         IDENTIFIED WITH mysql_native_password BY '${MYSQL_ROOT_PASSWORD}';
    FLUSH PRIVILEGES;
  " 2>/dev/null || true
log "Root user set to mysql_native_password."

# ── 3. Create MySQL users from MYSQL_USERS_JSON ───────────────────────────────
log "Creating MySQL users …"

if ! echo "${MYSQL_USERS_JSON}" | ${JQ} empty 2>/dev/null; then
  log "[ERROR] MYSQL_USERS_JSON in .env is not valid JSON."
  exit 1
fi

USER_COUNT=$(echo "${MYSQL_USERS_JSON}" | ${JQ} 'length')
log "Found ${USER_COUNT} user(s) to create."

for i in $(seq 0 $((USER_COUNT - 1))); do
  DB_USER=$(echo  "${MYSQL_USERS_JSON}" | ${JQ} -r ".[$i].user")
  DB_PASS=$(echo  "${MYSQL_USERS_JSON}" | ${JQ} -r ".[$i].password")
  DB_HOST=$(echo  "${MYSQL_USERS_JSON}" | ${JQ} -r ".[$i].host")
  DB_PRIVS=$(echo "${MYSQL_USERS_JSON}" | ${JQ} -r ".[$i].privileges")

  log "  → '${DB_USER}'@'${DB_HOST}'  [${DB_PRIVS}]"

  docker exec mysql_local mysql \
    -uroot -p"${MYSQL_ROOT_PASSWORD}" \
    -e "
      CREATE USER IF NOT EXISTS '${DB_USER}'@'${DB_HOST}'
        IDENTIFIED WITH mysql_native_password BY '${DB_PASS}';
      GRANT ${DB_PRIVS} ON *.* TO '${DB_USER}'@'${DB_HOST}';
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

CRON_LOG="${LOG_DIR}/cron.log"
mkdir -p "$(dirname "$CRON_LOG")"

CRON_LINE="${CRON_EXPR} /usr/bin/env bash ${SYNC_SCRIPT} >> ${CRON_LOG} 2>&1"
CRON_MARKER="# erp_database_sync"

if command -v crontab &>/dev/null; then
  # Strip BOTH the marker comment AND any existing sync.sh cron line before re-adding,
  # so re-running setup.sh never creates duplicate crontab entries.
  (
    crontab -l 2>/dev/null | grep -Ev "${CRON_MARKER}|sync\.sh" || true
    echo "${CRON_MARKER}"
    echo "${CRON_LINE}"
  ) | crontab -
  log "Cron registered: ${CRON_LINE}"
else
  log "crontab not available (Windows detected)."
  log "Add a Windows Task Scheduler entry to run every ${SYNC_INTERVAL_HOURS:-2} hours:"
  log "  Program : bash"
  log "  Args    : ${SYNC_SCRIPT}"
  log "  Or run manually: bash ${SYNC_SCRIPT}"
fi

# ── 5. First sync ─────────────────────────────────────────────────────────────
log "Running initial sync …"
bash "$SYNC_SCRIPT"

# ── 6. Start web dashboard ────────────────────────────────────────────────────
START_API="${SCRIPT_DIR}/start_api.sh"

if [[ -f "$START_API" ]]; then
  chmod +x "$START_API"
  log "Starting web dashboard …"
  bash "$START_API" restart   # restart = stop any old instance + start fresh
else
  log "[WARN] start_api.sh not found — skipping dashboard start."
  log "       Start manually: python3 ${SCRIPT_DIR}/api.py"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost")

log ""
log "╔══════════════════════════════════════════════════════╗"
log "║        Krea Onererp — Setup Complete                 ║"
log "╠══════════════════════════════════════════════════════╣"
log "║  Local MySQL   : ${SERVER_IP}:${MYSQL_LOCAL_PORT:-3306}"
log "║  Databases     : ALL (system DBs excluded)"
log "║  Sync schedule : ${CRON_EXPR}"
log "║  Logs          : ${LOG_DIR:-/var/erp_sync/logs}"
log "║  Dashboard     : http://${SERVER_IP}:${API_PORT:-8080}"
log "╚══════════════════════════════════════════════════════╝"
log ""
log "  Open the dashboard and enter your API_TOKEN to connect."
