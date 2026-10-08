#!/usr/bin/env python3
"""
api.py  –  Web dashboard + HTTP API for ERP DB sync control
Usage:
  ./start_api.sh start    # managed: systemd service, auto-restart + boot start
  python3 api.py          # foreground (debugging)
"""
import os
import glob
import json
import time
import shutil
import signal
import socket
import logging
import datetime
import threading
import subprocess
import pathlib
from functools import wraps
from flask import Flask, jsonify, request, Response

app = Flask(__name__)
SCRIPT_DIR  = pathlib.Path(__file__).resolve().parent
CRON_MARKER = "# erp_database_sync"
STARTED_AT  = time.time()
log = logging.getLogger("erp_api")
logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")


# ── Load simple vars from .env ────────────────────────────────────────────────
ENV_KEYS = {
    "LOG_DIR", "BACKUP_DIR", "STATE_DIR", "API_TOKEN", "API_PORT", "LOG_KEEP_COUNT",
    "BACKUP_KEEP_COUNT", "BACKUP_KEEP_DAYS", "SYNC_MODE", "SYNC_PARALLEL",
    "SYNC_CHANGE_DETECT", "FULL_SYNC_HOUR", "SYNC_EXCLUDE_DBS", "SYNC_EXCLUDE_TABLES",
    "PROD_DB_HOST", "PROD_DB_PORT", "PROD_DB_USER", "MYSQL_LOCAL_PORT", "MYSQL_BUFFER_POOL",
}


def _unquote(val):
    val = val.strip()
    if len(val) >= 2 and val[0] == val[-1] and val[0] in "'\"":
        quote, val = val[0], val[1:-1]
        if quote == '"':
            for esc in ('\\$', '\\"', '\\`', '\\\\'):
                val = val.replace(esc, esc[1])
    return val


def _load_env():
    env_path = SCRIPT_DIR / ".env"
    if not env_path.exists():
        return
    for line in env_path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, val = line.partition("=")
        key = key.strip()
        if key in ENV_KEYS:
            os.environ.setdefault(key, _unquote(val))


_load_env()

API_TOKEN  = os.environ.get("API_TOKEN", "")
BACKUP_DIR = os.environ.get("BACKUP_DIR") or str(SCRIPT_DIR / "backups")
LOG_DIR    = os.environ.get("LOG_DIR")    or str(SCRIPT_DIR / "logs")
STATE_DIR  = os.environ.get("STATE_DIR")  or str(SCRIPT_DIR / "state")
SYNC_SH    = str(SCRIPT_DIR / "sync.sh")


# ── Token auth decorator ──────────────────────────────────────────────────────
def require_token(f):
    @wraps(f)
    def wrapper(*args, **kwargs):
        if not API_TOKEN:
            return jsonify({"error": "API_TOKEN not set in .env"}), 500
        t = request.headers.get("X-API-Token", "") or request.args.get("token", "")
        if t != API_TOKEN:
            return jsonify({"error": "Unauthorized"}), 401
        return f(*args, **kwargs)
    return wrapper


@app.errorhandler(Exception)
def _on_error(e):
    code = getattr(e, "code", 500)
    if code == 500:
        log.exception("Unhandled error on %s", request.path)
    return jsonify({"error": str(e) if code != 500 else "Internal server error"}), code


# ── Small helpers ─────────────────────────────────────────────────────────────
_cache, _cache_lock = {}, threading.Lock()


def cached(ttl):
    """Memoise a no-arg function for `ttl` seconds."""
    def deco(fn):
        @wraps(fn)
        def wrapper():
            now = time.time()
            with _cache_lock:
                hit = _cache.get(fn.__name__)
                if hit and now - hit[0] < ttl:
                    return hit[1]
            val = fn()
            with _cache_lock:
                _cache[fn.__name__] = (now, val)
            return val
        return wrapper
    return deco


def _mtime(path):
    try:
        return os.path.getmtime(path)
    except OSError:
        return 0


def _fmt_ts(ts):
    return datetime.datetime.fromtimestamp(ts).strftime("%Y-%m-%d %H:%M:%S") if ts else None


def _read_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def _pid_alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except PermissionError:
        return True
    except (OSError, ValueError, TypeError):
        return False


def _tail_lines(path, n):
    """Last n lines of a file without reading all of it."""
    with open(path, "rb") as f:
        f.seek(0, os.SEEK_END)
        end = pos = f.tell()
        data, block = b"", 64 * 1024
        while pos > 0 and data.count(b"\n") <= n:
            pos = max(0, pos - block)
            f.seek(pos)
            data = f.read(end - pos)
    lines = data.decode("utf-8", errors="replace").splitlines()
    return lines[-n:], pos == 0


def _dir_size(path):
    total = 0
    try:
        with os.scandir(path) as it:
            for e in it:
                try:
                    if e.is_dir(follow_symlinks=False):
                        total += _dir_size(e.path)
                    else:
                        total += e.stat(follow_symlinks=False).st_size
                except OSError:
                    pass
    except OSError:
        pass
    return total


def _disk(path):
    p = pathlib.Path(path)
    while not p.exists() and p != p.parent:
        p = p.parent
    try:
        u = shutil.disk_usage(str(p))
        return {"path": str(path), "total": u.total, "used": u.used, "free": u.free,
                "pct": round(u.used * 100 / u.total, 1) if u.total else 0}
    except OSError:
        return None


def _run(cmd, timeout=8):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        return -1, ""


# ── Cron helpers ──────────────────────────────────────────────────────────────
def _crontab_available():
    return shutil.which("crontab") is not None


def _read_crontab():
    if not _crontab_available():
        return ""
    code, out = _run(["crontab", "-l"])
    return out + "\n" if code == 0 else ""


def _write_crontab(content):
    if not _crontab_available():
        raise RuntimeError("crontab not available on this system")
    subprocess.run(["crontab", "-"], input=content, text=True, check=True, timeout=10)


def _cron_info():
    if not _crontab_available():
        return False, None
    lines = _read_crontab().splitlines()
    for i, line in enumerate(lines):
        if CRON_MARKER in line:
            for j in range(i + 1, min(i + 3, len(lines))):
                cand = lines[j].strip()
                if cand and "sync.sh" in cand:
                    disabled = cand.startswith("#")
                    expr = cand.replace("# DISABLED: ", "", 1).lstrip("#").strip()
                    return not disabled, expr
    return False, None


def _cron_field(spec, lo, hi):
    vals = set()
    for part in spec.split(","):
        step = 1
        if "/" in part:
            part, s = part.split("/", 1)
            step = int(s)
        if part == "*":
            a, b = lo, hi
        elif "-" in part:
            a, b = (int(x) for x in part.split("-", 1))
        else:
            a = int(part)
            b = hi if step > 1 else a
        vals.update(range(a, b + 1, step))
    return vals


def _next_cron_run(expr):
    """Next fire time of a 5-field cron expression (no @macros)."""
    fields = (expr or "").split()
    if len(fields) < 5 or fields[0].startswith("@"):
        return None
    try:
        mins  = _cron_field(fields[0], 0, 59)
        hours = _cron_field(fields[1], 0, 23)
        doms  = _cron_field(fields[2], 1, 31)
        mons  = _cron_field(fields[3], 1, 12)
        dows  = {d % 7 for d in _cron_field(fields[4], 0, 7)}
    except ValueError:
        return None
    dom_any, dow_any = fields[2] == "*", fields[4] == "*"
    t = datetime.datetime.now().replace(second=0, microsecond=0) + datetime.timedelta(minutes=1)
    for _ in range(400 * 24):
        dow = (t.weekday() + 1) % 7
        if dom_any or dow_any:
            day_ok = (t.day in doms) and (dow in dows)
        else:
            day_ok = (t.day in doms) or (dow in dows)
        if t.month not in mons or not day_ok:
            t = (t + datetime.timedelta(days=1)).replace(hour=0, minute=0)
            continue
        if t.hour not in hours:
            t = (t + datetime.timedelta(hours=1)).replace(minute=0)
            continue
        for m in sorted(mins):
            if m >= t.minute:
                return t.replace(minute=m)
        t = (t + datetime.timedelta(hours=1)).replace(minute=0)
    return None


# ── Sync state (written by sync.sh into STATE_DIR) ────────────────────────────
def _current_run():
    cur = _read_json(os.path.join(STATE_DIR, "current.json"))
    if not cur or not _pid_alive(cur.get("pid")):
        return None
    ok = failed = 0
    try:
        with open(os.path.join(STATE_DIR, "current_results.tsv"), encoding="utf-8", errors="replace") as f:
            for line in f:
                if line.startswith("OK"):
                    ok += 1
                elif line.startswith("FAIL"):
                    failed += 1
    except OSError:
        pass
    elapsed = int(time.time() - cur.get("started_epoch", time.time()))
    done, total = ok + failed, cur.get("total", 0)
    eta = int(elapsed / done * (total - done)) if cur.get("phase") == "copying" and done else None
    cur.update({"done": done, "ok": ok, "failed": failed, "elapsed_s": elapsed, "eta_s": eta})
    return cur


def _history(limit=30):
    path = os.path.join(STATE_DIR, "history.jsonl")
    if not os.path.exists(path):
        return []
    lines, _ = _tail_lines(path, limit)
    out = []
    for line in reversed(lines):
        try:
            out.append(json.loads(line))
        except ValueError:
            pass
    return out


def _last_run_tables(limit=10):
    """Slowest tables of the most recent (or current) run."""
    rows = []
    try:
        with open(os.path.join(STATE_DIR, "current_results.tsv"), encoding="utf-8", errors="replace") as f:
            for line in f:
                p = line.rstrip("\n").split("\t")
                if len(p) >= 6:
                    rows.append({"status": p[0], "db": p[1], "table": p[2],
                                 "bytes": int(p[4] or 0), "secs": int(p[5] or 0)})
    except (OSError, ValueError):
        pass
    failed = [r for r in rows if r["status"] != "OK"]
    slow = sorted(rows, key=lambda r: r["secs"], reverse=True)[:limit]
    return {"count": len(rows), "slowest": slow, "failed": failed[:50]}


def _log_files():
    files = glob.glob(f"{LOG_DIR}/sync_*.log") + glob.glob(f"{LOG_DIR}/manual_sync_*.log")
    return sorted(files, key=_mtime, reverse=True)


def _system_log_files():
    return [p for p in (f"{LOG_DIR}/api.log", f"{LOG_DIR}/launcher.log", f"{LOG_DIR}/cron.log")
            if os.path.isfile(p)]


@cached(60)
def _backup_stats():
    runs = glob.glob(f"{BACKUP_DIR}/run_*")
    legacy = glob.glob(f"{BACKUP_DIR}/dump_all_*.sql.gz")
    size = sum(_dir_size(r) for r in runs) + sum(os.path.getsize(f) for f in legacy if os.path.exists(f))
    return {"count": len(runs) + len(legacy), "bytes": size}


@cached(15)
def _mysql_container():
    code, out = _run(["docker", "inspect", "-f",
                      "{{.State.Status}}|{{.State.StartedAt}}|{{.Config.Image}}|"
                      "{{if .State.Health}}{{.State.Health.Status}}{{end}}|{{.RestartCount}}",
                      "mysql_local"])
    if code != 0 or not out:
        return {"status": "missing" if code == 1 else "unknown"}
    status, started, image, health, restarts = (out.split("|") + [""] * 5)[:5]
    started_epoch = None
    try:
        started_epoch = datetime.datetime.fromisoformat(started[:19]).replace(
            tzinfo=datetime.timezone.utc).timestamp()
    except ValueError:
        pass
    return {"status": status, "health": health or None, "image": image,
            "started_epoch": started_epoch, "restarts": int(restarts or 0)}


def _sysinfo():
    info = {"hostname": socket.gethostname(), "cpus": os.cpu_count(),
            "api_uptime_s": int(time.time() - STARTED_AT), "api_pid": os.getpid()}
    try:
        info["load"] = [round(x, 2) for x in os.getloadavg()]
    except (OSError, AttributeError):
        info["load"] = None
    try:
        mem = {}
        with open("/proc/meminfo") as f:
            for line in f:
                k, v = line.split(":", 1)
                mem[k] = int(v.split()[0]) * 1024
        info["mem_total"], info["mem_avail"] = mem.get("MemTotal"), mem.get("MemAvailable")
        with open("/proc/uptime") as f:
            info["host_uptime_s"] = int(float(f.read().split()[0]))
    except (OSError, ValueError):
        pass
    return info


# ── API routes ────────────────────────────────────────────────────────────────
@app.route("/api/health")
def api_health():
    return jsonify({"ok": True, "uptime_s": int(time.time() - STARTED_AT)})


@app.route("/api/status")
def api_status():
    enabled, expr = _cron_info()
    logs = _log_files()
    hist = _history(1)
    last = hist[0] if hist else None
    bk = _backup_stats()
    nxt = _next_cron_run(expr) if enabled else None
    return jsonify({
        "cron_enabled":    enabled,
        "cron_expr":       expr,
        "next_run":        nxt.strftime("%Y-%m-%d %H:%M:%S") if nxt else None,
        "last_sync":       last["finished"] if last else _fmt_ts(_mtime(logs[0]) if logs else 0),
        "last_status":     last["status"] if last else None,
        "running":         _current_run() is not None,
        "log_count":       len(logs),
        "backup_count":    bk["count"],
        "backup_size_gb":  round(bk["bytes"] / 1024 ** 3, 2),
    })


@app.route("/api/overview")
@require_token
def api_overview():
    enabled, expr = _cron_info()
    nxt = _next_cron_run(expr) if enabled else None
    hist = _history(30)
    done = [h for h in hist if h.get("status") in ("success", "partial")]
    db_stats = _read_json(os.path.join(STATE_DIR, "db_stats.json")) or {}
    return jsonify({
        "now":        datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "running":    _current_run(),
        "cron":       {"enabled": enabled, "expr": expr,
                       "next_run": nxt.strftime("%Y-%m-%d %H:%M:%S") if nxt else None,
                       "next_in_s": int((nxt - datetime.datetime.now()).total_seconds()) if nxt else None},
        "history":    hist,
        "averages":   {
            "incremental_s": _avg([h["duration_s"] for h in done if h.get("mode") == "incremental"][:10]),
            "full_s":        _avg([h["duration_s"] for h in done if h.get("mode") == "full"][:5]),
        },
        "last_full":  _read_text(os.path.join(STATE_DIR, "last_full_date")),
        "last_tables": _last_run_tables(),
        "databases":  db_stats,
        "mysql":      _mysql_container(),
        "backups":    _backup_stats(),
        "disk":       {"backups": _disk(BACKUP_DIR), "docker": _disk("/var/lib/docker"), "logs": _disk(LOG_DIR)},
        "system":     _sysinfo(),
        "config":     {k: os.environ.get(k, "") for k in (
            "SYNC_MODE", "SYNC_PARALLEL", "SYNC_CHANGE_DETECT", "FULL_SYNC_HOUR",
            "SYNC_EXCLUDE_DBS", "SYNC_EXCLUDE_TABLES", "BACKUP_KEEP_COUNT", "BACKUP_KEEP_DAYS",
            "LOG_KEEP_COUNT", "PROD_DB_HOST", "PROD_DB_PORT", "PROD_DB_USER", "MYSQL_LOCAL_PORT",
            "MYSQL_BUFFER_POOL")},
    })


def _avg(vals):
    return int(sum(vals) / len(vals)) if vals else None


def _read_text(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read().strip() or None
    except OSError:
        return None


@app.route("/api/cron/enable", methods=["POST"])
@require_token
def api_cron_enable():
    lines = _read_crontab().splitlines()
    new, changed = [], False
    for line in lines:
        if line.strip().startswith("# DISABLED:") and "sync.sh" in line:
            new.append(line.replace("# DISABLED: ", "", 1))
            changed = True
        else:
            new.append(line)
    if changed:
        _write_crontab("\n".join(new) + "\n")
    return jsonify({"status": "enabled" if changed else "already_enabled"})


@app.route("/api/cron/disable", methods=["POST"])
@require_token
def api_cron_disable():
    lines = _read_crontab().splitlines()
    new, changed = [], False
    for line in lines:
        if "sync.sh" in line and not line.strip().startswith("#"):
            new.append(f"# DISABLED: {line}")
            changed = True
        else:
            new.append(line)
    if changed:
        _write_crontab("\n".join(new) + "\n")
    return jsonify({"status": "disabled" if changed else "already_disabled"})


_launch_lock = threading.Lock()


def _start_sync():
    if not os.path.exists(SYNC_SH):
        return jsonify({"error": "sync.sh not found"}), 500
    body = request.get_json(silent=True) or {}
    mode = body.get("mode") or request.args.get("mode") or ""
    if mode not in ("", "incremental", "full"):
        return jsonify({"error": "mode must be 'incremental' or 'full'"}), 400
    with _launch_lock:
        if _current_run():
            return jsonify({"error": "A sync is already running"}), 409
        os.makedirs(LOG_DIR, exist_ok=True)
        cmd = ["bash", SYNC_SH] + ([f"--{mode}"] if mode else [])
        with open(f"{LOG_DIR}/launcher.log", "a") as lf:
            lf.write(f"\n[{datetime.datetime.now():%Y-%m-%d %H:%M:%S}] dashboard → {' '.join(cmd)}\n")
            lf.flush()
            proc = subprocess.Popen(cmd, stdout=lf, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                                    start_new_session=True, cwd=str(SCRIPT_DIR),
                                    env={**os.environ, "SYNC_TRIGGER": "dashboard"})
        # Reap the child when it exits so it never lingers as a zombie
        threading.Thread(target=proc.wait, daemon=True).start()
        time.sleep(0.5)
    return jsonify({"status": "running", "mode": mode or os.environ.get("SYNC_MODE", "incremental"),
                    "pid": proc.pid})


@app.route("/api/cron/run", methods=["POST"])
@require_token
def api_cron_run():
    """Run the sync job immediately. JSON body: {"mode": "incremental"|"full"} (optional)"""
    return _start_sync()


@app.route("/api/sync/trigger", methods=["POST"])
@require_token
def api_sync_trigger():
    return _start_sync()


@app.route("/api/sync/stop", methods=["POST"])
@require_token
def api_sync_stop():
    cur = _current_run()
    if not cur:
        return jsonify({"status": "not_running"})
    pid, pgid = int(cur["pid"]), int(cur.get("pgid") or 0)
    try:
        if pgid and pgid != os.getpgid(0):
            os.killpg(pgid, signal.SIGTERM)
        else:
            os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        return jsonify({"status": "not_running"})
    except PermissionError:
        return jsonify({"error": "Permission denied stopping the sync process"}), 403
    return jsonify({"status": "stopping", "pid": pid})


@app.route("/api/logs")
@require_token
def api_logs():
    files = _system_log_files() + _log_files()[:30]
    out = []
    for f in files:
        try:
            st = os.stat(f)
        except OSError:
            continue
        out.append({"name": os.path.basename(f), "size_kb": round(st.st_size / 1024, 1),
                    "modified": _fmt_ts(st.st_mtime),
                    "system": not os.path.basename(f).startswith(("sync_", "manual_sync_"))})
    return jsonify(out)


@app.route("/api/logs/<path:filename>")
@require_token
def api_log_content(filename):
    safe     = os.path.basename(filename)
    log_path = os.path.join(LOG_DIR, safe)
    if not safe.endswith(".log") or not os.path.isfile(log_path):
        return jsonify({"error": "Not found"}), 404
    n = min(max(int(request.args.get("tail", 800)), 10), 5000)
    lines, complete = _tail_lines(log_path, n)
    return jsonify({"name": safe, "lines": lines, "truncated": not complete})


# ── Dashboard HTML ────────────────────────────────────────────────────────────
DASHBOARD_HTML = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>ERP Sync Dashboard &mdash; Krea Onererp</title>
<link rel="icon" type="image/x-icon" href="https://cdn.krea.edu.in/favicon.ico">
<style>
:root {
  --bg:         #0d1117;
  --surface:    #161b22;
  --surface-2:  #21262d;
  --border:     #30363d;
  --border-dim: #21262d;
  --text:       #c9d1d9;
  --text-muted: #8b949e;
  --text-dim:   #6e7681;
  --blue:       #58a6ff;
  --blue-bg:    rgba(31,111,235,.13);
  --green:      #3fb950;
  --green-bg:   rgba(63,185,80,.13);
  --red:        #f85149;
  --red-bg:     rgba(248,81,73,.13);
  --yellow:     #e3b341;
  --yellow-bg:  rgba(227,179,65,.13);
  --purple:     #d2a8ff;
  --purple-bg:  rgba(210,168,255,.13);
  --orange:     #ffa657;
  --orange-bg:  rgba(255,166,87,.13);
  --r-sm: 6px; --r: 10px; --r-lg: 14px;
}
*, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
html { font-size: 16px; }
body {
  background: var(--bg); color: var(--text);
  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif;
  min-height: 100vh; display: flex; flex-direction: column; line-height: 1.5;
}
::-webkit-scrollbar { width: 7px; height: 7px; }
::-webkit-scrollbar-track { background: var(--bg); }
::-webkit-scrollbar-thumb { background: var(--border); border-radius: 4px; }
.mono { font-family: 'SFMono-Regular', Consolas, 'Liberation Mono', monospace; }
.num  { font-variant-numeric: tabular-nums; }

/* ── Navbar ── */
.navbar {
  position: sticky; top: 0; z-index: 100;
  background: rgba(13,17,23,.96); backdrop-filter: blur(14px);
  border-bottom: 1px solid var(--border);
  height: 62px; padding: 0 2rem;
  display: flex; align-items: center; justify-content: space-between; gap: 1rem;
}
.brand { display: flex; align-items: center; gap: .75rem; flex-shrink: 0; }
.brand-icon {
  width: 38px; height: 38px; background: linear-gradient(135deg, #1f6feb 0%, #388bfd 100%);
  border-radius: 10px; display: flex; align-items: center; justify-content: center;
  font-size: 1.15rem; flex-shrink: 0;
  box-shadow: 0 0 0 1px rgba(88,166,255,.2), 0 4px 12px rgba(31,111,235,.3);
}
.brand-name { font-size: .95rem; font-weight: 700; color: #e6edf3; line-height: 1.2; }
.brand-sub  { font-size: .7rem;  color: var(--text-muted); line-height: 1.2; }
.env-pill {
  padding: .18rem .6rem; background: var(--green-bg); color: var(--green);
  border: 1px solid rgba(63,185,80,.3); border-radius: 99px;
  font-size: .62rem; font-weight: 800; letter-spacing: .1em;
}
.nav-right { display: flex; align-items: center; gap: 1rem; }
.conn-status { display: flex; align-items: center; gap: .4rem; font-size: .78rem; color: var(--text-muted); }
.conn-dot { width: 7px; height: 7px; border-radius: 50%; background: var(--text-dim); transition: background .3s; }
.conn-dot.on  { background: var(--green); animation: blink 2.2s ease-in-out infinite; }
.conn-dot.bad { background: var(--red); }
@keyframes blink { 0%,100%{opacity:1} 50%{opacity:.45} }
.token-row { display: flex; gap: .45rem; align-items: center; }
.token-row input {
  width: 185px; background: var(--surface-2); border: 1px solid var(--border);
  border-radius: var(--r-sm); color: var(--text); padding: .42rem .8rem; font-size: .82rem; outline: none;
  transition: border-color .15s, box-shadow .15s;
}
.token-row input:focus { border-color: var(--blue); box-shadow: 0 0 0 3px rgba(88,166,255,.15); }
.token-row input::placeholder { color: var(--text-dim); }

/* ── Buttons ── */
.btn {
  display: inline-flex; align-items: center; gap: .4rem; padding: .5rem 1.05rem;
  border-radius: var(--r-sm); border: 1px solid transparent; cursor: pointer;
  font-size: .82rem; font-weight: 600; line-height: 1; white-space: nowrap; text-decoration: none;
  transition: opacity .15s, transform .12s, box-shadow .15s;
}
.btn:hover:not(:disabled) { opacity: .85; transform: translateY(-1px); box-shadow: 0 4px 14px rgba(0,0,0,.3); }
.btn:active:not(:disabled) { transform: translateY(0); box-shadow: none; }
.btn:disabled { opacity: .35; cursor: not-allowed; }
.btn-xs { padding: .28rem .6rem; font-size: .74rem; }
.btn-sm { padding: .4rem .85rem; font-size: .8rem; }
.btn-primary { background: #1a7f37; border-color: #238636; color: #fff; }
.btn-danger  { background: var(--red-bg); border-color: rgba(248,81,73,.35); color: var(--red); }
.btn-blue    { background: #1f6feb; border-color: #388bfd; color: #fff; }
.btn-purple  { background: var(--purple-bg); border-color: rgba(210,168,255,.35); color: var(--purple); }
.btn-outline { background: var(--surface-2); border-color: var(--border); color: var(--text); }

/* ── Main ── */
.main { flex: 1; padding: 1.75rem 2rem; max-width: 1360px; width: 100%; margin: 0 auto; }

/* ── Running banner ── */
.run-banner {
  display: none; margin-bottom: 1.25rem;
  background: linear-gradient(90deg, rgba(31,111,235,.14), rgba(31,111,235,.04));
  border: 1px solid rgba(88,166,255,.35); border-radius: var(--r); padding: 1rem 1.3rem;
}
.run-banner.show { display: block; }
.run-top { display: flex; align-items: center; justify-content: space-between; gap: 1rem; flex-wrap: wrap; }
.run-title { display: flex; align-items: center; gap: .6rem; font-weight: 700; color: #e6edf3; font-size: .92rem; }
.run-meta { font-size: .76rem; color: var(--text-muted); display: flex; gap: 1.1rem; flex-wrap: wrap; margin-top: .55rem; }
.run-meta b { color: var(--text); font-weight: 600; }
.pbar { height: 8px; background: var(--surface-2); border-radius: 99px; overflow: hidden; margin-top: .75rem; }
.pbar-fill { height: 100%; width: 0; background: linear-gradient(90deg, #1f6feb, #58a6ff); border-radius: 99px; transition: width .6s ease; }
.pbar-fill.indet { width: 30%; animation: indet 1.4s ease-in-out infinite; }
@keyframes indet { 0%{margin-left:-30%} 100%{margin-left:100%} }

/* ── Metric Cards ── */
.metrics-grid { display: grid; grid-template-columns: repeat(4, 1fr); gap: 1rem; margin-bottom: 1.25rem; }
.metric-card {
  background: var(--surface); border: 1px solid var(--border); border-radius: var(--r);
  padding: 1.1rem 1.25rem; display: flex; flex-direction: column; gap: .6rem;
  position: relative; overflow: hidden; transition: border-color .2s, transform .2s, box-shadow .2s;
}
.metric-card:hover { transform: translateY(-2px); box-shadow: 0 8px 24px rgba(0,0,0,.25); }
.metric-card::after { content: ''; position: absolute; top: 0; left: 0; right: 0; height: 2px; }
.c-blue::after   { background: var(--blue); }
.c-green::after  { background: var(--green); }
.c-purple::after { background: var(--purple); }
.c-orange::after { background: var(--orange); }
.c-yellow::after { background: var(--yellow); }
.c-red::after    { background: var(--red); }
.metric-top { display: flex; align-items: center; justify-content: space-between; }
.metric-label { font-size: .7rem; font-weight: 700; text-transform: uppercase; letter-spacing: .07em; color: var(--text-muted); }
.metric-icon  { font-size: 1.05rem; }
.metric-value { font-size: 1.35rem; font-weight: 700; color: #e6edf3; min-height: 1.8rem; display: flex; align-items: center; gap: .5rem; flex-wrap: wrap; }
.metric-value.sm { font-size: 1rem; }
.metric-detail { font-size: .72rem; color: var(--text-muted); }
.locked { color: var(--text-dim); font-size: .8rem; font-weight: 500; }
.mini-bar { height: 5px; background: var(--surface-2); border-radius: 99px; overflow: hidden; }
.mini-bar > span { display: block; height: 100%; border-radius: 99px; background: var(--green); }

/* ── Badges ── */
.sbadge {
  display: inline-flex; align-items: center; gap: .38rem; padding: .22rem .6rem; border-radius: var(--r-sm);
  font-size: .72rem; font-weight: 700; letter-spacing: .03em; white-space: nowrap;
}
.sbadge-dot { width: 6px; height: 6px; border-radius: 50%; background: currentColor; flex-shrink: 0; }
.sbadge-green  { background: var(--green-bg);  color: var(--green);  border: 1px solid rgba(63,185,80,.28); }
.sbadge-green .sbadge-dot { animation: pulseG 1.8s ease-in-out infinite; }
@keyframes pulseG { 0%,100%{box-shadow:0 0 0 0 rgba(63,185,80,.5)} 60%{box-shadow:0 0 0 4px rgba(63,185,80,0)} }
.sbadge-gray   { background: rgba(139,148,158,.1); color: var(--text-muted); border: 1px solid rgba(139,148,158,.2); }
.sbadge-red    { background: var(--red-bg);    color: var(--red);    border: 1px solid rgba(248,81,73,.3); }
.sbadge-yellow { background: var(--yellow-bg); color: var(--yellow); border: 1px solid rgba(227,179,65,.3); }
.sbadge-blue   { background: var(--blue-bg);   color: var(--blue);   border: 1px solid rgba(88,166,255,.3); }
.sbadge-purple { background: var(--purple-bg); color: var(--purple); border: 1px solid rgba(210,168,255,.3); }
.tag { font-size: .66rem; padding: .1rem .45rem; border-radius: 4px; background: var(--surface-2); color: var(--text-muted); border: 1px solid var(--border); font-weight: 600; text-transform: uppercase; letter-spacing: .04em; }

/* ── Panels ── */
.control-panel, .panel {
  background: var(--surface); border: 1px solid var(--border); border-radius: var(--r); margin-bottom: 1.25rem;
}
.control-panel { padding: 1.1rem 1.5rem; display: flex; align-items: center; justify-content: space-between; flex-wrap: wrap; gap: .9rem; }
.panel { overflow: hidden; }
.panel-head {
  display: flex; align-items: center; justify-content: space-between; gap: .75rem;
  padding: .8rem 1.25rem; background: var(--surface-2); border-bottom: 1px solid var(--border);
}
.panel-title { font-size: .88rem; font-weight: 700; color: #e6edf3; display: flex; align-items: center; gap: .5rem; }
.panel-sub   { font-size: .74rem; color: var(--text-muted); }
.action-row  { display: flex; align-items: center; gap: .55rem; flex-wrap: wrap; }
.countdown   { font-size: .73rem; color: var(--text-dim); padding-left: .25rem; }
.two-col { display: grid; grid-template-columns: 3fr 2fr; gap: 1.25rem; }
.two-col > .panel { margin-bottom: 1.25rem; min-width: 0; }
.panel-empty { padding: 1.6rem 1rem; text-align: center; color: var(--text-dim); font-size: .8rem; }

/* ── Tables ── */
.tbl-wrap { overflow-x: auto; max-height: 420px; overflow-y: auto; }
table.tbl { width: 100%; border-collapse: collapse; font-size: .78rem; }
.tbl th {
  position: sticky; top: 0; background: var(--surface); z-index: 1;
  text-align: left; font-size: .67rem; text-transform: uppercase; letter-spacing: .06em;
  color: var(--text-muted); font-weight: 700; padding: .55rem .8rem; border-bottom: 1px solid var(--border); white-space: nowrap;
}
.tbl td { padding: .5rem .8rem; border-bottom: 1px solid var(--border-dim); white-space: nowrap; vertical-align: middle; }
.tbl tr:hover td { background: rgba(255,255,255,.02); }
.tbl .r { text-align: right; }
.tbl .muted { color: var(--text-muted); }
.tbl a { color: var(--blue); text-decoration: none; cursor: pointer; }
.tbl a:hover { text-decoration: underline; }
.dur { display: flex; align-items: center; gap: .5rem; }
.dur-bar { height: 6px; border-radius: 99px; background: var(--blue); opacity: .7; min-width: 2px; }
.dur-bar.full { background: var(--purple); }

/* ── Key/value grid ── */
.kv { display: grid; grid-template-columns: repeat(auto-fill, minmax(210px, 1fr)); gap: 0; }
.kv > div { padding: .65rem 1.1rem; border-bottom: 1px solid var(--border-dim); border-right: 1px solid var(--border-dim); }
.kv dt { font-size: .66rem; text-transform: uppercase; letter-spacing: .06em; color: var(--text-muted); font-weight: 700; }
.kv dd { font-size: .82rem; color: var(--text); margin-top: .15rem; word-break: break-all; }

/* ── Log Section ── */
.log-layout { display: flex; min-height: 440px; }
.log-sidebar { width: 265px; flex-shrink: 0; border-right: 1px solid var(--border); overflow-y: auto; max-height: 580px; }
.log-empty { padding: 2rem 1rem; text-align: center; color: var(--text-dim); font-size: .8rem; line-height: 1.6; }
.log-group { padding: .45rem 1rem; font-size: .64rem; text-transform: uppercase; letter-spacing: .08em; color: var(--text-dim); font-weight: 700; background: var(--bg); border-bottom: 1px solid var(--border-dim); }
.log-file-item {
  padding: .6rem 1rem; cursor: pointer; border-bottom: 1px solid var(--border-dim);
  border-left: 2px solid transparent; transition: background .1s, border-color .1s;
}
.log-file-item:hover  { background: var(--surface-2); }
.log-file-item.active { background: var(--blue-bg); border-left-color: var(--blue); }
.log-file-name { font-family: 'SFMono-Regular', Consolas, monospace; font-size: .72rem; color: var(--blue); line-height: 1.4; margin-bottom: .18rem; word-break: break-all; }
.log-file-meta { font-size: .67rem; color: var(--text-dim); }
.log-content { flex: 1; overflow: hidden; display: flex; flex-direction: column; min-width: 0; }
.log-ph { flex: 1; display: flex; flex-direction: column; align-items: center; justify-content: center; color: var(--text-dim); gap: .8rem; padding: 2rem; }
.log-ph-icon { font-size: 2.8rem; opacity: .3; }
.log-ph p    { font-size: .82rem; }
.log-viewer  { flex: 1; display: flex; flex-direction: column; overflow: hidden; }
.log-toolbar {
  display: flex; align-items: center; justify-content: space-between; gap: .5rem;
  padding: .5rem 1rem; background: var(--surface-2); border-bottom: 1px solid var(--border);
  font-size: .76rem; color: var(--text-muted); font-family: monospace;
}
.log-toolbar input {
  background: var(--bg); border: 1px solid var(--border); border-radius: var(--r-sm);
  color: var(--text); padding: .25rem .55rem; font-size: .74rem; width: 150px; outline: none;
}
.log-body {
  flex: 1; overflow-y: auto; background: #010409; max-height: 500px;
  font-family: 'SFMono-Regular', Consolas, 'Liberation Mono', monospace; font-size: .74rem; line-height: 1.65;
}
.log-line        { display: flex; min-height: 1.3em; padding: 0 .4rem; }
.log-line:hover  { background: rgba(255,255,255,.025); }
.ln { min-width: 3.4em; text-align: right; padding-right: .7rem; color: var(--text-dim); user-select: none; border-right: 1px solid #1c2128; margin-right: .7rem; flex-shrink: 0; padding-top: .06em; }
.lt { flex: 1; white-space: pre-wrap; word-break: break-all; color: var(--text); padding-top: .06em; }
.ll-err  .lt { color: var(--red); }
.ll-warn .lt { color: var(--yellow); }
.ll-ok   .lt { color: var(--green); }
.ll-head { background: rgba(31,111,235,.06); }
.ll-head .lt { color: var(--blue); font-weight: 600; }
.ll-dim  .lt { color: var(--text-dim); }

/* ── Footer ── */
.footer { border-top: 1px solid var(--border); background: var(--surface); font-size: .8rem; color: var(--text-muted); }
.footer-top { background: rgba(248,81,73,.06); border-bottom: 1px solid rgba(248,81,73,.15); padding: .55rem 2rem; text-align: center; }
.footer-notice { font-size: .72rem; color: rgba(248,81,73,.8); letter-spacing: .02em; }
.footer-bottom { padding: .9rem 2rem; display: flex; align-items: center; justify-content: center; gap: 1.25rem; flex-wrap: wrap; }
.footer .heart { color: var(--red); }
.footer strong { color: var(--text); font-weight: 600; }
.footer-sep { color: var(--text-dim); }
.footer-version { color: var(--text-dim); font-size: .72rem; }

/* ── Toast ── */
.toast-container { position: fixed; bottom: 1.5rem; right: 1.5rem; display: flex; flex-direction: column; gap: .45rem; z-index: 9999; }
.toast {
  background: var(--surface); border: 1px solid var(--border); border-radius: var(--r-sm);
  padding: .72rem 1.1rem; font-size: .82rem; max-width: 330px; display: flex; align-items: flex-start; gap: .5rem;
  box-shadow: 0 8px 28px rgba(0,0,0,.45); animation: tin .22s ease;
}
.toast.tg { border-color: rgba(63,185,80,.4); }
.toast.tr { border-color: rgba(248,81,73,.4); }
.toast.tb { border-color: rgba(88,166,255,.4); }
.t-ico { font-size: .88rem; flex-shrink: 0; margin-top: .05rem; }
.t-msg { color: var(--text); line-height: 1.4; }
@keyframes tin { from{transform:translateX(16px);opacity:0} to{transform:translateX(0);opacity:1} }

/* ── Spinner ── */
.spin {
  display: inline-block; width: 12px; height: 12px; border: 2px solid rgba(255,255,255,.18); border-top-color: #fff;
  border-radius: 50%; animation: rot .6s linear infinite; vertical-align: middle;
}
.spin.blue { border-color: rgba(88,166,255,.2); border-top-color: var(--blue); }
@keyframes rot { to{transform:rotate(360deg)} }

/* ── Responsive ── */
@media (max-width: 1100px) { .two-col { grid-template-columns: 1fr; } }
@media (max-width: 960px)  { .metrics-grid { grid-template-columns: repeat(2,1fr); } }
@media (max-width: 520px)  { .metrics-grid { grid-template-columns: 1fr; } }
@media (max-width: 700px) {
  .navbar { padding: 0 1rem; }
  .main   { padding: 1rem; }
  .brand-sub, .env-pill { display: none; }
  .conn-status { display: none; }
  .token-row input { width: 130px; }
  .log-layout { flex-direction: column; }
  .log-sidebar { width: 100%; max-height: 190px; border-right: none; border-bottom: 1px solid var(--border); }
}
</style>
</head>
<body>

<!-- Navbar -->
<nav class="navbar">
  <div class="brand">
    <div class="brand-icon">&#9881;</div>
    <div>
      <div class="brand-name">ERP Local DB Sync</div>
      <div class="brand-sub">Krea Onererp &mdash; Database Replication</div>
    </div>
    <span class="env-pill">LIVE</span>
  </div>
  <div class="nav-right">
    <div class="conn-status">
      <span class="conn-dot" id="connDot"></span>
      <span id="connLabel">Not connected</span>
    </div>
    <div class="token-row">
      <input type="password" id="tokenInput" placeholder="API Token&hellip;" autocomplete="off">
      <button class="btn btn-primary btn-sm" onclick="saveToken()">Connect</button>
    </div>
  </div>
</nav>

<main class="main">

  <!-- Running banner -->
  <div class="run-banner" id="runBanner">
    <div class="run-top">
      <div class="run-title"><span class="spin blue"></span><span id="runTitle">Sync running</span></div>
      <div class="action-row">
        <button class="btn btn-xs btn-outline" id="btnRunLog">&#128196; Live log</button>
        <button class="btn btn-xs btn-danger" id="btnStop" onclick="stopSync()">&#9632; Stop</button>
      </div>
    </div>
    <div class="pbar"><div class="pbar-fill" id="runBar"></div></div>
    <div class="run-meta" id="runMeta"></div>
  </div>

  <!-- Metric Cards: row 1 (sync) -->
  <div class="metrics-grid">
    <div class="metric-card c-blue">
      <div class="metric-top"><span class="metric-label">Cron Job</span><span class="metric-icon">&#128260;</span></div>
      <div class="metric-value" id="cronStatus">&mdash;</div>
      <div class="metric-detail mono" id="cronExpr">Schedule not loaded</div>
    </div>
    <div class="metric-card c-purple">
      <div class="metric-top"><span class="metric-label">Last Sync</span><span class="metric-icon">&#9200;</span></div>
      <div class="metric-value sm" id="lastSync">&mdash;</div>
      <div class="metric-detail" id="lastSyncDetail">Timezone &mdash; IST &bull; UTC+5:30</div>
    </div>
    <div class="metric-card c-yellow">
      <div class="metric-top"><span class="metric-label">Next Run</span><span class="metric-icon">&#9203;</span></div>
      <div class="metric-value sm" id="nextRun">&mdash;</div>
      <div class="metric-detail" id="nextRunDetail">&mdash;</div>
    </div>
    <div class="metric-card c-orange">
      <div class="metric-top"><span class="metric-label">Avg Duration</span><span class="metric-icon">&#9889;</span></div>
      <div class="metric-value" id="avgDur"><span class="locked">&#128274; Connect</span></div>
      <div class="metric-detail" id="avgDurDetail">Incremental &bull; last 10 runs</div>
    </div>
  </div>

  <!-- Metric Cards: row 2 (infrastructure) -->
  <div class="metrics-grid">
    <div class="metric-card c-green">
      <div class="metric-top"><span class="metric-label">Local MySQL</span><span class="metric-icon">&#128024;</span></div>
      <div class="metric-value" id="mysqlStatus"><span class="locked">&#128274; Connect</span></div>
      <div class="metric-detail" id="mysqlDetail">&mdash;</div>
    </div>
    <div class="metric-card c-blue">
      <div class="metric-top"><span class="metric-label">Mirror Size</span><span class="metric-icon">&#128451;</span></div>
      <div class="metric-value" id="mirrorSize"><span class="locked">&#128274; Connect</span></div>
      <div class="metric-detail" id="mirrorDetail">&mdash;</div>
    </div>
    <div class="metric-card c-purple">
      <div class="metric-top"><span class="metric-label">Disk</span><span class="metric-icon">&#128190;</span></div>
      <div class="metric-value" id="diskFree"><span class="locked">&#128274; Connect</span></div>
      <div class="mini-bar"><span id="diskBar" style="width:0"></span></div>
      <div class="metric-detail" id="diskDetail">&mdash;</div>
    </div>
    <div class="metric-card c-orange">
      <div class="metric-top"><span class="metric-label">Backups &amp; Logs</span><span class="metric-icon">&#128203;</span></div>
      <div class="metric-value" id="backupCount">&mdash;</div>
      <div class="metric-detail" id="backupSize">&mdash;</div>
    </div>
  </div>

  <!-- Controls -->
  <div class="control-panel">
    <span class="panel-title">&#9881; Quick Actions</span>
    <div class="action-row">
      <button class="btn btn-primary" id="btnEnable"  onclick="cronAction('enable')" disabled>&#10003; Enable Cron</button>
      <button class="btn btn-danger"  id="btnDisable" onclick="cronAction('disable')" disabled>&#10007; Disable Cron</button>
      <button class="btn btn-blue"    id="btnRunInc"  onclick="runJob('incremental')" disabled title="Copy only tables that changed">&#9654; Incremental Sync</button>
      <button class="btn btn-purple"  id="btnRunFull" onclick="runJob('full')" disabled title="Re-copy every table">&#10227; Full Sync</button>
      <button class="btn btn-outline" onclick="refresh()">&#8635; Refresh</button>
      <span class="countdown" id="countdown"></span>
    </div>
  </div>

  <!-- History + Databases -->
  <div class="two-col">
    <div class="panel">
      <div class="panel-head">
        <span class="panel-title">&#128202; Sync History</span>
        <span class="panel-sub" id="histMeta"></span>
      </div>
      <div class="tbl-wrap" id="histWrap"><div class="panel-empty">Connect with your API token to view history</div></div>
    </div>
    <div class="panel">
      <div class="panel-head">
        <span class="panel-title">&#128450; Databases</span>
        <span class="panel-sub" id="dbMeta"></span>
      </div>
      <div class="tbl-wrap" id="dbWrap"><div class="panel-empty">Connect with your API token to view databases</div></div>
    </div>
  </div>

  <!-- Slowest tables + System -->
  <div class="two-col">
    <div class="panel">
      <div class="panel-head">
        <span class="panel-title">&#128034; Slowest Tables &mdash; Last Run</span>
        <span class="panel-sub" id="slowMeta"></span>
      </div>
      <div class="tbl-wrap" id="slowWrap"><div class="panel-empty">No data yet</div></div>
    </div>
    <div class="panel">
      <div class="panel-head"><span class="panel-title">&#128421; System &amp; Configuration</span></div>
      <div id="sysWrap"><div class="panel-empty">Connect with your API token to view system info</div></div>
    </div>
  </div>

  <!-- Log Reports -->
  <div class="panel">
    <div class="panel-head">
      <span class="panel-title">&#128203; Log Reports</span>
      <span class="panel-sub" id="logMeta"></span>
    </div>
    <div class="log-layout">
      <div class="log-sidebar" id="logSidebar">
        <div class="log-empty">Connect with your API token<br>to browse log files</div>
      </div>
      <div class="log-content">
        <div class="log-ph" id="logPh">
          <div class="log-ph-icon">&#128196;</div>
          <p>Select a log file from the left panel</p>
        </div>
        <div class="log-viewer" id="logViewer" style="display:none">
          <div class="log-toolbar">
            <span id="logViewerTitle" style="font-size:.75rem"></span>
            <div class="action-row">
              <input id="logFilter" placeholder="Filter lines&hellip;" oninput="renderLog()">
              <label style="font-size:.72rem;display:flex;align-items:center;gap:.3rem"><input type="checkbox" id="logFollow" checked style="width:auto"> Follow</label>
              <button class="btn btn-xs btn-outline" onclick="scrollBottom()">&#8595; Bottom</button>
            </div>
          </div>
          <div class="log-body" id="logBody"><div id="logLines"></div></div>
        </div>
      </div>
    </div>
  </div>

</main>

<!-- Footer -->
<footer class="footer">
  <div class="footer-top">
    <span class="footer-notice">&#128274; Authorized Access Only &mdash; This system is restricted to authorized users of the Krea System. Unauthorized access is prohibited.</span>
  </div>
  <div class="footer-bottom">
    <span>Made with <span class="heart">&#10084;&#65039;</span> by <strong>Krea IT Team</strong></span>
    <span class="footer-sep">&bull;</span>
    <span class="footer-version">ERP Local DB Sync &mdash; Krea Onererp</span>
    <span class="footer-sep">&bull;</span>
    <span class="footer-version">&copy; <span id="fyear"></span> Krea IT. All rights reserved.</span>
  </div>
</footer>
<script>document.getElementById('fyear').textContent = new Date().getFullYear();</script>

<div class="toast-container" id="toastWrap"></div>

<script>
// ─── State ────────────────────────────────────────────────────────────────────
let token      = sessionStorage.getItem('erp_token') || '';
let authed     = false;
let running    = null;
let cdVal      = 30;
let cdTimer    = null;
let curLog     = null;
let curLogData = [];
const $ = id => document.getElementById(id);

// ─── Boot ─────────────────────────────────────────────────────────────────────
$('tokenInput').addEventListener('keydown', e => { if (e.key === 'Enter') saveToken(); });
if (token) $('tokenInput').value = token;
refresh();
startCd();

function saveToken() {
  token = $('tokenInput').value.trim();
  sessionStorage.setItem('erp_token', token);
  refresh();
}
function setConn(state) {
  $('connDot').className = 'conn-dot' + (state === true ? ' on' : state === 'bad' ? ' bad' : '');
  $('connLabel').textContent = state === true ? 'Connected' : state === 'bad' ? 'Invalid token' : 'Not connected';
}
function hdrs() { return { 'X-API-Token': token, 'Content-Type': 'application/json' }; }
async function refresh() {
  await loadStatus();
  if (token) { await loadOverview(); if (authed) await loadLogs(); }
  else { authed = false; setConn(false); }
  updateButtonState();
  cdVal = running ? 5 : 30;
}

// ─── Public status ────────────────────────────────────────────────────────────
async function loadStatus() {
  try {
    const d = await fetch('/api/status').then(r => r.json());
    $('cronStatus').innerHTML = d.cron_enabled
      ? badge('ENABLED', 'green', true) : badge('DISABLED', 'gray', true);
    $('cronExpr').textContent = d.cron_expr ? d.cron_expr.split(/\s+/).slice(0,5).join(' ') : 'No schedule registered';
    $('cronExpr').title = d.cron_expr || '';
    $('lastSync').innerHTML = d.last_sync
      ? `${x(d.last_sync)} ${d.last_status ? statusBadge(d.last_status) : ''}` : 'Never synced';
    if (d.next_run) { $('nextRun').textContent = d.next_run; $('nextRunDetail').textContent = 'in ' + rel(d.next_run); }
    else { $('nextRun').textContent = d.cron_enabled ? 'Unknown' : 'Cron disabled'; $('nextRunDetail').textContent = '—'; }
    $('backupCount').textContent = d.backup_count + ' backup' + (d.backup_count !== 1 ? 's' : '');
    $('backupSize').textContent  = d.backup_size_gb + ' GB on disk · ' + d.log_count + ' sync log' + (d.log_count !== 1 ? 's' : '');
    if (!d.running && running) { running = null; renderRunning(null); if (authed) loadLogs(); }
  } catch(e) { console.error('Status error:', e); }
}

// ─── Authenticated overview ───────────────────────────────────────────────────
async function loadOverview() {
  let r;
  try { r = await fetch('/api/overview', { headers: hdrs() }); } catch(e) { return; }
  if (r.status === 401) { authed = false; setConn('bad'); return; }
  if (!r.ok) return;
  authed = true; setConn(true);
  const d = await r.json();
  running = d.running;
  renderRunning(d.running);
  renderCards(d);
  renderHistory(d.history || []);
  renderDatabases(d.databases || {});
  renderSlow(d.last_tables || {});
  renderSystem(d);
}

function renderRunning(r) {
  $('runBanner').classList.toggle('show', !!r);
  if (!r) return;
  const pct = r.total ? Math.round(r.done * 100 / r.total) : 0;
  const bar = $('runBar');
  if (r.phase === 'copying' && r.total) { bar.classList.remove('indet'); bar.style.width = pct + '%'; }
  else { bar.classList.add('indet'); bar.style.width = ''; }
  $('runTitle').innerHTML = `${r.mode === 'full' ? 'Full' : 'Incremental'} sync running &mdash; <span style="color:var(--blue)">${x(r.phase)}</span>`;
  $('runMeta').innerHTML = [
    `Progress <b class="num">${r.done} / ${r.total} tables (${pct}%)</b>`,
    r.failed ? `<span style="color:var(--red)">Failed <b>${r.failed}</b></span>` : '',
    `Elapsed <b class="num">${dur(r.elapsed_s)}</b>`,
    r.eta_s != null ? `ETA <b class="num">~${dur(r.eta_s)}</b>` : '',
    `Started <b>${x(r.started)}</b>`,
    `Trigger <b>${x(r.trigger)}</b>`,
  ].filter(Boolean).join('');
  $('btnRunLog').onclick = () => openLog(r.log);
}

function renderCards(d) {
  const a = d.averages || {};
  $('avgDur').textContent = a.incremental_s != null ? dur(a.incremental_s) : '—';
  $('avgDurDetail').textContent = 'Incremental (last 10)' + (a.full_s != null ? ' · full ' + dur(a.full_s) : '') +
    (d.last_full ? ' · last full ' + d.last_full : '');

  const h = (d.history || [])[0];
  if (h) $('lastSyncDetail').textContent = `${h.mode} · ${dur(h.duration_s)} · ${h.tables_synced} copied, ${h.tables_skipped} unchanged` + (h.tables_failed ? `, ${h.tables_failed} failed` : '');

  const m = d.mysql || {};
  const st = m.status === 'running' ? (m.health && m.health !== 'healthy' ? badge(m.health.toUpperCase(), 'yellow') : badge('RUNNING', 'green', true))
           : badge((m.status || 'unknown').toUpperCase(), 'red');
  $('mysqlStatus').innerHTML = st;
  $('mysqlDetail').textContent = [m.image, m.started_epoch && m.status === 'running' ? 'up ' + dur(Date.now()/1000 - m.started_epoch) : '',
    m.restarts ? m.restarts + ' restart(s)' : ''].filter(Boolean).join(' · ') || '—';

  const dbs = (d.databases || {}).databases || [];
  const local = dbs.reduce((s, b) => s + b.local_bytes, 0), remote = dbs.reduce((s, b) => s + b.remote_bytes, 0);
  const tables = dbs.reduce((s, b) => s + b.tables, 0);
  $('mirrorSize').textContent = dbs.length ? bytes(local) : '—';
  $('mirrorDetail').textContent = dbs.length ? `${dbs.length} DBs · ${tables.toLocaleString()} tables · prod ${bytes(remote)}` : 'Available after the first sync';

  const dk = (d.disk || {}).docker || (d.disk || {}).backups;
  if (dk) {
    $('diskFree').textContent = bytes(dk.free) + ' free';
    $('diskBar').style.width = dk.pct + '%';
    $('diskBar').style.background = dk.pct > 90 ? 'var(--red)' : dk.pct > 75 ? 'var(--yellow)' : 'var(--green)';
    $('diskDetail').textContent = `${dk.pct}% used of ${bytes(dk.total)} · ${dk.path}`;
  }
}

function renderHistory(hist) {
  $('histMeta').textContent = hist.length ? `last ${hist.length} runs` : '';
  if (!hist.length) { $('histWrap').innerHTML = '<div class="panel-empty">No runs recorded yet</div>'; return; }
  const max = Math.max(...hist.map(h => h.duration_s || 0), 1);
  $('histWrap').innerHTML = `<table class="tbl"><thead><tr>
      <th>Started</th><th>Mode</th><th>Status</th><th>Duration</th><th class="r">Copied</th><th class="r">Unchanged</th><th class="r">Failed</th><th class="r">Data</th><th>Log</th>
    </tr></thead><tbody>${hist.map(h => `<tr>
      <td class="num">${x(h.started)}<div class="muted" style="font-size:.68rem">${x(h.trigger || '')}</div></td>
      <td><span class="tag">${x(h.mode)}</span></td>
      <td>${statusBadge(h.status)}</td>
      <td><div class="dur"><span class="num" style="min-width:58px">${dur(h.duration_s)}</span><span class="dur-bar ${h.mode==='full'?'full':''}" style="width:${Math.round(70 * h.duration_s / max)}px"></span></div></td>
      <td class="r num">${n(h.tables_synced)}</td>
      <td class="r num muted">${n(h.tables_skipped)}</td>
      <td class="r num" style="${h.tables_failed ? 'color:var(--red);font-weight:700' : ''}">${n(h.tables_failed)}</td>
      <td class="r num muted">${bytes(h.dump_bytes)}</td>
      <td><a onclick="openLog('${x(h.log)}')">view</a></td>
    </tr>`).join('')}</tbody></table>`;
}

function renderDatabases(s) {
  const dbs = (s.databases || []).slice().sort((a, b) => b.remote_bytes - a.remote_bytes);
  $('dbMeta').textContent = s.generated ? 'as of ' + s.generated : '';
  if (!dbs.length) { $('dbWrap').innerHTML = '<div class="panel-empty">Available after the first sync</div>'; return; }
  $('dbWrap').innerHTML = `<table class="tbl"><thead><tr>
      <th>Database</th><th class="r">Tables</th><th class="r">Prod</th><th class="r">Local</th><th class="r">Last run</th>
    </tr></thead><tbody>${dbs.map(b => `<tr>
      <td class="mono">${x(b.name)}</td>
      <td class="r num">${n(b.tables)}</td>
      <td class="r num muted">${bytes(b.remote_bytes)}</td>
      <td class="r num">${bytes(b.local_bytes)}</td>
      <td class="r num">${b.failed ? `<span style="color:var(--red)">${b.failed} failed</span>` : b.synced ? `${b.synced} copied` : '<span class="muted">unchanged</span>'}</td>
    </tr>`).join('')}</tbody></table>`;
}

function renderSlow(t) {
  const rows = t.slowest || [], failed = t.failed || [];
  $('slowMeta').textContent = t.count ? `${t.count} table(s) copied` : '';
  if (!rows.length && !failed.length) { $('slowWrap').innerHTML = '<div class="panel-empty">No tables copied in the last run</div>'; return; }
  const list = failed.concat(rows.filter(r => r.status === 'OK'));
  $('slowWrap').innerHTML = `<table class="tbl"><thead><tr>
      <th>Table</th><th>Status</th><th class="r">Time</th><th class="r">Dump size</th>
    </tr></thead><tbody>${list.map(r => `<tr>
      <td class="mono">${x(r.db)}.<b>${x(r.table)}</b></td>
      <td>${r.status === 'OK' ? badge('OK', 'green') : badge(r.status.replace('FAIL_', 'FAILED '), 'red')}</td>
      <td class="r num">${dur(r.secs)}</td>
      <td class="r num muted">${bytes(r.bytes)}</td>
    </tr>`).join('')}</tbody></table>`;
}

function renderSystem(d) {
  const s = d.system || {}, c = d.config || {}, b = d.disk || {};
  const mem = s.mem_total ? `${bytes(s.mem_total - s.mem_avail)} / ${bytes(s.mem_total)}` : '—';
  const items = [
    ['Host', s.hostname], ['CPU / Load', `${s.cpus} cores · ${(s.load || []).join(' / ') || '—'}`],
    ['Memory used', mem], ['Host uptime', s.host_uptime_s ? dur(s.host_uptime_s) : '—'],
    ['Dashboard uptime', `${dur(s.api_uptime_s)} · PID ${s.api_pid}`],
    ['Production', `${c.PROD_DB_USER || '?'}@${c.PROD_DB_HOST || '?'}:${c.PROD_DB_PORT || 3306}`],
    ['Sync mode', `${c.SYNC_MODE || 'incremental'} · detect: ${c.SYNC_CHANGE_DETECT || 'stats'}`],
    ['Parallel workers', c.SYNC_PARALLEL || '4'],
    ['Daily full sync', c.FULL_SYNC_HOUR !== '' && c.FULL_SYNC_HOUR != null ? `first run after ${c.FULL_SYNC_HOUR}:00` : 'off'],
    ['Excluded', [c.SYNC_EXCLUDE_DBS, c.SYNC_EXCLUDE_TABLES].filter(Boolean).join(' · ') || 'none'],
    ['Retention', `${c.BACKUP_KEEP_COUNT || 3} runs / ${c.BACKUP_KEEP_DAYS || 1}d · ${c.LOG_KEEP_COUNT || 14} logs`],
    ['Buffer pool', c.MYSQL_BUFFER_POOL || '1G'],
    ['Backup disk', b.backups ? `${bytes(b.backups.free)} free (${b.backups.pct}% used)` : '—'],
    ['Local MySQL port', c.MYSQL_LOCAL_PORT || '3306'],
  ];
  $('sysWrap').innerHTML = '<dl class="kv">' + items.map(([k, v]) => `<div><dt>${x(k)}</dt><dd>${x(v ?? '—')}</dd></div>`).join('') + '</dl>';
}

// ─── Log list ─────────────────────────────────────────────────────────────────
async function loadLogs() {
  const r = await fetch('/api/logs', { headers: hdrs() });
  if (!r.ok) return;
  const logs = await r.json();
  const sb = $('logSidebar');
  const syncLogs = logs.filter(l => !l.system), sysLogs = logs.filter(l => l.system);
  $('logMeta').textContent = syncLogs.length ? syncLogs.length + ' sync log' + (syncLogs.length !== 1 ? 's' : '') : '';
  if (!logs.length) { sb.innerHTML = '<div class="log-empty">No log files found</div>'; return; }
  const item = l => `<div class="log-file-item ${l.name === curLog ? 'active' : ''}" data-name="${x(l.name)}" onclick="openLog('${x(l.name)}')">
       <div class="log-file-name">${x(l.name)}</div>
       <div class="log-file-meta">${x(l.modified)} &nbsp;&middot;&nbsp; ${l.size_kb} KB</div>
     </div>`;
  sb.innerHTML = (syncLogs.length ? '<div class="log-group">Sync runs</div>' + syncLogs.map(item).join('') : '') +
                 (sysLogs.length  ? '<div class="log-group">System</div>'    + sysLogs.map(item).join('')  : '');
  if (curLog && running && running.log === curLog) openLog(curLog, true);
}

// ─── Log viewer ───────────────────────────────────────────────────────────────
async function openLog(name, silent) {
  if (!name) return;
  curLog = name;
  document.querySelectorAll('.log-file-item').forEach(i => i.classList.toggle('active', i.dataset.name === name));
  $('logPh').style.display = 'none';
  $('logViewer').style.display = 'flex';
  $('logViewerTitle').textContent = name;
  if (!silent) {
    $('logLines').innerHTML = '<div style="padding:1rem;color:var(--text-dim)"><span class="spin"></span> Loading…</div>';
    $('logViewer').scrollIntoView({ behavior: 'smooth', block: 'nearest' });
  }
  const r = await fetch('/api/logs/' + encodeURIComponent(name), { headers: hdrs() });
  if (!r.ok) { $('logLines').innerHTML = '<div style="padding:1rem;color:var(--red)">&#10007; Failed to load log.</div>'; return; }
  const d = await r.json();
  curLogData = d.lines;
  if (d.truncated) curLogData = ['… (showing last ' + d.lines.length + ' lines)'].concat(d.lines);
  renderLog();
}
function renderLog() {
  const q = ($('logFilter').value || '').toLowerCase();
  $('logLines').innerHTML = curLogData.map((line, i) => {
    if (q && !line.toLowerCase().includes(q)) return '';
    let cls = '';
    if (line.includes('[ERROR]') || /\bERROR \d+/.test(line) || line.includes('FAILED')) cls = 'll-err';
    else if (line.includes('[WARN]') || line.includes('PARTIAL'))                      cls = 'll-warn';
    else if (line.includes('Sync Finished') || line.includes('SUCCESS') || line.includes('✓') || line.includes('[OK]')) cls = 'll-ok';
    else if (line.includes('=====') || line.includes('DB Sync'))                         cls = 'll-head';
    else if (line.trim() === '')                                                        cls = 'll-dim';
    return `<div class="log-line ${cls}"><span class="ln">${i+1}</span><span class="lt">${x(line)}</span></div>`;
  }).join('');
  if ($('logFollow').checked) scrollBottom();
}
function scrollBottom() { const b = $('logBody'); if (b) b.scrollTop = b.scrollHeight; }

// ─── Button state ─────────────────────────────────────────────────────────────
function updateButtonState() {
  ['btnEnable', 'btnDisable'].forEach(id => $(id).disabled = !authed);
  ['btnRunInc', 'btnRunFull'].forEach(id => $(id).disabled = !authed || !!running);
}

// ─── Cron control ─────────────────────────────────────────────────────────────
async function cronAction(action) {
  if (!authed) { toast('Enter a valid API token first', 'r'); return; }
  if (!confirm(action === 'enable' ? 'Enable the cron job?' : 'Disable the cron job?')) return;
  const btn = $(action === 'enable' ? 'btnEnable' : 'btnDisable'), orig = btn.innerHTML;
  btn.disabled = true;
  btn.innerHTML = `<span class="spin"></span>${action === 'enable' ? 'Enabling…' : 'Disabling…'}`;
  try {
    const r = await fetch('/api/cron/' + action, { method: 'POST', headers: hdrs() });
    const d = await r.json();
    toast((d.status || d.error || 'done').replace(/_/g, ' '), r.ok ? 'g' : 'r');
    await loadStatus();
  } finally { btn.disabled = false; btn.innerHTML = orig; }
}

// ─── Run / stop sync ──────────────────────────────────────────────────────────
async function runJob(mode) {
  if (!authed) { toast('Enter a valid API token first', 'r'); return; }
  const msg = mode === 'full'
    ? 'Run a FULL sync now?\n\nEvery table is re-copied from production. This takes much longer than an incremental sync.'
    : 'Run an incremental sync now?\n\nOnly tables changed since the last run are copied.';
  if (!confirm(msg)) return;
  const btn = $(mode === 'full' ? 'btnRunFull' : 'btnRunInc'), orig = btn.innerHTML;
  btn.disabled = true; btn.innerHTML = '<span class="spin"></span>Starting…';
  try {
    const r = await fetch('/api/sync/trigger', { method: 'POST', headers: hdrs(), body: JSON.stringify({ mode }) });
    const d = await r.json();
    r.ok ? toast(`${mode === 'full' ? 'Full' : 'Incremental'} sync started`, 'b') : toast(d.error || 'Failed to start sync', 'r');
  } finally {
    btn.innerHTML = orig;
    setTimeout(refresh, 1500);
  }
}
async function stopSync() {
  if (!confirm('Stop the running sync?\n\nTables already copied are kept; the rest will be retried on the next run.')) return;
  const r = await fetch('/api/sync/stop', { method: 'POST', headers: hdrs() });
  const d = await r.json();
  toast(d.error || ('Sync ' + (d.status || '').replace(/_/g, ' ')), r.ok ? 'b' : 'r');
  setTimeout(refresh, 2000);
}

// ─── Countdown ────────────────────────────────────────────────────────────────
function startCd() {
  if (cdTimer) clearInterval(cdTimer);
  cdTimer = setInterval(() => {
    cdVal--;
    if (cdVal <= 0) { cdVal = running ? 5 : 30; refresh(); }
    $('countdown').textContent = 'Auto-refresh in ' + Math.max(cdVal, 0) + 's';
  }, 1000);
}

// ─── Utilities ────────────────────────────────────────────────────────────────
function x(s) {
  return String(s ?? '').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;').replace(/'/g,'&#39;');
}
function n(v) { return (v ?? 0).toLocaleString(); }
function bytes(b) {
  b = Number(b) || 0;
  const u = ['B','KB','MB','GB','TB']; let i = 0;
  while (b >= 1024 && i < u.length - 1) { b /= 1024; i++; }
  return (i ? b.toFixed(b < 10 ? 2 : 1) : b) + ' ' + u[i];
}
function dur(s) {
  s = Math.max(0, Math.round(Number(s) || 0));
  const d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600), m = Math.floor(s % 3600 / 60), sec = s % 60;
  if (d) return `${d}d ${h}h`;
  if (h) return `${h}h ${m}m`;
  if (m) return `${m}m ${String(sec).padStart(2,'0')}s`;
  return `${sec}s`;
}
function rel(ts) {
  const diff = (new Date(ts.replace(' ', 'T')) - new Date()) / 1000;
  return diff > 0 ? dur(diff) : 'now';
}
function badge(text, color, dot) {
  return `<span class="sbadge sbadge-${color}">${dot ? '<span class="sbadge-dot"></span>' : ''}${x(text)}</span>`;
}
function statusBadge(st) {
  const map = { success: 'green', partial: 'yellow', failed: 'red', cancelled: 'gray', running: 'blue' };
  return badge((st || '').toUpperCase(), map[st] || 'gray');
}
function toast(msg, type) {
  const icons = { g: '&#10003;', r: '&#10007;', b: '&#8505;' };
  const t = Object.assign(document.createElement('div'), {
    className: 'toast t' + (type || 'b'),
    innerHTML: `<span class="t-ico">${icons[type]||icons.b}</span><span class="t-msg">${x(msg)}</span>`
  });
  $('toastWrap').appendChild(t);
  setTimeout(() => t.remove(), 4500);
}
</script>
</body>
</html>"""


@app.route("/")
def dashboard():
    return Response(DASHBOARD_HTML, mimetype="text/html")


if __name__ == "__main__":
    port = int(os.environ.get("API_PORT", 8080))
    print(f"\n  ERP Sync Dashboard  ->  http://0.0.0.0:{port}")
    print(f"  Backup dir : {BACKUP_DIR}")
    print(f"  Log dir    : {LOG_DIR}")
    print(f"  State dir  : {STATE_DIR}")
    print(f"  Auth token : {'SET' if API_TOKEN else 'NOT SET - add API_TOKEN to .env'}\n", flush=True)
    try:
        from waitress import serve
        serve(app, host="0.0.0.0", port=port, threads=8, channel_timeout=60, ident="erp-sync")
    except ImportError:
        print("  [WARN] waitress not installed — falling back to Flask dev server", flush=True)
        app.run(host="0.0.0.0", port=port, debug=False, threaded=True)
