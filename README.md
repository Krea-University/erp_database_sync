# Krea Onererp — Local DB Sync

Pulls **all remote MySQL production databases** directly into a local Docker MySQL instance and keeps them in sync via cron.  
Syncs are **incremental**: only tables that changed since the last run are copied, several at a time.  
No Cloud SQL Proxy required — direct TCP connection.  
Includes a **web dashboard** to monitor status, view logs, and control the cron job from a browser.

> **Authorized Access Only** — This system is restricted to authorized users of the Krea System. Unauthorized access is prohibited.

---

## How It Works

```
Remote MySQL  (read-only user erp_sync_ro)
           │
           │ 1. fingerprint every table (information_schema / CHECKSUM TABLE)
           │ 2. compare with state/fingerprints.tsv from the last run
           │ 3. mysqldump ONLY changed tables — SYNC_PARALLEL at a time
           ▼
 backups/run_YYYYMMDD_HHMMSS_<mode>/<db>/<table>.sql.gz
           │
           ▼
 Local Docker MySQL  (:3306)    ← tuned for fast bulk loads
 Timezone : IST (+05:30)
 Auth     : mysql_native_password
           │
    cron   : any interval (a lock prevents overlapping runs)
           │
           ▼
 Web Dashboard  (:8080)  — systemd service: auto-restart + start on boot
```

### Sync modes

| Mode | What is copied | When |
|---|---|---|
| `incremental` (default) | Tables whose fingerprint changed, new tables, tables missing locally | Every cron run |
| `full` | Every table | Daily, first run after `FULL_SYNC_HOUR` (safety net), or on demand |

```bash
./sync.sh                # SYNC_MODE from .env (incremental)
./sync.sh --incremental
./sync.sh --full
```

Every run also:
- drops local tables/views deleted on production (capped by `SYNC_DROP_MAX`)
- refreshes views / routines / events of databases whose definitions changed
- runs `ANALYZE TABLE` on every restored table (accurate stats → good query plans)
- retries any table that failed in the previous run

**Change detection** (`SYNC_CHANGE_DETECT`):

| Value | How | Cost on production |
|---|---|---|
| `stats` (default) | `CREATE_TIME`, `UPDATE_TIME`, row estimate, data length, `AUTO_INCREMENT` from `information_schema` | Instant |
| `checksum` | `CHECKSUM TABLE` — exact | Reads every row of every table |

> `stats` can, rarely, miss an UPDATE-only change on a table MySQL evicted from its cache
> (e.g. after a production restart) — the daily full sync catches that. With `checksum`
> you can set `FULL_SYNC_HOUR=` (empty). Switching modes re-copies every table once.

> Each table is dumped with its own `--single-transaction` snapshot, so tables can be a few
> seconds apart in time. A table is briefly unavailable on the mirror while it is reloaded.

---

## Read-only Production User

Create a dedicated read-only account — run as an admin **on the production server**:

```bash
# edit <SYNC_SERVER_IP> and <STRONG_PASSWORD> in the file first
mysql -h <PROD_DB_HOST> -u root -p < sql/create_sync_readonly_user.sql
```

It grants only `SELECT, SHOW VIEW, TRIGGER, EVENT` (no write privileges, no `PROCESS`/`RELOAD`)
and caps the account at 8 concurrent connections. Then set in `.env`:

```env
PROD_DB_USER=erp_sync_ro
PROD_DB_PASS="<STRONG_PASSWORD>"
```

---

## Prerequisites

Run the installer — it handles Docker, jq, Python 3, Flask, and mysql-client automatically:

```bash
chmod +x install_prerequisites.sh
./install_prerequisites.sh
```

| Tool | Supported OS |
|---|---|
| Docker & Docker Compose plugin | Ubuntu, Debian, CentOS, RHEL, Fedora, Amazon Linux, macOS |
| `jq` | All of the above |
| `python3` + `pip3` + `Flask` | All of the above |

---

## Project Structure

```
erp_database_sync/
├── .env                      ← your local config (never commit)
├── .env.example              ← template — copy this to .env
├── docker-compose.yml        ← local MySQL service
├── mysql/
│   └── my.cnf                ← MySQL settings (timezone, sql_mode, etc.)
├── setup.sh                  ← one-time bootstrap (MySQL + cron)
├── sync.sh                   ← incremental / full sync (called by cron)
├── sql/
│   └── create_sync_readonly_user.sql  ← read-only production account
├── state/                    ← fingerprints + run history (created by sync.sh)
├── api.py                    ← web dashboard + REST API
├── start_api.sh              ← install / manage the dashboard service
├── requirements.txt          ← Python deps (Flask, waitress) → .venv
├── install_prerequisites.sh  ← install all tools
├── deploy_ubuntu.sh          ← Ubuntu server deploy helper
├── init/                     ← (optional) .sql files run on first MySQL start
└── README.md
```

---

## Quick Start

```bash
# 1. Copy and configure .env
cp .env.example .env
nano .env           # set PROD_DB_*, MYSQL_ROOT_PASSWORD, API_TOKEN

# 2. Make scripts executable
chmod +x setup.sh sync.sh start_api.sh

# 3. Run one-time setup (starts MySQL, creates users, registers cron, first sync)
./setup.sh

# 4. Start the web dashboard
./start_api.sh start
# → http://<server-ip>:8080
```

---

## Configuration (`.env`)

```bash
cp .env.example .env
```

### Production Database

| Variable | Description |
|---|---|
| `PROD_DB_HOST` | Remote MySQL host IP or hostname |
| `PROD_DB_PORT` | Remote MySQL port (default `3306`) |
| `PROD_DB_USER` | Production MySQL user |
| `PROD_DB_PASS` | Production MySQL password |

> **Special characters in password:** Wrap in double quotes and escape `$` with `\$`
> ```
> PROD_DB_PASS="myP@ss\$word&123"
> ```

### Local MySQL (Docker)

| Variable | Description |
|---|---|
| `MYSQL_ROOT_PASSWORD` | Local MySQL root password |
| `MYSQL_LOCAL_PORT` | Host port for local MySQL (default `3306`) |
| `MYSQL_USERS_JSON` | JSON array of extra users to create (see below) |

### Sync Schedule

| Variable | Description |
|---|---|
| `SYNC_INTERVAL_HOURS` | `2` or `3` — auto-generates cron expression |
| `SYNC_CRON_OVERRIDE` | Custom cron expression — overrides interval if set |

| Setting | Cron result |
|---|---|
| `SYNC_INTERVAL_HOURS=2` | `0 */2 * * *` — every 2 hours |
| `SYNC_INTERVAL_HOURS=3` | `0 */3 * * *` — every 3 hours |
| `SYNC_CRON_OVERRIDE="30 1,4,7 * * *"` | uses exact expression (quotes required — `.env` is sourced by bash) |
| `SYNC_CRON_OVERRIDE="*/30 * * * *"` | every 30 min — practical now that syncs are incremental |

> After changing the schedule, re-run `./setup.sh` (or edit `crontab -e`) to re-register the cron line.

### Sync Engine

| Variable | Default | Description |
|---|---|---|
| `SYNC_MODE` | `incremental` | `incremental` or `full` |
| `SYNC_CHANGE_DETECT` | `stats` | `stats` (instant) or `checksum` (exact) — see *Sync modes* |
| `SYNC_PARALLEL` | `4` | Tables copied at once. Keep ≤ the RO user's `MAX_USER_CONNECTIONS` − 2 |
| `FULL_SYNC_HOUR` | `2` | First run at/after this hour each day is full. Empty = never automatic |
| `SYNC_EXCLUDE_DBS` | — | Regex of databases to skip, e.g. `'test_.*\|old_erp'` |
| `SYNC_EXCLUDE_TABLES` | — | Regex of `db.table` to skip, e.g. `'erp\.audit_log\|.*\.tmp_.*'` |
| `SYNC_DROP_MISSING` | `1` | Drop local tables deleted on production |
| `SYNC_DROP_MAX` | `100` | Safety cap — skip drops if more than N would be dropped |
| `FAST_RESTORE_DISABLE_REDO` | `0` | `1` = disable InnoDB redo log while loading > 50 tables (2–3× faster; a power cut mid-load means re-creating the volume + full sync) |
| `MYSQLDUMP_EXTRA_OPTS` | — | Extra mysqldump flags, e.g. `--compress` over a WAN link |
| `MYSQL_BUFFER_POOL` | `1G` | Local InnoDB buffer pool — set to ~50–70% of RAM |
| `STATE_DIR` | `./state` | Fingerprints + run history |

### Backup Retention

| Variable | Default | Description |
|---|---|---|
| `BACKUP_DIR` | `/var/erp_sync/backups` | Where `.sql.gz` dumps are stored |
| `LOG_DIR` | `/var/erp_sync/logs` | Where sync logs are written |
| `BACKUP_KEEP_DAYS` | `1` | Delete dumps older than N days |
| `BACKUP_KEEP_COUNT` | `3` | Keep N most recent sync runs (`0` = delete dumps right after restore) |
| `LOG_KEEP_COUNT` | `14` | Keep N most recent log files |

> Pruning runs automatically on every sync exit — even if the sync fails mid-way.

### Web Dashboard

| Variable | Default | Description |
|---|---|---|
| `API_TOKEN` | — | Secret token required to log in to the dashboard |
| `API_PORT` | `8080` | Port the dashboard listens on |

### MySQL Users JSON

```env
MYSQL_USERS_JSON='[
  {"user":"app_user",  "password":"AppP@ssw0rd!",  "host":"%",        "privileges":"ALL PRIVILEGES"},
  {"user":"readonly",  "password":"R3adOnly#2024",  "host":"localhost", "privileges":"SELECT"}
]'
```

| Field | Description |
|---|---|
| `user` | MySQL username |
| `password` | User password |
| `host` | `%` = any host, `localhost` = local only |
| `privileges` | `ALL PRIVILEGES`, `SELECT`, `SELECT,INSERT,UPDATE`, etc. |

---

## MySQL Settings (`mysql/my.cnf`)

The local MySQL container is pre-configured with:

| Setting | Value | Reason |
|---|---|---|
| `default-time-zone` | `+05:30` | IST timezone |
| `default-authentication-plugin` | `mysql_native_password` | SQLyog / old client compatibility |
| `sql-mode` | `STRICT_TRANS_TABLES,...` | `ONLY_FULL_GROUP_BY` removed — fixes GROUP BY errors |
| `log-bin-trust-function-creators` | `1` | Allows stored functions with binary log enabled |
| `group-concat-max-len` | `4294967295` | Maximum GROUP_CONCAT length |
| `max-execution-time` | `60000` | Query timeout — 60 seconds |
| `event-scheduler` | `OFF` | Production's events are copied but must not run on the mirror |
| `innodb_flush_log_at_trx_commit` | `2` | Bulk-load speed (the mirror can always be re-synced) |
| `innodb_doublewrite` | `OFF` | Halves write I/O during restores |
| `innodb_redo_log_capacity` | `2G` | Fewer checkpoints during big loads |
| `max_allowed_packet` | `1G` | Large rows / BLOBs |

> After changing `my.cnf` or `MYSQL_BUFFER_POOL`: `docker compose up -d` (recreates the container; the data volume is kept).

---

## Web Dashboard

### Starting & Managing (`start_api.sh`)

```bash
chmod +x start_api.sh

./start_api.sh start      # install/refresh the service and start it
./start_api.sh stop       # stop (stays enabled at boot)
./start_api.sh restart    # same as start
./start_api.sh status     # state, crash-restart count, health check, URL
./start_api.sh logs       # tail -f the API log
./start_api.sh uninstall  # remove the service / autostart
```

Run `./start_api.sh start` **once**. From then on the dashboard:
- runs as systemd service `erp_api.service` under your user (so it sees your crontab)
- **restarts automatically within 3 s if it crashes** (`Restart=always`, no retry limit)
- **starts on boot** — nobody has to log in and run the script again
- is served by `waitress` (production WSGI server) instead of Flask's dev server
- lives in `.venv` (no `externally-managed-environment` pip errors on Ubuntu 23.04+)
- keeps a dashboard-started sync running if the dashboard itself restarts (`KillMode=process`)

Without systemd (containers, WSL1) it falls back to a watchdog loop plus an `@reboot` cron entry.

Open `http://<server-ip>:8080` in a browser and enter your `API_TOKEN` to connect.

### Dashboard Features

| Feature | Description |
|---|---|
| Live progress | Running sync: phase, tables done / total, progress bar, elapsed, ETA, failures, **Stop** |
| Sync cards | Cron state, last sync + result, next scheduled run, average duration |
| Infra cards | Local MySQL container health/uptime, mirror size, disk free, backups & logs |
| Sync history | Last 30 runs — mode, trigger, status, duration bar, copied / unchanged / failed, data size |
| Databases | Per-DB table count, production vs local size, what the last run copied |
| Slowest tables | Failed + slowest tables of the last run |
| System & config | Host load/memory, uptimes, production endpoint, sync settings |
| Enable / Disable Cron | Toggle the sync cron job on or off with one click |
| Incremental / Full Sync | Start a sync now (disabled while one is running) |
| Log Reports | Sync logs + system logs (api, launcher, cron), line filter, follow mode |
| Auto-refresh | Every 30 s — every 5 s while a sync is running |

### REST API Endpoints

| Method | Path | Auth | Description |
|---|---|---|---|
| `GET` | `/` | — | Web dashboard UI |
| `GET` | `/api/health` | — | Liveness probe `{"ok": true}` |
| `GET` | `/api/status` | — | Cron state, next run, last sync + result, running, backup stats |
| `GET` | `/api/overview` | `X-API-Token` | Everything the dashboard shows (progress, history, DBs, system) |
| `POST` | `/api/cron/enable` | `X-API-Token` | Re-enable cron job |
| `POST` | `/api/cron/disable` | `X-API-Token` | Disable cron job |
| `POST` | `/api/sync/trigger` | `X-API-Token` | Start a sync — body `{"mode": "incremental"}` or `{"mode": "full"}`; `409` if one is running |
| `POST` | `/api/cron/run` | `X-API-Token` | Same as `/api/sync/trigger` |
| `POST` | `/api/sync/stop` | `X-API-Token` | Stop the running sync |
| `GET` | `/api/logs` | `X-API-Token` | List recent log files |
| `GET` | `/api/logs/<name>?tail=800` | `X-API-Token` | Last N lines of a log file |

```bash
# Example — disable cron via curl
curl -X POST http://10.10.3.44:8080/api/cron/disable \
     -H "X-API-Token: ERP@Sync#2026!"
```

---

## Docker

```bash
# Start MySQL
docker compose up -d

# View container logs
docker compose logs -f mysql_local

# Stop
docker compose down

# Destroy local data volume  ⚠
docker compose down -v
```

Connect directly to local MySQL:
```bash
mysql -h 127.0.0.1 -P 3306 -u root -p
```

---

## Ubuntu Server Deploy

A helper script automates full Ubuntu setup (Docker install + UFW rules + directories):

```bash
chmod +x deploy_ubuntu.sh
./deploy_ubuntu.sh
```

Open firewall ports for MySQL and the dashboard:

```bash
ufw allow 3306/tcp
ufw allow 8080/tcp
```

> **Proxmox VM:** Also add inbound TCP rules in the Proxmox Web UI:  
> **VM → Firewall → Add rule → Direction: in, Protocol: tcp, Dest. port: 3306 / 8080**

---

## Logs & Backups

| Path | Contents |
|---|---|
| `$LOG_DIR/sync_YYYYMMDD_HHMMSS.log` | Per cron-sync log |
| `$LOG_DIR/launcher.log` | Dashboard-triggered syncs (output before the sync log opens) |
| `$LOG_DIR/api.log` | Web dashboard process log |
| `$BACKUP_DIR/run_YYYYMMDD_HHMMSS_<mode>/<db>/<table>.sql.gz` | Per-table dumps of one sync run |
| `state/history.jsonl` | One JSON line per run (duration, counts, status) |
| `state/fingerprints.tsv` | Change-detection state — delete it to force a full re-copy |

```bash
# Tail the latest sync log
./start_api.sh logs

# List backups with sizes
ls -lh /var/erp_sync/backups/

# Manually restore one table from a run
gunzip < /var/erp_sync/backups/run_20261009_100000_full/erp_main/orders.sql.gz \
  | docker exec -i mysql_local mysql -uroot -p"$MYSQL_ROOT_PASSWORD" erp_main
```

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `mysqldump: Access denied` | Check `PROD_DB_USER` / `PROD_DB_PASS` in `.env` |
| `Can't connect to MySQL server` | `telnet $PROD_DB_HOST $PROD_DB_PORT` — verify firewall |
| `mysql_local not running` | `docker compose up -d` |
| `MySQL did not become ready` | `docker compose logs mysql_local` — check root password |
| Cron not running | `crontab -l` — verify entry; check `$LOG_DIR` |
| Port 3306 unreachable from other hosts | Check Proxmox firewall → add inbound TCP 3306 rule |
| `ERROR 2058: caching_sha2_password` | Ensure `mysql/my.cnf` is mounted and container restarted |
| Old backups not deleted | Check `BACKUP_KEEP_DAYS`/`BACKUP_KEEP_COUNT` in `.env`; look for prune lines in sync log |
| Dashboard shows "Unauthorized" | Token in browser must match `API_TOKEN` in `.env` |
| Dashboard not reachable | Run `./start_api.sh status`; check `./start_api.sh logs` |
| Dashboard keeps restarting | `./start_api.sh status` shows the restart count; the cause is in `api.log` |
| `jq: command not found` | `sudo apt install jq` or run `./install_prerequisites.sh` |
| Flask not found / `externally-managed-environment` | `rm -rf .venv && ./start_api.sh start` |
| "Another sync is already running — skipping" | Expected when runs overlap — watch the dashboard's live progress |
| Sync result `PARTIAL` | Failed tables are listed on the dashboard and retried automatically next run |
| One table looks out of date | Run a Full Sync, or switch to `SYNC_CHANGE_DETECT=checksum` |
| Re-copy everything from scratch | `rm state/fingerprints.tsv && ./sync.sh --full` |

---

## Security Notes

- **Never commit** `.env` — it is listed in `.gitignore`
- Restrict file permissions: `chmod 600 .env`
- Change `API_TOKEN` from the default to a strong, unique value
- Dashboard binds to `0.0.0.0` — consider a reverse proxy (nginx) if exposing publicly
- Sync with the read-only `erp_sync_ro` account (`sql/create_sync_readonly_user.sql`)
- MySQL passwords reach the container via `MYSQL_PWD` — never on a command line visible in `ps`

```bash
echo ".env"     >> .gitignore
echo "*.sql.gz" >> .gitignore
```

---

*© 2026 Krea IT. All rights reserved.*  
*Authorized Access Only — This system is restricted to authorized users of the Krea System. Unauthorized access is prohibited.*
