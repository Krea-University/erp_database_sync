#!/usr/bin/env bash
# =============================================================================
#  sync.sh  –  Mirror remote MySQL databases (excluding system DBs)
#              → local Docker MySQL, table-by-table, in parallel
#
#  Usage:
#    ./sync.sh                 ← SYNC_MODE from .env (default: incremental)
#    ./sync.sh --incremental   ← copy only tables changed since the last run
#    ./sync.sh --full          ← re-copy every table
#
#  How it works:
#    1. Fingerprint every remote table (cheap metadata, or CHECKSUM TABLE)
#    2. Compare with fingerprints saved after the previous run
#    3. Dump + restore only the changed tables, SYNC_PARALLEL at a time
#    4. Drop local tables that no longer exist remotely; refresh views,
#       routines and events of databases whose definitions changed
#
#  Uses the mysql_local Docker container as the MySQL client —
#  no mysql/mysqldump install required on the host.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="${SCRIPT_DIR}/$(basename "${BASH_SOURCE[0]}")"
ENV_FILE="${SCRIPT_DIR}/.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "[ERROR] .env not found at $ENV_FILE"
  exit 1
fi
# shellcheck disable=SC1090
source "$ENV_FILE"

SYSTEM_DBS="'information_schema','performance_schema','mysql','sys'"
STATE_DIR="${STATE_DIR:-${SCRIPT_DIR}/state}"
PARALLEL="${SYNC_PARALLEL:-4}"
GZIP_CMD="gzip -1"
command -v pigz &>/dev/null && GZIP_CMD="pigz -1"

log()   { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
human() { numfmt --to=iec --suffix=B "${1:-0}" 2>/dev/null || echo "${1:-0}B"; }

# ── MySQL helpers ─────────────────────────────────────────────────────────────
# Passwords travel via MYSQL_PWD (docker exec -e NAME copies it from our env),
# so they never show up in `ps` output on the host.
remote_sql() {
  MYSQL_PWD="$PROD_DB_PASS" docker exec -e MYSQL_PWD "$MYSQL_CONTAINER" mysql \
    --host="$PROD_DB_HOST" --port="$PROD_DB_PORT" --user="$PROD_DB_USER" \
    --batch --skip-column-names --default-character-set=utf8mb4 "$@"
}

remote_dump() {
  # shellcheck disable=SC2086
  MYSQL_PWD="$PROD_DB_PASS" docker exec -e MYSQL_PWD "$MYSQL_CONTAINER" mysqldump \
    --host="$PROD_DB_HOST" --port="$PROD_DB_PORT" --user="$PROD_DB_USER" \
    --single-transaction --quick --skip-lock-tables --no-tablespaces \
    --set-gtid-purged=OFF --hex-blob --default-character-set=utf8mb4 \
    --max-allowed-packet=1G ${MYSQLDUMP_EXTRA_OPTS:-} "$@"
}

local_query() {   # no stdin — safe inside loops
  MYSQL_PWD="$MYSQL_ROOT_PASSWORD" docker exec -e MYSQL_PWD "$MYSQL_CONTAINER" mysql \
    -uroot --batch --skip-column-names --default-character-set=utf8mb4 "$@"
}

local_load() {    # reads SQL from stdin
  MYSQL_PWD="$MYSQL_ROOT_PASSWORD" docker exec -i -e MYSQL_PWD "$MYSQL_CONTAINER" mysql \
    -uroot --default-character-set=utf8mb4 --max-allowed-packet=1G "$@"
}

# ── Worker: copy one table (run in parallel via xargs) ────────────────────────
# $1 = "db<TAB>table<TAB>fingerprint<TAB>size"
sync_table() {
  local db tbl fp size
  IFS=$'\t' read -r db tbl fp size <<< "$1"
  local dir="${RUN_DIR}/${db}"
  local file="${dir}/${tbl//\//_}.sql.gz"
  local errf; errf="$(mktemp)"
  local t0=$SECONDS status="OK"
  mkdir -p "$dir"

  if ! remote_dump "$db" "$tbl" 2>"$errf" | $GZIP_CMD > "$file"; then
    status="FAIL_DUMP"
  elif ! $GZIP_CMD -dc "$file" | local_load "$db" 2>>"$errf"; then
    status="FAIL_RESTORE"
  else
    # Fresh statistics → good query plans on the mirror + accurate sizes
    local_query -e "ANALYZE TABLE \`${db//\`/\`\`}\`.\`${tbl//\`/\`\`}\`;" >/dev/null 2>&1 || true
  fi

  local bytes secs=$((SECONDS - t0))
  bytes=$(stat -c %s "$file" 2>/dev/null || echo 0)
  if [[ "$status" == "OK" ]]; then
    log "  ✓ ${db}.${tbl}  ($(human "$bytes"), ${secs}s)"
  else
    log "[ERROR] ${db}.${tbl}: ${status} — $(grep -v '^mysqldump: \[Warning\]' "$errf" | head -c 600 | tr '\n' ' ')"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$status" "$db" "$tbl" "$fp" "$bytes" "$secs" >> "$RESULTS_FILE"

  [[ "${BACKUP_KEEP_COUNT:-3}" == "0" ]] && rm -f "$file"
  rm -f "$errf"
}

# ── Arguments ─────────────────────────────────────────────────────────────────
MODE_ARG=""
case "${1:-}" in
  --worker)      sync_table "$2"; exit 0 ;;
  --full)        MODE_ARG="full" ;;
  --incremental) MODE_ARG="incremental" ;;
  "")            ;;
  *) echo "Usage: $0 [--incremental|--full]"; exit 1 ;;
esac

# ── Validate required variables ───────────────────────────────────────────────
for var in PROD_DB_HOST PROD_DB_PORT PROD_DB_USER PROD_DB_PASS \
           MYSQL_ROOT_PASSWORD BACKUP_DIR LOG_DIR; do
  if [[ -z "${!var:-}" ]]; then
    echo "[ERROR] \$$var is not set in .env"
    exit 1
  fi
done

mkdir -p "$BACKUP_DIR" "$LOG_DIR" "$STATE_DIR"

# ── Single-instance lock (cron + dashboard can never overlap) ─────────────────
exec 9>"${STATE_DIR}/sync.lock"
if ! flock -n 9; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Another sync is already running — skipping."
  exit 0
fi

# ── Mode selection ────────────────────────────────────────────────────────────
FP_FILE="${STATE_DIR}/fingerprints.tsv"
touch "$FP_FILE"
MODE="${MODE_ARG:-${SYNC_MODE:-incremental}}"
MODE_REASON="${MODE_ARG:+requested}"
MODE_REASON="${MODE_REASON:-default}"
if [[ -z "$MODE_ARG" && "$MODE" == "incremental" && -n "${FULL_SYNC_HOUR:-}" ]]; then
  last_full_day=$(cat "${STATE_DIR}/last_full_date" 2>/dev/null || true)
  if [[ "$last_full_day" != "$(date +%F)" && "$(date +%-H)" -ge "$FULL_SYNC_HOUR" ]]; then
    MODE="full"
    MODE_REASON="daily full sync (FULL_SYNC_HOUR=${FULL_SYNC_HOUR})"
  fi
fi
FIRST_RUN=0
[[ -s "$FP_FILE" ]] || FIRST_RUN=1

if [[ -n "${SYNC_TRIGGER:-}" ]]; then TRIGGER="$SYNC_TRIGGER"
elif [[ -t 1 ]];                 then TRIGGER="manual"
else                                  TRIGGER="cron"
fi

# ── Setup run paths & logging ─────────────────────────────────────────────────
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="${LOG_DIR}/sync_${TIMESTAMP}.log"
RUN_DIR="${BACKUP_DIR}/run_${TIMESTAMP}_${MODE}"
RESULTS_FILE="${STATE_DIR}/current_results.tsv"
WORK="$(mktemp -d)"
START_EPOCH=$(date +%s)
START_ISO=$(date '+%Y-%m-%d %H:%M:%S')
PGID=$(ps -o pgid= -p $$ | tr -d ' ')
JOB_TOTAL=0
DROPPED=0
OBJ_FAILED=0
REACHED_COPY=0
CANCELLED=0
REDO_DISABLED=0
: > "$RESULTS_FILE"
touch "${WORK}/objects_done.tsv" "${WORK}/skipped.tsv" "${WORK}/remote_all.tsv" "${WORK}/remote_tables.tsv"
mkdir -p "$RUN_DIR"
export RUN_DIR RESULTS_FILE LOG_FILE

write_state() {   # $1 = phase
  cat > "${STATE_DIR}/current.json.tmp" <<EOF
{"pid":$$,"pgid":${PGID:-0},"mode":"${MODE}","trigger":"${TRIGGER}","started":"${START_ISO}","started_epoch":${START_EPOCH},"phase":"$1","total":${JOB_TOTAL},"log":"$(basename "$LOG_FILE")"}
EOF
  mv -f "${STATE_DIR}/current.json.tmp" "${STATE_DIR}/current.json"
}

# ── Prune — runs on EXIT ──────────────────────────────────────────────────────
prune() {
  local keep_days="${BACKUP_KEEP_DAYS:-1}"
  local keep_count="${BACKUP_KEEP_COUNT:-3}"
  local log_keep="${LOG_KEEP_COUNT:-14}"

  if [[ -d "$BACKUP_DIR" ]]; then
    local before; before=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)
    find "$BACKUP_DIR" -maxdepth 1 \( -name 'run_*' -o -name 'dump_all_*.sql.gz' \) \
      -mtime "+${keep_days}" -exec rm -rf {} + 2>/dev/null || true
    ls -dt "$BACKUP_DIR"/run_* 2>/dev/null | tail -n "+$((keep_count + 1))" | xargs -r rm -rf
    # Legacy single-file dumps from the old sync.sh are superseded by run_* dirs
    ls -t "$BACKUP_DIR"/dump_all_*.sql.gz 2>/dev/null | tail -n "+$((keep_count + 1))" | xargs -r rm -f
    local after; after=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)
    log "Backup dir: ${before} → ${after}  (keep ${keep_count} run(s) / ${keep_days}d)"
  fi

  if [[ -d "$LOG_DIR" ]]; then
    ls -t "$LOG_DIR"/sync_*.log "$LOG_DIR"/manual_sync_*.log 2>/dev/null \
      | tail -n "+$((log_keep + 1))" | xargs -r rm -f
  fi

  # Dangling images only. Never `docker container prune` here — it would delete
  # mysql_local itself whenever that container happens to be stopped.
  command -v docker &>/dev/null && docker image prune -f &>/dev/null || true
}

# ── Finish — always runs on EXIT (success, failure or cancel) ─────────────────
finish() {
  local rc=$?
  set +e
  trap - EXIT TERM INT

  if [[ "$REDO_DISABLED" == "1" ]]; then
    local_query -e "ALTER INSTANCE ENABLE INNODB REDO_LOG;" 2>>"$LOG_FILE" \
      && log "InnoDB redo log re-enabled."
  fi

  local ok failed skipped bytes
  ok=$(grep -c '^OK' "$RESULTS_FILE" 2>/dev/null || true)
  failed=$(grep -c '^FAIL' "$RESULTS_FILE" 2>/dev/null || true)
  skipped=$(wc -l < "${WORK}/skipped.tsv" 2>/dev/null || echo 0)
  bytes=$(awk -F'\t' '{s+=$5} END {printf "%d", s}' "$RESULTS_FILE" 2>/dev/null)

  local status="success"
  if   [[ "$CANCELLED" == "1" ]];                      then status="cancelled"
  elif [[ "$rc" -ne 0 ]];                              then status="failed"
  elif [[ "$failed" -gt 0 || "$OBJ_FAILED" -gt 0 ]];   then status="partial"
  fi

  # Save fingerprints of every table that was restored OK. Failed tables keep
  # their old fingerprint, so the next run retries them automatically.
  if [[ "$REACHED_COPY" == "1" ]]; then
    awk -F'\t' -v OFS='\t' '
      FILENAME == ARGV[1] { if ($1 == "OK") ok[$2 FS $3] = $4; next }
      FILENAME == ARGV[2] { exists[$1 FS $2] = 1; next }
      FILENAME == ARGV[3] { obj[$1] = $2; next }
      {
        k = $1 FS $2
        if (k in ok) next
        if ($2 == "@objects") { if ($1 in obj) next }
        else if (!(k in exists)) next
        print
      }
      END {
        for (k in ok)  print k, ok[k]
        for (d in obj) print d, "@objects", obj[d]
      }' "$RESULTS_FILE" "${WORK}/remote_all.tsv" "${WORK}/objects_done.tsv" "$FP_FILE" \
      > "${FP_FILE}.tmp" && mv -f "${FP_FILE}.tmp" "$FP_FILE"

    if [[ "$status" == "success" && ( "$MODE" == "full" || "$FIRST_RUN" == "1" ) ]]; then
      date +%F > "${STATE_DIR}/last_full_date"
    fi

    write_db_stats
  fi

  local end_epoch; end_epoch=$(date +%s)
  local duration=$((end_epoch - START_EPOCH))
  printf '{"started":"%s","finished":"%s","duration_s":%d,"mode":"%s","reason":"%s","trigger":"%s","status":"%s","tables_total":%d,"tables_synced":%d,"tables_failed":%d,"tables_skipped":%d,"tables_dropped":%d,"objects_failed":%d,"dump_bytes":%d,"log":"%s"}\n' \
    "$START_ISO" "$(date '+%Y-%m-%d %H:%M:%S')" "$duration" "$MODE" "$MODE_REASON" "$TRIGGER" "$status" \
    "$JOB_TOTAL" "$ok" "$failed" "$skipped" "$DROPPED" "$OBJ_FAILED" "${bytes:-0}" "$(basename "$LOG_FILE")" \
    >> "${STATE_DIR}/history.jsonl"
  tail -n 500 "${STATE_DIR}/history.jsonl" > "${STATE_DIR}/history.tmp" \
    && mv -f "${STATE_DIR}/history.tmp" "${STATE_DIR}/history.jsonl"
  rm -f "${STATE_DIR}/current.json"

  prune
  rm -rf "$WORK"

  log "Result : ${status^^} — ${ok} copied, ${failed} failed, ${skipped} unchanged, ${DROPPED} dropped  ($(human "${bytes:-0}") in $((duration / 60))m $((duration % 60))s)"
  log "========== Sync Finished =========="
  log "Log: ${LOG_FILE}"
  exit "$rc"
}

# Per-database summary for the dashboard (remote size vs local size)
write_db_stats() {
  local_query -e "
    SET SESSION information_schema_stats_expiry = 0;
    SELECT TABLE_SCHEMA, SUM(IFNULL(DATA_LENGTH,0) + IFNULL(INDEX_LENGTH,0))
    FROM information_schema.TABLES
    WHERE TABLE_TYPE = 'BASE TABLE' AND TABLE_SCHEMA NOT IN (${SYSTEM_DBS})
    GROUP BY TABLE_SCHEMA;" > "${WORK}/local_sizes.tsv" 2>>"$LOG_FILE"

  awk -F'\t' -v gen="$(date '+%Y-%m-%d %H:%M:%S')" '
    function js(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return s }
    FILENAME == ARGV[1] { if ($1 == "OK") synced[$2]++; else if ($1 ~ /^FAIL/) failed[$2]++; next }
    FILENAME == ARGV[2] { local[$1] = $2; next }
    $3 == "BASE TABLE" { if (!($1 in tables)) order[++n] = $1; tables[$1]++; size[$1] += $4 }
    END {
      printf "{\"generated\":\"%s\",\"databases\":[", gen
      for (i = 1; i <= n; i++) {
        d = order[i]
        printf "%s{\"name\":\"%s\",\"tables\":%d,\"remote_bytes\":%d,\"local_bytes\":%d,\"synced\":%d,\"failed\":%d}",
          (i > 1 ? "," : ""), js(d), tables[d], size[d], local[d] + 0, synced[d] + 0, failed[d] + 0
      }
      print "]}"
    }' "$RESULTS_FILE" "${WORK}/local_sizes.tsv" "${WORK}/remote_tables.tsv" \
    > "${STATE_DIR}/db_stats.json.tmp" && mv -f "${STATE_DIR}/db_stats.json.tmp" "${STATE_DIR}/db_stats.json"
}

trap finish EXIT
trap 'CANCELLED=1; log "[WARN] Sync cancelled."; exit 143' TERM INT

write_state "starting"
log "========== ERP DB Sync Started (${MODE^^}) =========="
log "Source  : ${PROD_DB_USER}@${PROD_DB_HOST}:${PROD_DB_PORT}"
log "Target  : local Docker mysql_local"
log "Mode    : ${MODE}  (${MODE_REASON}, trigger: ${TRIGGER})"
log "Workers : ${PARALLEL} parallel  ·  change detection: ${SYNC_CHANGE_DETECT:-stats}"

# ── Verify container is running ───────────────────────────────────────────────
MYSQL_CONTAINER=$(docker ps --filter "name=^mysql_local$" --format "{{.Names}}" | head -1)
if [[ -z "$MYSQL_CONTAINER" ]]; then
  log "[ERROR] Container 'mysql_local' is not running. Run: docker compose up -d"
  exit 1
fi
export MYSQL_CONTAINER

# ── 1. Remote metadata ────────────────────────────────────────────────────────
write_state "scanning"
log "Scanning remote tables …"

# information_schema_stats_expiry=0 bypasses MySQL 8's 24h statistics cache
# (on MySQL 5.7 that SET just errors and --force carries on).
remote_sql --force -e "
  SET SESSION information_schema_stats_expiry = 0;
  SELECT TABLE_SCHEMA, TABLE_NAME, TABLE_TYPE,
         IFNULL(DATA_LENGTH,0) + IFNULL(INDEX_LENGTH,0),
         CONCAT_WS('|', IFNULL(CREATE_TIME,'-'), IFNULL(UPDATE_TIME,'-'), IFNULL(TABLE_ROWS,'-'),
                        IFNULL(DATA_LENGTH,'-'), IFNULL(AUTO_INCREMENT,'-'))
  FROM information_schema.TABLES
  WHERE TABLE_SCHEMA NOT IN (${SYSTEM_DBS})
  ORDER BY TABLE_SCHEMA, TABLE_NAME;" > "${WORK}/remote_all.tsv" 2>>"$LOG_FILE" || true

remote_sql -e "
  SELECT SCHEMA_NAME, DEFAULT_CHARACTER_SET_NAME, DEFAULT_COLLATION_NAME
  FROM information_schema.SCHEMATA
  WHERE SCHEMA_NAME NOT IN (${SYSTEM_DBS});" > "${WORK}/schemas_all.tsv" 2>>"$LOG_FILE" || true

if [[ ! -s "${WORK}/schemas_all.tsv" ]]; then
  log "[ERROR] No user databases found. Check PROD_DB_* credentials in .env"
  log "        See log for details: ${LOG_FILE}"
  exit 1
fi
# Never continue on an empty table list — the drop step would wipe the mirror
if ! awk -F'\t' '$3 == "BASE TABLE" { found = 1; exit } END { exit !found }' "${WORK}/remote_all.tsv"; then
  log "[ERROR] Remote table list is empty (query failed?). Aborting without changes."
  exit 1
fi

# Exclusion filters (regex, read via ENVIRON so backslashes survive)
export SYNC_EXCLUDE_DBS="${SYNC_EXCLUDE_DBS:-}" SYNC_EXCLUDE_TABLES="${SYNC_EXCLUDE_TABLES:-}"
EXCLUDE_AWK='
  ENVIRON["SYNC_EXCLUDE_DBS"]    != "" && $1 ~ ("^(" ENVIRON["SYNC_EXCLUDE_DBS"] ")$")             { next }
  ENVIRON["SYNC_EXCLUDE_TABLES"] != "" && NF > 3 && ($1 "." $2) ~ ("^(" ENVIRON["SYNC_EXCLUDE_TABLES"] ")$") { next }
  { print }'
awk -F'\t' "$EXCLUDE_AWK" "${WORK}/schemas_all.tsv" > "${WORK}/schemas.tsv"
awk -F'\t' "$EXCLUDE_AWK" "${WORK}/remote_all.tsv"  > "${WORK}/remote_tables.tsv"
mapfile -t DBS < <(cut -f1 "${WORK}/schemas.tsv")

log "Found ${#DBS[@]} database(s), $(awk -F'\t' '$3=="BASE TABLE"' "${WORK}/remote_tables.tsv" | wc -l) table(s), $(awk -F'\t' '$3=="VIEW"' "${WORK}/remote_tables.tsv" | wc -l) view(s)"

# Optional exact change detection: CHECKSUM TABLE (reads every row on prod)
if [[ "${SYNC_CHANGE_DETECT:-stats}" == "checksum" ]]; then
  write_state "checksumming"
  log "Computing CHECKSUM TABLE on remote (SYNC_CHANGE_DETECT=checksum) …"
  : > "${WORK}/checksums.tsv"
  for db in "${DBS[@]}"; do
    tbl_list=$(awk -F'\t' -v OFS='' -v d="$db" '$1==d && $3=="BASE TABLE" {gsub(/`/,"``",$2); printf "%s`%s`.`%s`", (n++ ? "," : ""), d, $2}' "${WORK}/remote_tables.tsv")
    [[ -z "$tbl_list" ]] && continue
    remote_sql -e "CHECKSUM TABLE ${tbl_list};" 2>>"$LOG_FILE" \
      | awk -F'\t' -v OFS='\t' -v d="$db" '{ t = substr($1, length(d) + 2); print d, t, $2 }' \
      >> "${WORK}/checksums.tsv" || true
  done
  awk -F'\t' -v OFS='\t' '
    FILENAME == ARGV[1] { ck[$1 FS $2] = $3; next }
    $3 == "BASE TABLE" { split($5, p, "|"); $5 = p[1] "|ck:" ck[$1 FS $2] }
    { print }' "${WORK}/checksums.tsv" "${WORK}/remote_tables.tsv" > "${WORK}/remote_tables.tmp"
  mv -f "${WORK}/remote_tables.tmp" "${WORK}/remote_tables.tsv"
fi

# Views / routines / events fingerprint per database
remote_sql --force -e "
  SET SESSION group_concat_max_len = 67108864;
  SELECT db, GROUP_CONCAT(part ORDER BY part SEPARATOR '|') FROM (
    SELECT ROUTINE_SCHEMA AS db, CONCAT('r', COUNT(*), '@', IFNULL(MAX(LAST_ALTERED),'-')) AS part
      FROM information_schema.ROUTINES GROUP BY ROUTINE_SCHEMA
    UNION ALL
    SELECT EVENT_SCHEMA, CONCAT('e', COUNT(*), '@', IFNULL(MAX(LAST_ALTERED),'-'))
      FROM information_schema.EVENTS GROUP BY EVENT_SCHEMA
    UNION ALL
    SELECT TABLE_SCHEMA, CONCAT('v', COUNT(*), '@', MD5(GROUP_CONCAT(TABLE_NAME, VIEW_DEFINITION ORDER BY TABLE_NAME)))
      FROM information_schema.VIEWS GROUP BY TABLE_SCHEMA
  ) x WHERE db NOT IN (${SYSTEM_DBS}) GROUP BY db;" > "${WORK}/objects.tsv" 2>>"$LOG_FILE" || true

# ── 2. Local state ────────────────────────────────────────────────────────────
local_query -e "
  SELECT TABLE_SCHEMA, TABLE_NAME, TABLE_TYPE FROM information_schema.TABLES
  WHERE TABLE_SCHEMA NOT IN (${SYSTEM_DBS});" > "${WORK}/local_tables.tsv" 2>>"$LOG_FILE"

# Create any database that is missing locally (with the remote charset)
awk -F'\t' '{ gsub(/`/, "``", $1); printf "CREATE DATABASE IF NOT EXISTS `%s` CHARACTER SET %s COLLATE %s;\n", $1, $2, $3 }' \
  "${WORK}/schemas.tsv" | local_load --force 2>>"$LOG_FILE" \
  || log "[WARN] Some databases could not be created locally (see log)."

# ── 3. Plan: which tables changed? ────────────────────────────────────────────
write_state "planning"
FULL_FLAG=0; [[ "$MODE" == "full" ]] && FULL_FLAG=1
awk -F'\t' -v OFS='\t' -v full="$FULL_FLAG" -v jobs="${WORK}/jobs.tsv" -v skip="${WORK}/skipped.tsv" '
  FILENAME == ARGV[1] { old[$1 FS $2] = $3; next }
  FILENAME == ARGV[2] { if ($3 == "BASE TABLE") have[$1 FS $2] = 1; next }
  $3 == "BASE TABLE" {
    k = $1 FS $2
    if (full || !(k in have) || !(k in old) || old[k] != $5) print $1, $2, $5, $4 > jobs
    else                                                       print $1, $2, $5     > skip
  }' "$FP_FILE" "${WORK}/local_tables.tsv" "${WORK}/remote_tables.tsv"
touch "${WORK}/jobs.tsv" "${WORK}/skipped.tsv"
# Biggest tables first → workers finish at roughly the same time
sort -t$'\t' -k4,4nr "${WORK}/jobs.tsv" -o "${WORK}/jobs.tsv"
JOB_TOTAL=$(wc -l < "${WORK}/jobs.tsv")
JOB_BYTES=$(awk -F'\t' '{s+=$4} END {printf "%d", s}' "${WORK}/jobs.tsv")
log "Plan: ${JOB_TOTAL} table(s) to copy (~$(human "$JOB_BYTES") on prod), $(wc -l < "${WORK}/skipped.tsv") unchanged"

# Drop local tables / views that were removed on production
if [[ "${SYNC_DROP_MISSING:-1}" == "1" ]]; then
  awk -F'\t' '
    FILENAME == ARGV[1] { db[$1] = 1; next }
    FILENAME == ARGV[2] { remote[$1 FS $2] = 1; next }
    ($1 in db) && !(($1 FS $2) in remote) {
      gsub(/`/, "``", $1); gsub(/`/, "``", $2)
      printf "DROP %s IF EXISTS `%s`.`%s`;\n", ($3 == "VIEW" ? "VIEW" : "TABLE"), $1, $2
    }' "${WORK}/schemas.tsv" "${WORK}/remote_all.tsv" "${WORK}/local_tables.tsv" > "${WORK}/drops.sql"
  DROPPED=$(wc -l < "${WORK}/drops.sql")
  if [[ "$DROPPED" -gt "${SYNC_DROP_MAX:-100}" ]]; then
    log "[WARN] ${DROPPED} local objects missing on production (> SYNC_DROP_MAX=${SYNC_DROP_MAX:-100}) — skipping drops for safety."
    DROPPED=0
  elif [[ "$DROPPED" -gt 0 ]]; then
    log "Dropping ${DROPPED} local object(s) no longer on production:"
    sed 's/^/  · /' "${WORK}/drops.sql" | tee -a "$LOG_FILE"
    { echo "SET foreign_key_checks = 0;"; cat "${WORK}/drops.sql"; } | local_load 2>>"$LOG_FILE" || true
  fi
fi

# ── 4. Copy changed tables in parallel ────────────────────────────────────────
REACHED_COPY=1
if [[ "$JOB_TOTAL" -gt 0 ]]; then
  if [[ "${FAST_RESTORE_DISABLE_REDO:-0}" == "1" && "$JOB_TOTAL" -gt 50 ]]; then
    if local_query -e "ALTER INSTANCE DISABLE INNODB REDO_LOG;" 2>>"$LOG_FILE"; then
      REDO_DISABLED=1
      log "InnoDB redo log disabled for bulk load (FAST_RESTORE_DISABLE_REDO=1)."
    fi
  fi

  write_state "copying"
  log "Copying ${JOB_TOTAL} table(s) with ${PARALLEL} worker(s) …"
  xargs -d '\n' -r -P "$PARALLEL" -I{} bash "$SELF" --worker {} < "${WORK}/jobs.tsv" || true
fi

# ── 5. Views, routines, events ────────────────────────────────────────────────
write_state "objects"
mapfile -t OBJ_DBS < <(awk -F'\t' -v full="$FULL_FLAG" '
  FILENAME == ARGV[1] { if ($2 == "@objects") old[$1] = $3; next }
  FILENAME == ARGV[2] { ok[$1] = 1; next }
  ($1 in ok) && (full || old[$1] != $2) { print $1 }' "$FP_FILE" "${WORK}/schemas.tsv" "${WORK}/objects.tsv")

if [[ "${#OBJ_DBS[@]}" -gt 0 ]]; then
  log "Refreshing views / routines / events in ${#OBJ_DBS[@]} database(s) …"
  for db in "${OBJ_DBS[@]}"; do
    obj_ok=1
    mapfile -t VIEWS < <(awk -F'\t' -v d="$db" '$1==d && $3=="VIEW" {print $2}' "${WORK}/remote_tables.tsv")
    if [[ "${#VIEWS[@]}" -gt 0 ]]; then
      remote_dump --no-data --skip-triggers "$db" "${VIEWS[@]}" 2>>"$LOG_FILE" \
        | local_load "$db" 2>>"$LOG_FILE" || obj_ok=0
    fi
    remote_dump --no-data --no-create-info --skip-triggers --routines --events "$db" 2>>"$LOG_FILE" \
      | local_load "$db" 2>>"$LOG_FILE" || obj_ok=0

    if [[ "$obj_ok" == "1" ]]; then
      awk -F'\t' -v OFS='\t' -v d="$db" '$1==d {print $1, $2}' "${WORK}/objects.tsv" >> "${WORK}/objects_done.tsv"
      log "  ✓ ${db}: ${#VIEWS[@]} view(s) + routines/events"
    else
      OBJ_FAILED=$((OBJ_FAILED + 1))
      log "[ERROR] ${db}: failed to refresh views/routines/events (see log above)"
    fi
  done
fi

write_state "finishing"
# finish() fires automatically via trap EXIT
