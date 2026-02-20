# Krea Onererp — Local DB Sync

Pulls the **remote MySQL production database** directly into a local Docker MySQL instance and keeps it in sync every **2–3 hours** via cron. No Cloud proxy required.

---

## How It Works

```
Remote MySQL (10.10.0.1:3306)
           │
           │  mysqldump (direct TCP)
           ▼
    .sql.gz backup file
           │
           ▼
 Local Docker MySQL (mysql_local)
           │
    cron: every 2 h
```

---

## Prerequisites

Run the installer script — it handles everything automatically:

```bash
chmod +x install_prerequisites.sh
./install_prerequisites.sh
```

| Tool | Supported OS |
|---|---|
| Docker & Docker Compose | Ubuntu, Debian, CentOS, RHEL, Fedora, Amazon Linux, macOS |
| `mysqldump` (mysql-client) | All of the above |
| `jq` | All of the above |

> **macOS:** Docker Desktop must be installed manually from https://docs.docker.com/desktop/install/mac-install/ — all other tools are installed via Homebrew automatically.

---

## Project Structure

```
erp_database_sync/
├── .env                  ← your local config (never commit)
├── .env.example          ← template
├── docker-compose.yml    ← local MySQL service
├── setup.sh              ← one-time setup
├── sync.sh               ← sync script (called by cron)
├── init/                 ← (optional) .sql files run on first MySQL start
└── README.md
```

---

## Configuration (`.env`)

Copy the template and set your values:

```bash
cp .env.example .env
```

| Variable              | Description                                 |
| --------------------- | ------------------------------------------- |
| `PROD_DB_HOST`        | Remote MySQL host IP                        |
| `PROD_DB_PORT`        | Remote MySQL port (default `3306`)          |
| `PROD_DB_NAME`        | Production database name                    |
| `PROD_DB_USER`        | Production MySQL user                       |
| `PROD_DB_PASS`        | Production MySQL password                   |
| `MYSQL_ROOT_PASSWORD` | Local MySQL root password                   |
| `MYSQL_DATABASE`      | Local database name (restored into)         |
| `MYSQL_LOCAL_PORT`    | Host port for local MySQL (default `3306`)  |
| `MYSQL_USERS_JSON`    | JSON array of users to create locally       |
| `SYNC_INTERVAL_HOURS` | `2` or `3` — cron interval                  |
| `SYNC_CRON_OVERRIDE`  | Custom cron expression (overrides interval) |
| `BACKUP_DIR`          | Where `.sql.gz` dumps are stored            |
| `LOG_DIR`             | Where sync logs are written                 |

### MySQL Users JSON

```json
MYSQL_USERS_JSON='[
  {"user":"app_user",  "password":"AppP@ssw0rd!",  "host":"%",        "privileges":"ALL PRIVILEGES"},
  {"user":"readonly",  "password":"R3adOnly#2024",  "host":"localhost", "privileges":"SELECT"}
]'
```

| Field        | Description                                              |
| ------------ | -------------------------------------------------------- |
| `user`       | MySQL username                                           |
| `password`   | User password                                            |
| `host`       | `%` = any host, `localhost` = local only                 |
| `privileges` | `ALL PRIVILEGES`, `SELECT`, `SELECT,INSERT,UPDATE`, etc. |

---

## Quick Start

```bash
# 1. Configure
cp .env.example .env
# Edit .env with your remote DB host, credentials, local passwords

# 2. Make scripts executable
chmod +x setup.sh sync.sh

# 3. Run one-time setup
./setup.sh
```

`setup.sh` will:

- Start local MySQL via Docker Compose and wait for it to be healthy
- Create all users from `MYSQL_USERS_JSON`
- Register the cron job (`0 */2 * * *` by default)
- Run the first sync immediately

---

## Scripts

### `setup.sh` — run once

```bash
./setup.sh
```

Idempotent — safe to re-run. Recreates users and updates the cron entry.

### `sync.sh` — run on demand or via cron

```bash
./sync.sh
```

Steps:

1. `mysqldump` remote DB → compressed `dump_YYYYMMDD_HHMMSS.sql.gz`
2. `CREATE DATABASE IF NOT EXISTS` in local MySQL
3. Restore dump into `mysql_local` container
4. Prune backups beyond the last 10

> The production password is passed via `MYSQL_PWD` environment variable — never via command-line arguments — to avoid exposure in process lists.

---

## Docker Compose

```bash
# Start MySQL
docker-compose up -d

# View logs
docker-compose logs -f mysql_local

# Stop
docker-compose down

# Destroy local data volume  ⚠
docker-compose down -v
```

Connect to local MySQL from your host:

```bash
mysql -h 127.0.0.1 -P 3306 -u root -p
```

---

## Sync Schedule

| Setting                             | Result                        |
| ----------------------------------- | ----------------------------- |
| `SYNC_INTERVAL_HOURS=2`             | `0 */2 * * *` — every 2 hours |
| `SYNC_INTERVAL_HOURS=3`             | `0 */3 * * *` — every 3 hours |
| `SYNC_CRON_OVERRIDE=30 1,4,7 * * *` | Uses exact expression         |

Check registered cron:

```bash
crontab -l
```

---

## Logs & Backups

| Path                                      | Contents                        |
| ----------------------------------------- | ------------------------------- |
| `$LOG_DIR/sync_YYYYMMDD_HHMMSS.log`       | Per-sync log                    |
| `$LOG_DIR/cron.log`                       | Aggregated cron output          |
| `$BACKUP_DIR/dump_YYYYMMDD_HHMMSS.sql.gz` | Compressed dumps (last 10 kept) |

```bash
# Live cron log
tail -f /var/log/erp_sync/cron.log

# List backups
ls -lh /tmp/erp_backups/

# Manual restore from a specific dump
gunzip < /tmp/erp_backups/dump_20240601_120000.sql.gz \
  | docker exec -i mysql_local mysql -uroot -p"$MYSQL_ROOT_PASSWORD" "$MYSQL_DATABASE"
```

---

## Troubleshooting

| Symptom                         | Fix                                                         |
| ------------------------------- | ----------------------------------------------------------- |
| `mysqldump: Access denied`      | Check `PROD_DB_USER` / `PROD_DB_PASS` in `.env`             |
| `Can't connect to MySQL server` | Verify `PROD_DB_HOST` is reachable: `telnet 10.10.0.1 3306` |
| `mysql_local not running`       | Run `docker-compose up -d`                                  |
| `MySQL did not become ready`    | `docker-compose logs mysql_local` — check root password     |
| Cron not running                | `crontab -l` — verify entry; check `$LOG_DIR/cron.log`      |
| `jq: command not found`         | `sudo apt install jq`                                       |

---

## Security Notes

- **Never commit** `.env` — add it to `.gitignore`
- `.env` contains production credentials — restrict file permissions: `chmod 600 .env`
- `mysqldump` uses `MYSQL_PWD` env var internally — password does not appear in `ps` output

```bash
# .gitignore
echo ".env" >> .gitignore
echo "*.sql.gz" >> .gitignore
```
