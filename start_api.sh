#!/usr/bin/env bash
# =============================================================================
#  start_api.sh  –  Manage the ERP Sync web dashboard
#
#  The dashboard runs as a systemd service (erp_api.service):
#    · restarts automatically within 3s if it ever crashes
#    · starts on boot — no login or manual ./start_api.sh needed
#  Without systemd it falls back to a watchdog loop + @reboot cron entry.
#
#  Usage:
#    ./start_api.sh              ← start (default) — installs/refreshes service
#    ./start_api.sh start
#    ./start_api.sh stop
#    ./start_api.sh restart
#    ./start_api.sh status
#    ./start_api.sh logs         ← tail api.log
#    ./start_api.sh uninstall    ← remove the service / autostart
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_FILE="${SCRIPT_DIR}/.api.pid"
API_PY="${SCRIPT_DIR}/api.py"
VENV="${SCRIPT_DIR}/.venv"
REQ="${SCRIPT_DIR}/requirements.txt"
SERVICE="erp_api.service"
UNIT="/etc/systemd/system/${SERVICE}"
CRON_TAG="# erp_api_autostart"

# ── Colours ───────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

ok()   { echo -e "${GREEN}[OK]${RESET}    $*"; }
info() { echo -e "${CYAN}[INFO]${RESET}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
err()  { echo -e "${RED}[ERROR]${RESET} $*" >&2; }

SUDO=""; [[ "$EUID" -ne 0 ]] && command -v sudo &>/dev/null && SUDO="sudo"
RUN_USER="${SUDO_USER:-$(id -un)}"
RUN_GROUP="$(id -gn "$RUN_USER")"

# ── Load vars from .env ───────────────────────────────────────────────────────
load_env() {
  API_PORT=8080
  LOG_DIR="${SCRIPT_DIR}/logs"
  if [[ -f "${SCRIPT_DIR}/.env" ]]; then
    while IFS= read -r line; do
      if   [[ "$line" =~ ^[[:space:]]*# ]];      then continue
      elif [[ "$line" =~ ^API_PORT=([0-9]+) ]];  then API_PORT="${BASH_REMATCH[1]}"
      elif [[ "$line" =~ ^LOG_DIR=(.+)$ ]];      then LOG_DIR="${BASH_REMATCH[1]//[\'\"]/}"
      fi
    done < "${SCRIPT_DIR}/.env"
  fi
  API_LOG="${LOG_DIR}/api.log"
}

# ── Helpers ───────────────────────────────────────────────────────────────────
server_ip() { hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost"; }

has_systemd() { command -v systemctl &>/dev/null && [[ -d /run/systemd/system ]]; }

service_installed() { has_systemd && [[ -f "$UNIT" ]]; }

watchdog_running() {
  [[ -f "$PID_FILE" ]] || return 1
  kill -0 "$(cat "$PID_FILE")" 2>/dev/null
}

health_check() {   # wait up to ~15s for /api/health
  local py="${VENV}/bin/python"; [[ -x "$py" ]] || py="python3"
  for _ in $(seq 1 15); do
    if "$py" - "$API_PORT" <<'EOF' 2>/dev/null
import sys, urllib.request
urllib.request.urlopen(f"http://127.0.0.1:{sys.argv[1]}/api/health", timeout=2).read()
EOF
    then return 0; fi
    sleep 1
  done
  return 1
}

# ── Python venv + dependencies ────────────────────────────────────────────────
# A venv avoids "externally-managed-environment" pip errors on Ubuntu 23.04+
ensure_venv() {
  local PYTHON_BIN; PYTHON_BIN="$(command -v python3 || true)"
  if [[ -z "$PYTHON_BIN" ]]; then
    err "python3 not found. Run: ./install_prerequisites.sh"
    exit 1
  fi

  if [[ ! -x "${VENV}/bin/python" ]]; then
    info "Creating Python virtual environment (.venv) …"
    if ! "$PYTHON_BIN" -m venv "$VENV" 2>/dev/null; then
      rm -rf "$VENV"
      if command -v apt-get &>/dev/null; then
        local pyver; pyver=$("$PYTHON_BIN" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
        info "Installing python3-venv …"
        $SUDO apt-get install -y -q "python${pyver}-venv" 2>/dev/null || $SUDO apt-get install -y -q python3-venv
      fi
      "$PYTHON_BIN" -m venv "$VENV" || { err "Could not create venv. Install python3-venv."; exit 1; }
    fi
  fi

  # Reinstall only when requirements.txt changes
  local stamp="${VENV}/.requirements.sha"
  local want; want=$(sha256sum "$REQ" | cut -d' ' -f1)
  if [[ "$(cat "$stamp" 2>/dev/null)" != "$want" ]]; then
    info "Installing Python dependencies …"
    "${VENV}/bin/python" -m pip install -q --upgrade pip
    "${VENV}/bin/python" -m pip install -q -r "$REQ"
    echo "$want" > "$stamp"
    ok "Dependencies installed."
  fi
  [[ "$EUID" -eq 0 && "$RUN_USER" != "root" ]] && chown -R "$RUN_USER:$RUN_GROUP" "$VENV"
  return 0
}

# Stop the pre-systemd nohup/watchdog instance if one is around
stop_watchdog() {
  if watchdog_running; then
    local pid; pid=$(cat "$PID_FILE")
    info "Stopping background instance (PID ${pid}) …"
    kill -- "-${pid}" 2>/dev/null || kill "$pid" 2>/dev/null || true
    sleep 1
  fi
  rm -f "$PID_FILE"
}

# ── systemd service ───────────────────────────────────────────────────────────
install_service() {
  info "Installing systemd service ${SERVICE} (runs as ${RUN_USER}) …"
  $SUDO tee "$UNIT" > /dev/null <<EOF
[Unit]
Description=Krea Onererp — ERP Sync Dashboard
After=network-online.target docker.service
Wants=network-online.target
# Never give up restarting
StartLimitIntervalSec=0

[Service]
Type=simple
User=${RUN_USER}
Group=${RUN_GROUP}
WorkingDirectory=${SCRIPT_DIR}
Environment=PYTHONUNBUFFERED=1
Environment=PYTHONIOENCODING=utf-8
ExecStart=${VENV}/bin/python ${API_PY}
Restart=always
RestartSec=3
# Only stop the dashboard itself — a sync started from the dashboard keeps running
KillMode=process
StandardOutput=append:${API_LOG}
StandardError=append:${API_LOG}

[Install]
WantedBy=multi-user.target
EOF
  $SUDO systemctl daemon-reload
  $SUDO systemctl enable "$SERVICE" &>/dev/null
  ok "Service enabled — auto-restart on crash, auto-start on boot."
}

# ── Fallback: watchdog loop (no systemd) ──────────────────────────────────────
start_watchdog() {
  warn "systemd not available — using watchdog loop + @reboot cron."
  local py="${VENV}/bin/python"
  setsid nohup bash -c "
    while true; do
      PYTHONUNBUFFERED=1 PYTHONIOENCODING=utf-8 '${py}' '${API_PY}'
      rc=\$?
      echo \"[\$(date '+%F %T')] api.py exited (code \$rc) — restarting in 3s\"
      sleep 3
    done" >> "$API_LOG" 2>&1 < /dev/null &
  echo $! > "$PID_FILE"

  if command -v crontab &>/dev/null; then
    ( crontab -l 2>/dev/null | grep -v "$CRON_TAG" || true
      echo "@reboot /usr/bin/env bash ${SCRIPT_DIR}/start_api.sh start >/dev/null 2>&1 ${CRON_TAG}"
    ) | crontab -
    ok "@reboot cron entry registered."
  fi
}

# ── Commands ──────────────────────────────────────────────────────────────────
cmd_start() {
  load_env
  mkdir -p "$LOG_DIR"
  [[ "$EUID" -eq 0 && "$RUN_USER" != "root" ]] && chown "$RUN_USER:$RUN_GROUP" "$LOG_DIR" 2>/dev/null || true
  ensure_venv
  stop_watchdog

  if has_systemd; then
    install_service
    $SUDO systemctl restart "$SERVICE"
  else
    start_watchdog
  fi

  info "Waiting for dashboard to respond …"
  if health_check; then
    ok "Dashboard running  →  http://$(server_ip):${API_PORT}"
  else
    err "Dashboard did not respond on port ${API_PORT}. Last log lines:"
    tail -n 20 "$API_LOG" 2>/dev/null || true
    exit 1
  fi
  ok "Log: ${API_LOG}"
}

cmd_stop() {
  load_env
  if service_installed; then
    $SUDO systemctl stop "$SERVICE"
    ok "Dashboard stopped (still enabled at boot — use 'uninstall' to disable)."
  fi
  stop_watchdog
}

cmd_restart() {
  cmd_start
}

cmd_status() {
  load_env
  echo ""
  echo -e "${BOLD}ERP Sync Dashboard — Status${RESET}"
  echo    "────────────────────────────────"
  if service_installed; then
    local state pid since restarts enabled
    state=$(systemctl is-active "$SERVICE" 2>/dev/null || true)
    enabled=$(systemctl is-enabled "$SERVICE" 2>/dev/null || true)
    pid=$(systemctl show -p MainPID --value "$SERVICE")
    since=$(systemctl show -p ActiveEnterTimestamp --value "$SERVICE")
    restarts=$(systemctl show -p NRestarts --value "$SERVICE" 2>/dev/null || echo "?")
    if [[ "$state" == "active" ]]; then
      echo -e "  State    : ${GREEN}● RUNNING${RESET}  (PID ${pid}, systemd)"
    else
      echo -e "  State    : ${RED}○ ${state^^}${RESET}"
    fi
    echo    "  Since    : ${since:-—}"
    echo    "  Restarts : ${restarts}  (automatic crash restarts)"
    echo    "  On boot  : ${enabled}"
  elif watchdog_running; then
    echo -e "  State    : ${GREEN}● RUNNING${RESET}  (watchdog PID $(cat "$PID_FILE"))"
  else
    echo -e "  State    : ${RED}○ STOPPED${RESET}"
    echo    "  Run      : ./start_api.sh start"
  fi
  if health_check; then
    echo -e "  Health   : ${GREEN}OK${RESET}"
  else
    echo -e "  Health   : ${RED}not responding${RESET}"
  fi
  echo -e "  URL      : ${CYAN}http://$(server_ip):${API_PORT}${RESET}"
  echo    "  Log      : ${API_LOG}"
  echo ""
}

cmd_logs() {
  load_env
  if [[ ! -f "$API_LOG" ]]; then
    warn "No log file at ${API_LOG}"
    return
  fi
  info "Tailing ${API_LOG}  (Ctrl+C to exit)"
  tail -n 100 -f "${API_LOG}"
}

cmd_uninstall() {
  if service_installed; then
    $SUDO systemctl disable --now "$SERVICE" 2>/dev/null || true
    $SUDO rm -f "$UNIT"
    $SUDO systemctl daemon-reload
    ok "Removed ${SERVICE}."
  fi
  stop_watchdog
  if command -v crontab &>/dev/null; then
    crontab -l 2>/dev/null | grep -v "$CRON_TAG" | crontab - || true
  fi
  ok "Autostart removed."
}

# ── Entry ─────────────────────────────────────────────────────────────────────
echo -e "${BOLD}"
echo "╔══════════════════════════════════════════╗"
echo "║   Krea Onererp — ERP Sync Dashboard      ║"
echo "╚══════════════════════════════════════════╝"
echo -e "${RESET}"

case "${1:-start}" in
  start)     cmd_start ;;
  stop)      cmd_stop ;;
  restart)   cmd_restart ;;
  status)    cmd_status ;;
  logs)      cmd_logs ;;
  uninstall) cmd_uninstall ;;
  *)
    echo "Usage: $0 [start|stop|restart|status|logs|uninstall]"
    exit 1
    ;;
esac
