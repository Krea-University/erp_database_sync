#!/usr/bin/env bash
# =============================================================================
#  setup.sh  –  Single entry-point: sets up EVERYTHING for Krea Onererp
#
#  Steps:
#   1. Validate .env
#   2. Install prerequisites  (Docker, Python, Flask, jq …)
#   3. Make all scripts executable
#   4. Start MySQL            (docker compose)
#   5. Configure MySQL        (native_password + users)
#   6. Register cron job      (duplicate-safe)
#   7. Enable MySQL auto-start (systemd)
#   8. Start MariaDB          (port 3307)
#   9. Run first sync
#  10. Start web dashboard    (Docker container)
#  11. Summary
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

# ── Colours ───────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log()  { echo -e "${CYAN}[$(date '+%H:%M:%S')]${RESET} $*"; }
ok()   { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn() { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
err()  { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
step() { echo -e "\n${BOLD}━━  $*  ━━${RESET}"; }

# ── 1. Validate .env ──────────────────────────────────────────────────────────
step "1 / 11  Validating .env"

if [[ ! -f "$ENV_FILE" ]]; then
  err ".env not found. Copy .env.example → .env and fill it in."
  err "  cp ${SCRIPT_DIR}/.env.example ${SCRIPT_DIR}/.env"
  exit 1
fi
# shellcheck disable=SC1090
source "$ENV_FILE"

for var in PROD_DB_HOST PROD_DB_USER PROD_DB_PASS MYSQL_ROOT_PASSWORD; do
  if [[ -z "${!var:-}" ]]; then
    err "\$$var is not set in .env"
    exit 1
  fi
done
ok ".env is valid."

# ── 2. Install prerequisites ──────────────────────────────────────────────────
step "2 / 11  Installing prerequisites"

PREREQ="${SCRIPT_DIR}/install_prerequisites.sh"
if [[ -f "$PREREQ" ]]; then
  chmod +x "$PREREQ"
  bash "$PREREQ"
else
  warn "install_prerequisites.sh not found — checking tools manually …"
  for tool in docker python3 pip3 jq; do
    command -v "$tool" &>/dev/null \
      && ok "${tool} found." \
      || { err "${tool} not found. Run: ./install_prerequisites.sh"; exit 1; }
  done
fi

# ── 3. Make all scripts executable ───────────────────────────────────────────
step "3 / 11  Setting script permissions"

for f in setup.sh sync.sh start_api.sh start_mariadb.sh \
          install_prerequisites.sh deploy_ubuntu.sh; do
  [[ -f "${SCRIPT_DIR}/${f}" ]] && chmod +x "${SCRIPT_DIR}/${f}" && ok "chmod +x ${f}"
done

# ── Detect docker compose v2 / v1 ────────────────────────────────────────────
if docker compose version &>/dev/null 2>&1; then
  COMPOSE="docker compose"
elif command -v docker-compose &>/dev/null; then
  COMPOSE="docker-compose"
else
  err "Neither 'docker compose' nor 'docker-compose' found."
  err "Run: sudo apt install docker-compose-plugin"
  exit 1
fi

# Detect jq — fall back to Docker image if not on host
if command -v jq &>/dev/null; then
  JQ="jq"
else
  JQ="docker run --rm -i ghcr.io/jqlang/jq:latest"
fi

# ── 4. Start MySQL ────────────────────────────────────────────────────────────
step "4 / 11  Starting MySQL (port ${MYSQL_LOCAL_PORT:-3306})"

${COMPOSE} -f "${SCRIPT_DIR}/docker-compose.yml" up -d mysql_local
log "Waiting for MySQL to be ready …"
RETRIES=30
until docker exec mysql_local \
    mysqladmin ping -uroot -p"${MYSQL_ROOT_PASSWORD}" --silent 2>/dev/null; do
  RETRIES=$((RETRIES - 1))
  [[ $RETRIES -eq 0 ]] && { err "MySQL did not become ready. Check: ${COMPOSE} logs mysql_local"; exit 1; }
  sleep 2
done
ok "MySQL is ready."

# ── 5. Configure MySQL ────────────────────────────────────────────────────────
step "5 / 11  Configuring MySQL users"

log "Setting root to mysql_native_password …"
docker exec mysql_local mysql \
  -uroot -p"${MYSQL_ROOT_PASSWORD}" \
  -e "
    ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${MYSQL_ROOT_PASSWORD}';
    ALTER USER 'root'@'%'         IDENTIFIED WITH mysql_native_password BY '${MYSQL_ROOT_PASSWORD}';
    FLUSH PRIVILEGES;
  " 2>/dev/null || true
ok "Root set to mysql_native_password."

if ! echo "${MYSQL_USERS_JSON}" | ${JQ} empty 2>/dev/null; then
  err "MYSQL_USERS_JSON in .env is not valid JSON."
  exit 1
fi

USER_COUNT=$(echo "${MYSQL_USERS_JSON}" | ${JQ} 'length')
log "Creating ${USER_COUNT} user(s) …"
for i in $(seq 0 $((USER_COUNT - 1))); do
  DB_USER=$(echo  "${MYSQL_USERS_JSON}" | ${JQ} -r ".[$i].user")
  DB_PASS=$(echo  "${MYSQL_USERS_JSON}" | ${JQ} -r ".[$i].password")
  DB_HOST=$(echo  "${MYSQL_USERS_JSON}" | ${JQ} -r ".[$i].host")
  DB_PRIVS=$(echo "${MYSQL_USERS_JSON}" | ${JQ} -r ".[$i].privileges")
  docker exec mysql_local mysql \
    -uroot -p"${MYSQL_ROOT_PASSWORD}" \
    -e "
      CREATE USER IF NOT EXISTS '${DB_USER}'@'${DB_HOST}'
        IDENTIFIED WITH mysql_native_password BY '${DB_PASS}';
      GRANT ${DB_PRIVS} ON *.* TO '${DB_USER}'@'${DB_HOST}';
      FLUSH PRIVILEGES;
    " 2>/dev/null
  ok "  User '${DB_USER}'@'${DB_HOST}'  [${DB_PRIVS}]"
done

# ── 6. Register cron job ──────────────────────────────────────────────────────
step "6 / 11  Registering sync cron job"

SYNC_SCRIPT="${SCRIPT_DIR}/sync.sh"
if [[ -n "${SYNC_CRON_OVERRIDE:-}" ]]; then
  CRON_EXPR="${SYNC_CRON_OVERRIDE}"
else
  CRON_EXPR="0 */${SYNC_INTERVAL_HOURS:-2} * * *"
fi

CRON_LOG="${LOG_DIR:-/var/erp_sync/logs}/cron.log"
mkdir -p "$(dirname "$CRON_LOG")"
CRON_LINE="${CRON_EXPR} /usr/bin/env bash ${SYNC_SCRIPT} >> ${CRON_LOG} 2>&1"
CRON_MARKER="# erp_database_sync"

if command -v crontab &>/dev/null; then
  (
    crontab -l 2>/dev/null | grep -Ev "${CRON_MARKER}|sync\.sh" || true
    echo "${CRON_MARKER}"
    echo "${CRON_LINE}"
  ) | crontab -
  ok "Cron registered: ${CRON_EXPR}"
else
  warn "crontab not available. Add manually to Task Scheduler:"
  warn "  bash ${SYNC_SCRIPT}"
fi

# ── 7. MySQL auto-start on boot ───────────────────────────────────────────────
step "7 / 11  Enabling MySQL auto-start on boot"

if command -v systemctl &>/dev/null; then
  SUDO_CMD=""; [[ "$EUID" -ne 0 ]] && SUDO_CMD="sudo"
  systemctl enable docker --now 2>/dev/null || true

  $SUDO_CMD bash -c "cat > /etc/systemd/system/mysql_local.service" <<EOF
[Unit]
Description=Krea Onererp — MySQL Local (port ${MYSQL_LOCAL_PORT:-3306})
Requires=docker.service
After=docker.service network-online.target
StartLimitIntervalSec=60
StartLimitBurst=3

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/docker start mysql_local
ExecStop=/usr/bin/docker stop  mysql_local
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

  $SUDO_CMD systemctl daemon-reload
  $SUDO_CMD systemctl enable mysql_local.service 2>/dev/null
  ok "mysql_local.service enabled."
else
  warn "systemd not found — skipping MySQL auto-start."
fi

# ── 8. Start MariaDB ──────────────────────────────────────────────────────────
step "8 / 11  Starting MariaDB (port 3307)"

MARIADB_SCRIPT="${SCRIPT_DIR}/start_mariadb.sh"
if [[ -f "$MARIADB_SCRIPT" ]]; then
  bash "$MARIADB_SCRIPT" start
else
  warn "start_mariadb.sh not found — skipping MariaDB."
fi

# ── 9. First sync ─────────────────────────────────────────────────────────────
step "9 / 11  Running initial database sync"

bash "$SYNC_SCRIPT"

# ── 10. Start web dashboard ───────────────────────────────────────────────────
step "10 / 11  Starting web dashboard"

START_API="${SCRIPT_DIR}/start_api.sh"
if [[ -f "$START_API" ]]; then
  bash "$START_API" restart
else
  warn "start_api.sh not found — skipping dashboard."
fi

# ── 11. Summary ───────────────────────────────────────────────────────────────
step "11 / 11  Done"

SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost")

echo ""
echo -e "${BOLD}"
echo    "╔══════════════════════════════════════════════════════════╗"
echo    "║          Krea Onererp — Setup Complete                   ║"
echo    "╠══════════════════════════════════════════════════════════╣"
echo -e "║  MySQL        : ${CYAN}${SERVER_IP}:${MYSQL_LOCAL_PORT:-3306}${RESET}"
echo -e "║  MariaDB      : ${CYAN}${SERVER_IP}:3307${RESET}"
echo -e "║  Sync cron    : ${CRON_EXPR}"
echo -e "║  Logs         : ${LOG_DIR:-/var/erp_sync/logs}"
echo -e "║  Dashboard    : ${CYAN}http://${SERVER_IP}:${API_PORT:-8080}${RESET}"
echo    "╚══════════════════════════════════════════════════════════╝"
echo -e "${RESET}"
echo    "  Open the dashboard and enter your API_TOKEN to connect."
echo    ""
