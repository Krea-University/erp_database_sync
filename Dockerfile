# =============================================================================
#  Dockerfile  –  ERP Sync Web Dashboard (api.py)
#  Build: docker build -t erp_api .
#  Run:   ./start_api.sh start
# =============================================================================

FROM python:3.11-slim

WORKDIR /app

# cron  → provides the `crontab` binary (enable/disable cron from the UI)
# bash  → needed by sync.sh
RUN apt-get update \
 && apt-get install -y --no-install-recommends cron bash \
 && rm -rf /var/lib/apt/lists/*

# Minimal Docker CLI — lets sync.sh call `docker exec mysql_local …`
COPY --from=docker:24-cli /usr/local/bin/docker /usr/local/bin/docker

# Python dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Application
COPY api.py .

EXPOSE 8080

CMD ["python3", "api.py"]
