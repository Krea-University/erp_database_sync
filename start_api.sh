#!/usr/bin/env bash
# =============================================================================
#  start_api.sh  –  Manage the ERP Sync web dashboard (Docker container)
#
#  Usage:
#    ./start_api.sh              ← build + start (default)
#    ./start_api.sh start
#    ./start_api.sh stop
#    ./start_api.sh restart
#    ./start_api.sh status
#    ./start_api.sh logs         ← docker logs -f
#    ./start_api.sh build        ← rebuild image only
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINER_NAME="erp_api"
IMAGE_NAME="erp_api"

# ── Colours ───────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

ok()   { echo -e "${GREEN}[OK]${RESET}    $*"; }
info() { echo -e "${CYAN}[INFO]${RESET}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
err()  { echo -e "${RED}[ERROR]${RESET} $*" >&2; }

# ── Load vars from .env ───────────────────────────────────────────────────────
load_env() {
  API_PORT=8080
  LOG_DIR="${SCRIPT_DIR}/logs"
  BACKUP_DIR="${SCRIPT_DIR}/backups"

  if [[ -f "${SCRIPT_DIR}/.env" ]]; then
    while IFS= read -r line; do
      [[ "$line" =~ ^[[:space:]]*# ]] && continue
      [[ "$line" =~ ^API_PORT=([0-9]+)$     ]] && API_PORT="${BASH_REMATCH[1]}"
      [[ "$line" =~ ^LOG_DIR=(.+)$          ]] && LOG_DIR="${BASH_REMATCH[1]//\'/}"
      [[ "$line" =~ ^BACKUP_DIR=(.+)$       ]] && BACKUP_DIR="${BASH_REMATCH[1]//\'/}"
    done < "${SCRIPT_DIR}/.env"
  fi
}

# ── Get server IP ─────────────────────────────────────────────────────────────
server_ip() {
  hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost"
}

# ── Auto-start on boot (systemd) ─────────────────────────────────────────────
enable_autostart() {
  if ! command -v systemctl &>/dev/null; then
    warn "systemd not found — skipping autostart setup."
    return
  fi

  systemctl enable docker --now 2>/dev/null || true

  local UNIT="/etc/systemd/system/${CONTAINER_NAME}.service"
  local SUDO_CMD=""; [[ "$EUID" -ne 0 ]] && SUDO_CMD="sudo"

  $SUDO_CMD bash -c "cat > ${UNIT}" <<EOF
[Unit]
Description=Krea Onererp — ERP Sync Dashboard
Requires=docker.service
After=docker.service network-online.target
StartLimitIntervalSec=60
StartLimitBurst=3

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/docker start ${CONTAINER_NAME}
ExecStop=/usr/bin/docker stop  ${CONTAINER_NAME}
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

  $SUDO_CMD systemctl daemon-reload
  $SUDO_CMD systemctl enable "${CONTAINER_NAME}.service" 2>/dev/null
  ok "Systemd service enabled: ${CONTAINER_NAME}.service"
  ok "Dashboard will auto-start on every boot."
}

# ── Commands ──────────────────────────────────────────────────────────────────
cmd_build() {
  info "Building Docker image '${IMAGE_NAME}' …"
  docker build -t "${IMAGE_NAME}" "${SCRIPT_DIR}"
  ok "Image '${IMAGE_NAME}' built."
}

cmd_start() {
  load_env

  cmd_build

  # Remove any existing container (running or stopped)
  if docker ps -a --filter "name=^${CONTAINER_NAME}$" --format "{{.Names}}" | grep -q "^${CONTAINER_NAME}$"; then
    info "Removing existing container '${CONTAINER_NAME}' …"
    docker rm -f "${CONTAINER_NAME}"
  fi

  # Ensure host directories exist before bind-mounting
  mkdir -p "${LOG_DIR}" "${BACKUP_DIR}"
  # crontab dir may not exist on fresh Ubuntu installs
  local SUDO_CMD=""; [[ "$EUID" -ne 0 ]] && command -v sudo &>/dev/null && SUDO_CMD="sudo"
  $SUDO_CMD mkdir -p /var/spool/cron/crontabs 2>/dev/null || \
    warn "/var/spool/cron/crontabs not writable — cron control from dashboard will be limited."

  info "Starting dashboard container …"
  docker run -d \
    --name "${CONTAINER_NAME}" \
    --restart unless-stopped \
    --add-host=host.docker.internal:host-gateway \
    -p "0.0.0.0:${API_PORT}:8080" \
    -v "${SCRIPT_DIR}/.env:/app/.env:ro" \
    -v "${SCRIPT_DIR}/sync.sh:/app/sync.sh:ro" \
    -v "${LOG_DIR}:${LOG_DIR}" \
    -v "${BACKUP_DIR}:${BACKUP_DIR}" \
    -v "/var/spool/cron/crontabs:/var/spool/cron/crontabs" \
    -v "/var/run/docker.sock:/var/run/docker.sock" \
    "${IMAGE_NAME}"

  # Wait for Flask to be ready (up to 20 s)
  info "Waiting for dashboard to be ready …"
  local ready=0
  for i in $(seq 1 20); do
    if docker ps --filter "name=^${CONTAINER_NAME}$" \
                 --filter "status=running" \
                 --format "{{.Names}}" | grep -q "^${CONTAINER_NAME}$"; then
      ready=1
      break
    fi
    sleep 1
  done

  if [[ $ready -eq 1 ]]; then
    ok "Dashboard running  →  http://$(server_ip):${API_PORT}"
    enable_autostart
  else
    err "Container failed to start. Logs:"
    docker logs "${CONTAINER_NAME}" 2>&1 | tail -30 >&2
    exit 1
  fi
}

cmd_stop() {
  if docker ps -a --filter "name=^${CONTAINER_NAME}$" --format "{{.Names}}" | grep -q "^${CONTAINER_NAME}$"; then
    info "Stopping and removing '${CONTAINER_NAME}' …"
    docker rm -f "${CONTAINER_NAME}"
    ok "Dashboard stopped."
  else
    warn "Dashboard is not running."
  fi
}

cmd_restart() {
  cmd_stop || true
  cmd_start
}

cmd_status() {
  load_env
  echo ""
  echo -e "${BOLD}ERP Sync Dashboard — Status${RESET}"
  echo    "────────────────────────────────"
  if docker ps --filter "name=^${CONTAINER_NAME}$" --format "{{.Names}}" | grep -q "^${CONTAINER_NAME}$"; then
    echo -e "  State  : ${GREEN}● RUNNING${RESET}  (Docker container)"
    echo -e "  URL    : ${CYAN}http://$(server_ip):${API_PORT}${RESET}"
    echo -e "  Image  : ${IMAGE_NAME}"
  else
    echo -e "  State  : ${RED}○ STOPPED${RESET}"
    echo    "  Run    : ./start_api.sh start"
  fi
  echo ""
}

cmd_logs() {
  if ! docker ps --filter "name=^${CONTAINER_NAME}$" --format "{{.Names}}" | grep -q "^${CONTAINER_NAME}$"; then
    warn "Dashboard container is not running."
    return
  fi
  info "Streaming logs from '${CONTAINER_NAME}'  (Ctrl+C to exit)"
  docker logs -f "${CONTAINER_NAME}"
}

# ── Entry ─────────────────────────────────────────────────────────────────────
echo -e "${BOLD}"
echo "╔══════════════════════════════════════════╗"
echo "║   Krea Onererp — ERP Sync Dashboard      ║"
echo "╚══════════════════════════════════════════╝"
echo -e "${RESET}"

case "${1:-start}" in
  start)   cmd_start ;;
  stop)    cmd_stop ;;
  restart) cmd_restart ;;
  status)  cmd_status ;;
  logs)    cmd_logs ;;
  build)   cmd_build ;;
  *)
    echo "Usage: $0 [start|stop|restart|status|logs|build]"
    exit 1
    ;;
esac
