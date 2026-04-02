#!/usr/bin/env bash
# =============================================================================
#  start_api.sh  –  Manage the ERP Sync web dashboard (Python direct)
#
#  Usage:
#    ./start_api.sh              ← start (default)
#    ./start_api.sh start
#    ./start_api.sh stop
#    ./start_api.sh restart
#    ./start_api.sh status
#    ./start_api.sh logs         ← tail api.log
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_FILE="${SCRIPT_DIR}/.api.pid"
API_PY="${SCRIPT_DIR}/api.py"

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

  if [[ -f "${SCRIPT_DIR}/.env" ]]; then
    while IFS= read -r line; do
      [[ "$line" =~ ^[[:space:]]*# ]] && continue
      [[ "$line" =~ ^API_PORT=([0-9]+)$ ]] && API_PORT="${BASH_REMATCH[1]}"
      [[ "$line" =~ ^LOG_DIR=(.+)$      ]] && LOG_DIR="${BASH_REMATCH[1]//\'/}"
    done < "${SCRIPT_DIR}/.env"
  fi
}

# ── Helpers ───────────────────────────────────────────────────────────────────
server_ip() {
  hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost"
}

is_running() {
  [[ -f "$PID_FILE" ]] || return 1
  local pid; pid=$(cat "$PID_FILE")
  kill -0 "$pid" 2>/dev/null
}

# ── Auto-start on boot (systemd) ─────────────────────────────────────────────
enable_autostart() {
  if ! command -v systemctl &>/dev/null; then
    warn "systemd not found — skipping autostart setup."
    return
  fi

  load_env
  local UNIT="/etc/systemd/system/erp_api.service"
  local SUDO_CMD=""; [[ "$EUID" -ne 0 ]] && command -v sudo &>/dev/null && SUDO_CMD="sudo"
  local PYTHON_BIN; PYTHON_BIN=$(command -v python3)

  $SUDO_CMD bash -c "cat > ${UNIT}" <<EOF
[Unit]
Description=Krea Onererp — ERP Sync Dashboard
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${SCRIPT_DIR}
ExecStart=${PYTHON_BIN} ${API_PY}
Restart=always
RestartSec=5
StandardOutput=append:${LOG_DIR}/api.log
StandardError=append:${LOG_DIR}/api.log

[Install]
WantedBy=multi-user.target
EOF

  $SUDO_CMD systemctl daemon-reload
  $SUDO_CMD systemctl enable erp_api.service 2>/dev/null
  ok "Systemd service enabled: erp_api.service"
  ok "Dashboard will auto-start on every boot."
}

# ── Commands ──────────────────────────────────────────────────────────────────
cmd_start() {
  load_env

  if is_running; then
    warn "Dashboard already running (PID $(cat "$PID_FILE")). Use restart to reload."
    return
  fi

  if ! command -v python3 &>/dev/null; then
    err "python3 not found. Run: ./install_prerequisites.sh"
    exit 1
  fi

  if ! python3 -c "import flask" &>/dev/null 2>&1; then
    err "Flask not installed. Run: pip3 install -r ${SCRIPT_DIR}/requirements.txt"
    exit 1
  fi

  mkdir -p "${LOG_DIR}"
  local API_LOG="${LOG_DIR}/api.log"

  info "Starting dashboard (python3 api.py) …"
  nohup python3 "${API_PY}" >> "${API_LOG}" 2>&1 &
  local pid=$!
  echo "$pid" > "$PID_FILE"

  # Give Flask 4 s to bind, then confirm the process is still alive
  sleep 4
  if kill -0 "$pid" 2>/dev/null; then
    ok "Dashboard running (PID ${pid})  →  http://$(server_ip):${API_PORT}"
    ok "Log: ${API_LOG}"
    enable_autostart
  else
    err "Dashboard crashed at startup. Last log lines:"
    tail -20 "${API_LOG}" >&2
    rm -f "$PID_FILE"
    exit 1
  fi
}

cmd_stop() {
  if ! is_running; then
    warn "Dashboard is not running."
    return
  fi
  local pid; pid=$(cat "$PID_FILE")
  info "Stopping dashboard (PID ${pid}) …"
  kill "$pid" 2>/dev/null || true
  rm -f "$PID_FILE"
  ok "Dashboard stopped."
}

cmd_restart() {
  cmd_stop || true
  sleep 1
  cmd_start
}

cmd_status() {
  load_env
  echo ""
  echo -e "${BOLD}ERP Sync Dashboard — Status${RESET}"
  echo    "────────────────────────────────"
  if is_running; then
    echo -e "  State  : ${GREEN}● RUNNING${RESET}  (PID $(cat "$PID_FILE"))"
    echo -e "  URL    : ${CYAN}http://$(server_ip):${API_PORT}${RESET}"
  else
    echo -e "  State  : ${RED}○ STOPPED${RESET}"
    echo    "  Run    : ./start_api.sh start"
  fi
  echo ""
}

cmd_logs() {
  load_env
  local API_LOG="${LOG_DIR}/api.log"
  if [[ ! -f "$API_LOG" ]]; then
    warn "No log file at ${API_LOG}"
    return
  fi
  info "Tailing ${API_LOG}  (Ctrl+C to exit)"
  tail -f "${API_LOG}"
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
  *)
    echo "Usage: $0 [start|stop|restart|status|logs]"
    exit 1
    ;;
esac
