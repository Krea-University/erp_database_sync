# Krea Onererp — Local DB Sync

Pulls **all remote MySQL production databases** directly into a local Docker MySQL instance and keeps them in sync every **2–3 hours** via cron.  
No Cloud SQL Proxy required — direct TCP connection.  
Includes a **web dashboard** to monitor status, view logs, and control the cron job from a browser.

---

## How It Works

```
Remote MySQL (Cloud SQL / VPS)
           │
           │  mysqldump --all-databases (direct TCP)
           ▼
    dump_all_YYYYMMDD_HHMMSS.sql.gz
           │
           ▼
 Local Docker MySQL  (:3306)
 Timezone: IST (+05:30)
 Auth: mysql_native_password
           │
    cron: every 2 h
           │
           ▼
 Web Dashboard  (:8080)
```

---

## Prerequisites

Run the installer — it handles Docker, jq, and mysql-client automatically:

```bash
chmod +x install_prerequisites.sh
./install_prerequisites.sh
```

| Tool | Supported OS |
|---|---|
| Docker & Docker Compose plugin | Ubuntu, Debian, CentOS, RHEL, Fedora, Amazon Linux, macOS |
| `jq` | All of the above |
| `python3` + `pip3` | Required for the web dashboard |

---

## Project Structure

```
erp_database_sync/
├── .env                    ← your local config (never commit)
├── .env.example            ← template — copy this to .env
├── docker-compose.yml      ← local MySQL service
├── mysql/
│   └── my.cnf              ← MySQL settings (timezone, sql_mode, etc.)
├── setup.sh                ← one-time bootstrap
├── sync.sh                 ← sync script (called by cron)
├── api.py                  ← web dashboard + REST API
├── requirements.txt        ← Python deps (Flask)
├── deploy_ubuntu.sh        ← Ubuntu server deploy helper
├── install_prerequisites.sh
├── init/                   ← (optional) .sql files run on first MySQL start
└── README.md
```

---

## Quick Start

```bash
# 1. Copy and configure .env
cp .env.example .env
nano .env          # fill in PROD_DB_*, MYSQL_ROOT_PASSWORD, API_TOKEN

# 2. Make scripts executable
chmod +x setup.sh sync.sh

# 3. Run one-time setup (starts MySQL, creates users, registers cron, first sync)
./setup.sh

# 4. Start the web dashboard
pip3 install -r requirements.txt
python3 api.py     # → http://<server-ip>:8080
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
| `SYNC_CRON_OVERRIDE=30 1,4,7 * * *` | uses exact expression |

### Backup Retention

| Variable | Default | Description |
|---|---|---|
| `BACKUP_DIR` | `/var/erp_sync/backups` | Where `.sql.gz` dumps are stored |
| `LOG_DIR` | `/var/erp_sync/logs` | Where sync logs are written |
| `BACKUP_KEEP_DAYS` | `1` | Delete dumps older than N days |
| `BACKUP_KEEP_COUNT` | `3` | Always keep at least N most recent dumps |
| `LOG_KEEP_COUNT` | `14` | Keep N most recent log files |

> Pruning runs automatically on every sync exit — even if the sync fails.

### Web Dashboard

| Variable | Default | Description |
|---|---|---|
| `API_TOKEN` | — | Secret token shown on the login page |
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
| `max-execution-time` | `60000` | Query timeout 60 seconds |

---

## Web Dashboard

Start the dashboard:

```bash
pip3 install -r requirements.txt
python3 api.py
```

Open `http://<server-ip>:8080` in a browser and enter your `API_TOKEN`.

### Dashboard Features

| Feature | Description |
|---|---|
| Status cards | Cron state, last sync time, backup count/size, log count |
| Enable / Disable Cron | Toggle the sync cron job on or off |
| Sync Now | Trigger a manual sync immediately |
| Log Reports | Browse and view the last 500 lines of any sync log |
| Auto-refresh | Status refreshes every 30 seconds |

### REST API Endpoints

| Method | Path | Auth | Description |
|---|---|---|---|
| `GET` | `/` | — | Web dashboard |
| `GET` | `/api/status` | — | JSON status (cron, last sync, backup stats) |
| `POST` | `/api/cron/enable` | `X-API-Token` | Re-enable cron job |
| `POST` | `/api/cron/disable` | `X-API-Token` | Disable cron job |
| `POST` | `/api/sync/trigger` | `X-API-Token` | Run sync in background now |
| `GET` | `/api/logs` | `X-API-Token` | List recent log files |
| `GET` | `/api/logs/<name>` | `X-API-Token` | View log file content |

Send the token as a header:
```bash
curl -X POST http://10.10.3.44:8080/api/cron/disable \
     -H "X-API-Token: ERP@Sync#2026!"
```

Run as a background service:
```bash
nohup python3 api.py >> /var/erp_sync/logs/api.log 2>&1 &
```

---

## Docker

```bash
# Start MySQL
docker compose up -d

# View logs
docker compose logs -f mysql_local

# Stop
docker compose down

# Destroy local data volume  ⚠
docker compose down -v
```

Connect directly:
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

To allow external connections, make sure port `3306` (MySQL) and `8080` (dashboard) are open:

```bash
ufw allow 3306/tcp
ufw allow 8080/tcp
```

> If running inside Proxmox, also add inbound TCP rules in:  
> **Proxmox Web UI → VM → Firewall → Add rule → Direction: in, Protocol: tcp, Port: 3306 / 8080**

---

## Logs & Backups

| Path | Contents |
|---|---|
| `$LOG_DIR/sync_YYYYMMDD_HHMMSS.log` | Per-sync log |
| `$LOG_DIR/manual_sync_YYYYMMDD_HHMMSS.log` | Logs from dashboard-triggered syncs |
| `$BACKUP_DIR/dump_all_YYYYMMDD_HHMMSS.sql.gz` | Compressed full dump |

```bash
# Live log
tail -f /var/erp_sync/logs/sync_*.log | tail -1

# List backups with sizes
ls -lh /var/erp_sync/backups/

# Manual restore from a specific dump
gunzip < /var/erp_sync/backups/dump_all_20260324_120000.sql.gz \
  | docker exec -i mysql_local mysql -uroot -p"$MYSQL_ROOT_PASSWORD"
```

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `mysqldump: Access denied` | Check `PROD_DB_USER` / `PROD_DB_PASS` in `.env` |
| `Can't connect to MySQL server` | `telnet $PROD_DB_HOST $PROD_DB_PORT` — verify firewall |
| `mysql_local not running` | `docker compose up -d` |
| `MySQL did not become ready` | `docker compose logs mysql_local` — check root password |
| Cron not running | `crontab -l` — verify entry; check log files |
| Port 3306 unreachable from other hosts | Check Proxmox firewall → add inbound TCP 3306 rule |
| `ERROR 2058: caching_sha2_password` | Ensure `mysql/my.cnf` is mounted and container restarted |
| Old backups not deleted | Verify `BACKUP_KEEP_DAYS` and `BACKUP_KEEP_COUNT` in `.env`; check logs for prune output |
| Dashboard shows "Unauthorized" | Token in browser must match `API_TOKEN` in `.env` |
| `jq: command not found` | `sudo apt install jq` or `pip3 install jq` |

---

## Security Notes

- **Never commit** `.env` — it is in `.gitignore`
- Restrict file permissions: `chmod 600 .env`
- Change `API_TOKEN` from the default to something strong
- Dashboard runs on `0.0.0.0` — restrict with a reverse proxy (nginx) if exposing externally
- `mysqldump` does not expose passwords in process lists (`--password=` flag is used inside Docker)

```bash
echo ".env"     >> .gitignore
echo "*.sql.gz" >> .gitignore
```
