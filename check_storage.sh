#!/usr/bin/env bash
# =============================================================================
#  check_storage.sh  –  Storage diagnostic for ERP DB Sync
#  Usage: ./check_storage.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Colours ───────────────────────────────────────────────────────────────────
BOLD='\033[1m'; CYAN='\033[0;36m'; GREEN='\033[0;32m'
YELLOW='\033[1;33m'; RED='\033[0;31m'; RESET='\033[0m'

header() { echo -e "\n${BOLD}${CYAN}══ $* ══${RESET}"; }
row()    { printf "  %-30s %s\n" "$1" "$2"; }
warn()   { echo -e "  ${YELLOW}⚠  $*${RESET}"; }
ok()     { echo -e "  ${GREEN}✔  $*${RESET}"; }

# ── Load .env ─────────────────────────────────────────────────────────────────
BACKUP_DIR="${SCRIPT_DIR}/backups"
LOG_DIR="${SCRIPT_DIR}/logs"
MYSQL_ROOT_PASSWORD=""
MYSQL_CONTAINER="mysql_local"

if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  while IFS= read -r line; do
    if   [[ "$line" =~ ^BACKUP_DIR=(.+)$ ]];          then BACKUP_DIR="${BASH_REMATCH[1]//\'/}"
    elif [[ "$line" =~ ^LOG_DIR=(.+)$ ]];              then LOG_DIR="${BASH_REMATCH[1]//\'/}"
    elif [[ "$line" =~ ^MYSQL_ROOT_PASSWORD=(.+)$ ]];  then MYSQL_ROOT_PASSWORD="${BASH_REMATCH[1]//\'/}"
    fi
  done < "${SCRIPT_DIR}/.env"
fi

echo -e "${BOLD}"
echo "╔══════════════════════════════════════════════════╗"
echo "║   Krea Onererp — Storage Diagnostic              ║"
echo "╚══════════════════════════════════════════════════╝"
echo -e "${RESET}"

# ── 1. Disk usage ─────────────────────────────────────────────────────────────
header "1. Disk Usage"
df -h | awk 'NR==1 || /\/$/ || /\/data/ || /\/var/ || /\/home/' \
  | while read -r line; do echo "  $line"; done

# ── 2. Top space consumers ────────────────────────────────────────────────────
header "2. Top 10 Directories by Size"
du -h / --max-depth=4 2>/dev/null | sort -rh | head -10 \
  | while read -r line; do echo "  $line"; done

# ── 3. Backup dir ─────────────────────────────────────────────────────────────
header "3. Backup Directory  ($BACKUP_DIR)"
if [[ -d "$BACKUP_DIR" ]]; then
  total=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)
  count=$(ls "$BACKUP_DIR"/dump_all_*.sql.gz 2>/dev/null | wc -l | tr -d ' ')
  row "Total size:"  "$total"
  row "Dump files:"  "$count"
  echo ""
  ls -lh "$BACKUP_DIR"/dump_all_*.sql.gz 2>/dev/null \
    | awk '{printf "  %-10s  %s\n", $5, $9}' || echo "  (none)"
else
  warn "Backup dir not found: $BACKUP_DIR"
fi

# ── 4. Log dir ────────────────────────────────────────────────────────────────
header "4. Log Directory  ($LOG_DIR)"
if [[ -d "$LOG_DIR" ]]; then
  total=$(du -sh "$LOG_DIR" 2>/dev/null | cut -f1)
  count=$(ls "$LOG_DIR"/sync_*.log 2>/dev/null | wc -l | tr -d ' ')
  row "Total size:"  "$total"
  row "Log files:"   "$count"
else
  warn "Log dir not found: $LOG_DIR"
fi

# ── 5. Docker system ──────────────────────────────────────────────────────────
header "5. Docker System Usage"
if command -v docker &>/dev/null; then
  docker system df
else
  warn "Docker not found"
fi

# ── 6. MySQL volume & binary logs ─────────────────────────────────────────────
header "6. MySQL Container  ($MYSQL_CONTAINER)"
if docker ps --filter "name=^${MYSQL_CONTAINER}$" --format "{{.Names}}" \
    | grep -q "^${MYSQL_CONTAINER}$"; then

  # Volume size
  vol_size=$(docker exec "$MYSQL_CONTAINER" du -sh /var/lib/mysql 2>/dev/null | cut -f1)
  row "Data volume:"  "$vol_size"

  # Binary logs
  binlog_count=$(docker exec "$MYSQL_CONTAINER" \
    bash -c "ls /var/lib/mysql/binlog.* 2>/dev/null | wc -l" || echo "0")
  binlog_size=$(docker exec "$MYSQL_CONTAINER" \
    bash -c "du -sh /var/lib/mysql/binlog.* 2>/dev/null | tail -1 | cut -f1" \
    || echo "0")

  row "Binary log files:" "$binlog_count"
  if [[ "$binlog_count" -gt 0 ]] 2>/dev/null; then
    warn "Binary logs found! Size: ${binlog_size}"
    warn "Run: docker exec ${MYSQL_CONTAINER} mysql -uroot -p\$MYSQL_ROOT_PASSWORD -e \"RESET BINARY LOGS AND GTIDS;\""
  else
    ok "No binary logs (skip-log-bin is active)"
  fi

  # Confirm skip-log-bin setting
  echo ""
  echo "  MySQL variables:"
  if [[ -n "$MYSQL_ROOT_PASSWORD" ]]; then
    docker exec "$MYSQL_CONTAINER" \
      mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" --batch --skip-column-names \
      -e "SHOW VARIABLES WHERE Variable_name IN
          ('log_bin','innodb_undo_log_truncate','innodb_max_undo_log_size',
           'default_time_zone','sql_mode','max_execution_time');" \
      2>/dev/null | while read -r line; do echo "    $line"; done \
      || warn "Could not query MySQL (check MYSQL_ROOT_PASSWORD in .env)"
  else
    warn "MYSQL_ROOT_PASSWORD not set in .env — skipping variable check"
  fi
else
  warn "Container '${MYSQL_CONTAINER}' is not running."
fi

# ── 7. Dangling Docker objects ────────────────────────────────────────────────
header "7. Dangling Docker Objects (reclaimable)"
if command -v docker &>/dev/null; then
  dangling_images=$(docker images -f "dangling=true" -q | wc -l | tr -d ' ')
  stopped_containers=$(docker ps -a -f "status=exited" -q | wc -l | tr -d ' ')
  row "Dangling images:"      "$dangling_images"
  row "Stopped containers:"   "$stopped_containers"
  if [[ "$dangling_images" -gt 0 || "$stopped_containers" -gt 0 ]]; then
    warn "Run: docker image prune -f && docker container prune -f"
  else
    ok "Nothing to prune"
  fi
fi

echo ""
echo -e "${BOLD}── Done ──${RESET}"
echo ""
