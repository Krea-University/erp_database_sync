#!/usr/bin/env bash
# =============================================================================
#  start_api.sh  –  Manage the ERP Sync web dashboard (api.py)
#
#  Usage:
#    ./start_api.sh              ← start (default)
#    ./start_api.sh start
#    ./start_api.sh stop
#    ./start_api.sh restart
#    ./start_api.sh status
#    ./start_api.sh logs         ← tail -f the API log
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API_SCRIPT="${SCRIPT_DIR}/api.py"
PID_FILE="${SCRIPT_DIR}/.api.pid"

# ── Colours ───────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

ok()   { echo -e "${GREEN}[OK]${RESET}    $*"; }
info() { echo -e "${CYAN}[INFO]${RESET}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
err()  { echo -e "${RED}[ERROR]${RESET} $*" >&2; }

# ── Load .env (only safe simple vars) ────────────────────────────────────────
load_env() {
  API_PORT=8080
  LOG_DIR="${SCRIPT_DIR}/logs"
  if [[ -f "${SCRIPT_DIR}/.env" ]]; then
    while IFS= read -r line; do
      [[ "$line" =~ ^[[:space:]]*# ]] && continue
      [[ "$line" =~ ^API_PORT=([0-9]+)$ ]]  && API_PORT="${BASH_REMATCH[1]}"
      [[ "$line" =~ ^LOG_DIR=(.+)$ ]]       && LOG_DIR="${BASH_REMATCH[1]//\'/}"
    done < "${SCRIPT_DIR}/.env"
  fi
}

# ── Get server IP ─────────────────────────────────────────────────────────────
server_ip() {
  hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost"
}

# ── Check dependencies ────────────────────────────────────────────────────────
check_deps() {
  if ! command -v python3 &>/dev/null; then
    err "python3 not found. Run: ./install_prerequisites.sh"
    exit 1
  fi
  if ! python3 -c "import flask" &>/dev/null 2>&1; then
    info "Flask not installed — installing from requirements.txt …"
    pip3 install -r "${SCRIPT_DIR}/requirements.txt"
  fi
}

# ── Get PID of running process (empty if not running) ─────────────────────────
running_pid() {
  if [[ -f "$PID_FILE" ]]; then
    local pid; pid=$(cat "$PID_FILE")
    if kill -0 "$pid" 2>/dev/null; then
      echo "$pid"
      return
    fi
    rm -f "$PID_FILE"   # stale pid file
  fi
  echo ""
}

# ── Commands ──────────────────────────────────────────────────────────────────
cmd_start() {
  load_env
  local pid; pid=$(running_pid)

  if [[ -n "$pid" ]]; then
    warn "Dashboard is already running (PID ${pid})"
    info "URL  : http://$(server_ip):${API_PORT}"
    return
  fi

  check_deps

  if [[ ! -f "$API_SCRIPT" ]]; then
    err "api.py not found at: ${API_SCRIPT}"
    exit 1
  fi

  mkdir -p "$LOG_DIR"
  local api_log="${LOG_DIR}/api.log"

  info "Starting ERP Sync Dashboard …"
  nohup python3 "$API_SCRIPT" >> "$api_log" 2>&1 &
  local new_pid=$!
  echo "$new_pid" > "$PID_FILE"

  sleep 2   # give Python a moment to bind the port

  if kill -0 "$new_pid" 2>/dev/null; then
    ok "Dashboard started  (PID ${new_pid})"
    ok "URL  : http://$(server_ip):${API_PORT}"
    ok "Log  : ${api_log}"
  else
    err "Dashboard failed to start. Check log: ${api_log}"
    rm -f "$PID_FILE"
    exit 1
  fi
}

cmd_stop() {
  local pid; pid=$(running_pid)
  if [[ -z "$pid" ]]; then
    warn "Dashboard is not running."
    return
  fi
  info "Stopping dashboard (PID ${pid}) …"
  kill "$pid" && rm -f "$PID_FILE"
  ok "Dashboard stopped."
}

cmd_restart() {
  cmd_stop || true
  sleep 1
  cmd_start
}

cmd_status() {
  load_env
  local pid; pid=$(running_pid)
  echo ""
  echo -e "${BOLD}ERP Sync Dashboard — Status${RESET}"
  echo    "────────────────────────────────"
  if [[ -n "$pid" ]]; then
    echo -e "  State  : ${GREEN}● RUNNING${RESET}  (PID ${pid})"
    echo -e "  URL    : ${CYAN}http://$(server_ip):${API_PORT}${RESET}"
  else
    echo -e "  State  : ${RED}○ STOPPED${RESET}"
    echo    "  Run    : ./start_api.sh start"
  fi
  echo ""
}

cmd_logs() {
  load_env
  local api_log="${LOG_DIR}/api.log"
  if [[ ! -f "$api_log" ]]; then
    warn "No API log found at: ${api_log}"
    warn "The dashboard may not have been started yet."
    return
  fi
  info "Tailing ${api_log}  (Ctrl+C to exit)"
  tail -f "$api_log"
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
