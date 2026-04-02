#!/usr/bin/env bash
# =============================================================================
#  start_mariadb.sh  –  Run a MariaDB instance on port 3307
#  Credentials are loaded from .env (same root password + users as MySQL)
#
#  Usage:
#    ./start_mariadb.sh              ← start (default)
#    ./start_mariadb.sh start
#    ./start_mariadb.sh stop
#    ./start_mariadb.sh restart
#    ./start_mariadb.sh status
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

CONTAINER_NAME="mariadb_local"
MARIADB_PORT=3307
MARIADB_IMAGE="mariadb:11.8"
VOLUME_NAME="erp_mariadb_data"

# ── Colours ───────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

ok()   { echo -e "${GREEN}[OK]${RESET}    $*"; }
info() { echo -e "${CYAN}[INFO]${RESET}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
err()  { echo -e "${RED}[ERROR]${RESET} $*" >&2; }

# ── Load credentials from .env ────────────────────────────────────────────────
load_env() {
  if [[ ! -f "$ENV_FILE" ]]; then
    err ".env not found at ${ENV_FILE}"
    exit 1
  fi
  # shellcheck disable=SC1090
  source "$ENV_FILE"

  if [[ -z "${MYSQL_ROOT_PASSWORD:-}" ]]; then
    err "MYSQL_ROOT_PASSWORD is not set in .env"
    exit 1
  fi
}

# ── Wait for MariaDB to be ready ──────────────────────────────────────────────
wait_ready() {
  info "Waiting for MariaDB to be ready …"
  local retries=30
  until docker exec "$CONTAINER_NAME" \
      mysqladmin ping -uroot -p"${MYSQL_ROOT_PASSWORD}" --silent 2>/dev/null; do
    retries=$((retries - 1))
    if [[ $retries -eq 0 ]]; then
      err "MariaDB did not become ready. Check: docker logs ${CONTAINER_NAME}"
      exit 1
    fi
    sleep 2
  done
  ok "MariaDB is ready."
}

# ── Create users from MYSQL_USERS_JSON ───────────────────────────────────────
create_users() {
  [[ -z "${MYSQL_USERS_JSON:-}" ]] && return

  # Detect jq
  if command -v jq &>/dev/null; then
    JQ="jq"
  else
    JQ="docker run --rm -i ghcr.io/jqlang/jq:latest"
  fi

  local count
  count=$(echo "${MYSQL_USERS_JSON}" | ${JQ} 'length')
  info "Creating ${count} user(s) in MariaDB …"

  for i in $(seq 0 $((count - 1))); do
    local db_user db_pass db_host db_privs
    db_user=$(echo  "${MYSQL_USERS_JSON}" | ${JQ} -r ".[$i].user")
    db_pass=$(echo  "${MYSQL_USERS_JSON}" | ${JQ} -r ".[$i].password")
    db_host=$(echo  "${MYSQL_USERS_JSON}" | ${JQ} -r ".[$i].host")
    db_privs=$(echo "${MYSQL_USERS_JSON}" | ${JQ} -r ".[$i].privileges")

    docker exec "$CONTAINER_NAME" mysql \
      -uroot -p"${MYSQL_ROOT_PASSWORD}" \
      -e "
        CREATE USER IF NOT EXISTS '${db_user}'@'${db_host}'
          IDENTIFIED VIA mysql_native_password USING PASSWORD('${db_pass}');
        GRANT ${db_privs} ON *.* TO '${db_user}'@'${db_host}';
        FLUSH PRIVILEGES;
      " 2>/dev/null && ok "  User '${db_user}'@'${db_host}' ready." || \
      warn "  Could not create user '${db_user}' (may already exist)."
  done
}

# ── Commands ──────────────────────────────────────────────────────────────────
cmd_start() {
  load_env

  if docker ps --filter "name=^${CONTAINER_NAME}$" --format "{{.Names}}" | grep -q "^${CONTAINER_NAME}$"; then
    warn "Container '${CONTAINER_NAME}' is already running."
    info "Port : ${MARIADB_PORT}"
    return
  fi

  # Remove stopped container with the same name if it exists
  if docker ps -a --filter "name=^${CONTAINER_NAME}$" --format "{{.Names}}" | grep -q "^${CONTAINER_NAME}$"; then
    info "Removing stopped container '${CONTAINER_NAME}' …"
    docker rm "${CONTAINER_NAME}"
  fi

  info "Pulling image ${MARIADB_IMAGE} …"
  docker pull "${MARIADB_IMAGE}" --quiet

  info "Starting MariaDB on port ${MARIADB_PORT} …"
  docker run -d \
    --name  "${CONTAINER_NAME}" \
    --restart unless-stopped \
    -p "0.0.0.0:${MARIADB_PORT}:3306" \
    -v "${VOLUME_NAME}:/var/lib/mysql" \
    -e "MARIADB_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}" \
    -e "MARIADB_ROOT_HOST=%" \
    -e "TZ=Asia/Kolkata" \
    "${MARIADB_IMAGE}" \
    --default-authentication-plugin=mysql_native_password \
    --character-set-server=utf8mb4 \
    --collation-server=utf8mb4_unicode_ci

  wait_ready

  # Force root to use mysql_native_password (plain password — SQLyog / old client safe)
  info "Setting root authentication to mysql_native_password …"
  docker exec "$CONTAINER_NAME" mysql \
    -uroot -p"${MYSQL_ROOT_PASSWORD}" \
    -e "
      ALTER USER 'root'@'localhost' IDENTIFIED VIA mysql_native_password USING PASSWORD('${MYSQL_ROOT_PASSWORD}');
      ALTER USER 'root'@'%'         IDENTIFIED VIA mysql_native_password USING PASSWORD('${MYSQL_ROOT_PASSWORD}');
      FLUSH PRIVILEGES;
    " 2>/dev/null || true
  ok "Root set to mysql_native_password."

  create_users

  ok "MariaDB started on port ${MARIADB_PORT}"
  ok "Connect: mysql -h 127.0.0.1 -P ${MARIADB_PORT} -uroot -p'${MYSQL_ROOT_PASSWORD}'"
}

cmd_stop() {
  if ! docker ps --filter "name=^${CONTAINER_NAME}$" --format "{{.Names}}" | grep -q "^${CONTAINER_NAME}$"; then
    warn "'${CONTAINER_NAME}' is not running."
    return
  fi
  info "Stopping ${CONTAINER_NAME} …"
  docker stop "${CONTAINER_NAME}"
  ok "MariaDB stopped."
}

cmd_restart() {
  cmd_stop || true
  sleep 1
  cmd_start
}

cmd_status() {
  load_env
  echo ""
  echo -e "${BOLD}MariaDB Local — Status${RESET}"
  echo    "──────────────────────────────"
  if docker ps --filter "name=^${CONTAINER_NAME}$" --format "{{.Names}}" | grep -q "^${CONTAINER_NAME}$"; then
    local server_ip
    server_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost")
    echo -e "  State  : ${GREEN}● RUNNING${RESET}"
    echo -e "  Host   : ${CYAN}${server_ip}:${MARIADB_PORT}${RESET}"
    echo -e "  Volume : ${VOLUME_NAME}"
  else
    echo -e "  State  : ${RED}○ STOPPED${RESET}"
    echo    "  Run    : ./start_mariadb.sh start"
  fi
  echo ""
}

# ── Entry ─────────────────────────────────────────────────────────────────────
echo -e "${BOLD}"
echo "╔══════════════════════════════════════════╗"
echo "║   Krea Onererp — MariaDB Local (3307)    ║"
echo "╚══════════════════════════════════════════╝"
echo -e "${RESET}"

case "${1:-start}" in
  start)   cmd_start ;;
  stop)    cmd_stop ;;
  restart) cmd_restart ;;
  status)  cmd_status ;;
  *)
    echo "Usage: $0 [start|stop|restart|status]"
    exit 1
    ;;
esac
