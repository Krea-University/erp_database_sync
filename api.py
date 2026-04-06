#!/usr/bin/env python3
"""
api.py  –  Web dashboard + HTTP API for ERP DB sync control
Usage:
  pip3 install -r requirements.txt
  python3 api.py          # foreground
  ./start_api.sh start    # background (managed)
"""
import os
import glob
import subprocess
import datetime
import pathlib
from functools import wraps
from flask import Flask, jsonify, request, Response

app = Flask(__name__)
SCRIPT_DIR  = pathlib.Path(__file__).parent
CRON_MARKER = "# erp_database_sync"


# ── Load simple vars from .env ────────────────────────────────────────────────
def _load_env():
    env_path = SCRIPT_DIR / ".env"
    if not env_path.exists():
        return
    safe_keys = {"LOG_DIR", "BACKUP_DIR", "API_TOKEN", "API_PORT", "LOG_KEEP_COUNT"}
    for line in env_path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, val = line.partition("=")
        key = key.strip()
        if key in safe_keys:
            val = val.strip().strip("'").strip('"')
            os.environ.setdefault(key, val)


_load_env()

API_TOKEN  = os.environ.get("API_TOKEN", "")
BACKUP_DIR = os.environ.get("BACKUP_DIR", str(SCRIPT_DIR / "backups"))
LOG_DIR    = os.environ.get("LOG_DIR",    str(SCRIPT_DIR / "logs"))


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


# ── Cron helpers ──────────────────────────────────────────────────────────────
def _crontab_available():
    import shutil
    return shutil.which("crontab") is not None


def _read_crontab():
    if not _crontab_available():
        return ""
    try:
        r = subprocess.run(["crontab", "-l"], capture_output=True, text=True)
        return r.stdout if r.returncode == 0 else ""
    except Exception:
        return ""


def _write_crontab(content):
    if not _crontab_available():
        raise RuntimeError("crontab not available on this system")
    subprocess.run(["crontab", "-"], input=content, text=True, check=True)


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
                    # Use replace() to remove literal "# DISABLED: " prefix (not lstrip which removes chars)
                    expr = cand.replace("# DISABLED: ", "", 1).lstrip("#").strip()
                    return not disabled, expr
    return False, None


# ── API routes ────────────────────────────────────────────────────────────────
@app.route("/api/status")
def api_status():
    enabled, expr = _cron_info()
    logs = sorted(
        glob.glob(f"{LOG_DIR}/sync_*.log") + glob.glob(f"{LOG_DIR}/manual_sync_*.log"),
        reverse=True
    )
    last_sync = None
    if logs:
        last_sync = datetime.datetime.fromtimestamp(
            os.path.getmtime(logs[0])
        ).strftime("%Y-%m-%d %H:%M:%S")
    backups   = glob.glob(f"{BACKUP_DIR}/dump_all_*.sql.gz")
    size_bytes = sum(os.path.getsize(f) for f in backups if os.path.exists(f))
    return jsonify({
        "cron_enabled":    enabled,
        "cron_expr":       expr,
        "last_sync":       last_sync,
        "log_count":       len(logs),
        "backup_count":    len(backups),
        "backup_size_gb":  round(size_bytes / 1024 ** 3, 2),
    })


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


@app.route("/api/cron/run", methods=["POST"])
@require_token
def api_cron_run():
    """Run the sync job immediately (same as trigger, but under /api/cron/)"""
    sync_script = str(SCRIPT_DIR / "sync.sh")
    if not os.path.exists(sync_script):
        return jsonify({"error": "sync.sh not found"}), 500
    os.makedirs(LOG_DIR, exist_ok=True)
    ts       = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    log_file = f"{LOG_DIR}/manual_sync_{ts}.log"
    with open(log_file, "w") as lf:
        subprocess.Popen(["bash", sync_script], stdout=lf, stderr=lf, start_new_session=True)
    return jsonify({"status": "running", "log": os.path.basename(log_file)})


@app.route("/api/sync/trigger", methods=["POST"])
@require_token
def api_sync_trigger():
    sync_script = str(SCRIPT_DIR / "sync.sh")
    if not os.path.exists(sync_script):
        return jsonify({"error": "sync.sh not found"}), 500
    os.makedirs(LOG_DIR, exist_ok=True)
    ts       = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    log_file = f"{LOG_DIR}/manual_sync_{ts}.log"
    with open(log_file, "w") as lf:
        subprocess.Popen(["bash", sync_script], stdout=lf, stderr=lf, start_new_session=True)
    return jsonify({"status": "triggered", "log": os.path.basename(log_file)})


@app.route("/api/logs")
@require_token
def api_logs():
    all_logs = sorted(
        glob.glob(f"{LOG_DIR}/sync_*.log") + glob.glob(f"{LOG_DIR}/manual_sync_*.log"),
        key=os.path.getmtime, reverse=True
    )[:30]
    return jsonify([{
        "name":     os.path.basename(f),
        "size_kb":  round(os.path.getsize(f) / 1024, 1),
        "modified": datetime.datetime.fromtimestamp(
            os.path.getmtime(f)
        ).strftime("%Y-%m-%d %H:%M:%S"),
    } for f in all_logs])


@app.route("/api/logs/<path:filename>")
@require_token
def api_log_content(filename):
    safe     = os.path.basename(filename)
    log_path = os.path.join(LOG_DIR, safe)
    if not os.path.isfile(log_path):
        return jsonify({"error": "Not found"}), 404
    with open(log_path) as f:
        lines = f.readlines()
    return jsonify({
        "name":        safe,
        "lines":       [l.rstrip("\n") for l in lines[-500:]],
        "total_lines": len(lines),
    })


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
  --text-dim:   #484f58;
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
  background: var(--bg);
  color: var(--text);
  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif;
  min-height: 100vh;
  display: flex;
  flex-direction: column;
  line-height: 1.5;
}
::-webkit-scrollbar { width: 7px; height: 7px; }
::-webkit-scrollbar-track { background: var(--bg); }
::-webkit-scrollbar-thumb { background: var(--border); border-radius: 4px; }
::-webkit-scrollbar-thumb:hover { background: var(--text-dim); }

/* ── Navbar ── */
.navbar {
  position: sticky; top: 0; z-index: 100;
  background: rgba(13,17,23,.96);
  backdrop-filter: blur(14px);
  border-bottom: 1px solid var(--border);
  height: 62px;
  padding: 0 2rem;
  display: flex; align-items: center; justify-content: space-between; gap: 1rem;
}
.brand { display: flex; align-items: center; gap: .75rem; flex-shrink: 0; }
.brand-icon {
  width: 38px; height: 38px;
  background: linear-gradient(135deg, #1f6feb 0%, #388bfd 100%);
  border-radius: 10px;
  display: flex; align-items: center; justify-content: center;
  font-size: 1.15rem; flex-shrink: 0;
  box-shadow: 0 0 0 1px rgba(88,166,255,.2), 0 4px 12px rgba(31,111,235,.3);
}
.brand-name { font-size: .95rem; font-weight: 700; color: #e6edf3; line-height: 1.2; }
.brand-sub  { font-size: .7rem;  color: var(--text-muted); line-height: 1.2; }
.env-pill {
  padding: .18rem .6rem;
  background: var(--green-bg);
  color: var(--green);
  border: 1px solid rgba(63,185,80,.3);
  border-radius: 99px;
  font-size: .62rem; font-weight: 800; letter-spacing: .1em;
}
.nav-right { display: flex; align-items: center; gap: 1rem; }
.conn-status { display: flex; align-items: center; gap: .4rem; font-size: .78rem; color: var(--text-muted); }
.conn-dot { width: 7px; height: 7px; border-radius: 50%; background: var(--text-dim); transition: background .3s; }
.conn-dot.on { background: var(--green); animation: blink 2.2s ease-in-out infinite; }
@keyframes blink { 0%,100%{opacity:1} 50%{opacity:.45} }
.token-row { display: flex; gap: .45rem; align-items: center; }
.token-row input {
  width: 185px;
  background: var(--surface-2); border: 1px solid var(--border);
  border-radius: var(--r-sm); color: var(--text);
  padding: .42rem .8rem; font-size: .82rem; outline: none;
  transition: border-color .15s, box-shadow .15s;
}
.token-row input:focus { border-color: var(--blue); box-shadow: 0 0 0 3px rgba(88,166,255,.15); }
.token-row input::placeholder { color: var(--text-dim); }

/* ── Buttons ── */
.btn {
  display: inline-flex; align-items: center; gap: .4rem;
  padding: .5rem 1.05rem;
  border-radius: var(--r-sm); border: 1px solid transparent;
  cursor: pointer; font-size: .82rem; font-weight: 600; line-height: 1;
  white-space: nowrap; text-decoration: none;
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
.btn-outline { background: var(--surface-2); border-color: var(--border); color: var(--text); }

/* ── Main ── */
.main { flex: 1; padding: 1.75rem 2rem; max-width: 1280px; width: 100%; margin: 0 auto; }

/* ── Metric Cards ── */
.metrics-grid {
  display: grid;
  grid-template-columns: repeat(4, 1fr);
  gap: 1rem; margin-bottom: 1.25rem;
}
.metric-card {
  background: var(--surface); border: 1px solid var(--border);
  border-radius: var(--r); padding: 1.2rem 1.3rem;
  display: flex; flex-direction: column; gap: .8rem;
  position: relative; overflow: hidden;
  transition: border-color .2s, transform .2s, box-shadow .2s;
}
.metric-card:hover { transform: translateY(-2px); box-shadow: 0 8px 24px rgba(0,0,0,.25); }
.metric-card::after {
  content: ''; position: absolute;
  top: 0; left: 0; right: 0; height: 2px;
  border-radius: var(--r) var(--r) 0 0;
}
.metric-card::before {
  content: ''; position: absolute;
  inset: 0; border-radius: var(--r);
  opacity: .05; pointer-events: none;
}
.c-blue::after   { background: var(--blue); }
.c-blue::before  { background: var(--blue); }
.c-blue:hover    { border-color: rgba(88,166,255,.35); }
.c-green::after  { background: var(--green); }
.c-green::before { background: var(--green); }
.c-green:hover   { border-color: rgba(63,185,80,.35); }
.c-purple::after  { background: var(--purple); }
.c-purple::before { background: var(--purple); }
.c-purple:hover   { border-color: rgba(210,168,255,.35); }
.c-orange::after  { background: var(--orange); }
.c-orange::before { background: var(--orange); }
.c-orange:hover   { border-color: rgba(255,166,87,.35); }

.metric-top { display: flex; align-items: center; justify-content: space-between; }
.metric-label { font-size: .7rem; font-weight: 700; text-transform: uppercase; letter-spacing: .07em; color: var(--text-muted); }
.metric-icon  { font-size: 1.05rem; }
.metric-value { font-size: 1.45rem; font-weight: 700; color: #e6edf3; min-height: 1.8rem; display: flex; align-items: center; }
.metric-detail { font-size: .72rem; color: var(--text-muted); }

/* ── Status Badge ── */
.sbadge {
  display: inline-flex; align-items: center; gap: .38rem;
  padding: .24rem .65rem; border-radius: var(--r-sm);
  font-size: .76rem; font-weight: 700; letter-spacing: .03em;
}
.sbadge-dot { width: 6px; height: 6px; border-radius: 50%; background: currentColor; flex-shrink: 0; }
.sbadge-green {
  background: var(--green-bg); color: var(--green);
  border: 1px solid rgba(63,185,80,.28);
}
.sbadge-green .sbadge-dot { animation: pulseG 1.8s ease-in-out infinite; }
@keyframes pulseG { 0%,100%{box-shadow:0 0 0 0 rgba(63,185,80,.5)} 60%{box-shadow:0 0 0 4px rgba(63,185,80,0)} }
.sbadge-gray  {
  background: rgba(139,148,158,.1); color: var(--text-muted);
  border: 1px solid rgba(139,148,158,.2);
}

/* ── Control Panel ── */
.control-panel {
  background: var(--surface); border: 1px solid var(--border);
  border-radius: var(--r); padding: 1.1rem 1.5rem;
  margin-bottom: 1.25rem;
  display: flex; align-items: center; justify-content: space-between;
  flex-wrap: wrap; gap: .9rem;
}
.panel-title { font-size: .88rem; font-weight: 700; color: #e6edf3; display: flex; align-items: center; gap: .5rem; }
.action-row  { display: flex; align-items: center; gap: .55rem; flex-wrap: wrap; }
.countdown   { font-size: .73rem; color: var(--text-dim); padding-left: .25rem; }

/* ── Divider ── */
.divider { height: 1px; background: var(--border); margin: .25rem 0; }

/* ── Log Section ── */
.log-section {
  background: var(--surface); border: 1px solid var(--border);
  border-radius: var(--r); overflow: hidden; margin-bottom: 1.5rem;
}
.log-section-header {
  display: flex; align-items: center; justify-content: space-between;
  padding: .9rem 1.5rem;
  background: var(--surface-2); border-bottom: 1px solid var(--border);
}
.log-layout { display: flex; min-height: 440px; }
.log-sidebar {
  width: 265px; flex-shrink: 0;
  border-right: 1px solid var(--border);
  overflow-y: auto; max-height: 580px;
}
.log-empty { padding: 2rem 1rem; text-align: center; color: var(--text-dim); font-size: .8rem; line-height: 1.6; }
.log-file-item {
  padding: .65rem 1rem; cursor: pointer;
  border-bottom: 1px solid var(--border-dim);
  border-left: 2px solid transparent;
  transition: background .1s, border-color .1s;
}
.log-file-item:hover  { background: var(--surface-2); }
.log-file-item.active { background: var(--blue-bg); border-left-color: var(--blue); }
.log-file-name { font-family: 'SFMono-Regular', Consolas, monospace; font-size: .72rem; color: var(--blue); line-height: 1.4; margin-bottom: .18rem; word-break: break-all; }
.log-file-meta { font-size: .67rem; color: var(--text-dim); }
.log-content { flex: 1; overflow: hidden; display: flex; flex-direction: column; }
.log-ph {
  flex: 1; display: flex; flex-direction: column;
  align-items: center; justify-content: center;
  color: var(--text-dim); gap: .8rem; padding: 2rem;
}
.log-ph-icon { font-size: 2.8rem; opacity: .3; }
.log-ph p    { font-size: .82rem; }
.log-viewer  { flex: 1; display: flex; flex-direction: column; overflow: hidden; }
.log-toolbar {
  display: flex; align-items: center; justify-content: space-between;
  padding: .5rem 1rem;
  background: var(--surface-2); border-bottom: 1px solid var(--border);
  font-size: .76rem; color: var(--text-muted); font-family: monospace;
}
.log-body {
  flex: 1; overflow-y: auto; background: #010409;
  max-height: 500px;
  font-family: 'SFMono-Regular', Consolas, 'Liberation Mono', monospace;
  font-size: .74rem; line-height: 1.65;
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
.footer {
  border-top: 1px solid var(--border);
  background: var(--surface);
  font-size: .8rem; color: var(--text-muted);
}
.footer-top {
  background: rgba(248,81,73,.06);
  border-bottom: 1px solid rgba(248,81,73,.15);
  padding: .55rem 2rem;
  text-align: center;
}
.footer-notice {
  font-size: .72rem; color: rgba(248,81,73,.8);
  letter-spacing: .02em;
}
.footer-bottom {
  padding: .9rem 2rem;
  display: flex; align-items: center; justify-content: center;
  gap: 1.25rem; flex-wrap: wrap;
}
.footer .heart { color: var(--red); }
.footer strong { color: var(--text); font-weight: 600; }
.footer-sep { color: var(--text-dim); }
.footer-version { color: var(--text-dim); font-size: .72rem; }

/* ── Toast ── */
.toast-container { position: fixed; bottom: 1.5rem; right: 1.5rem; display: flex; flex-direction: column; gap: .45rem; z-index: 9999; }
.toast {
  background: var(--surface); border: 1px solid var(--border);
  border-radius: var(--r-sm); padding: .72rem 1.1rem;
  font-size: .82rem; max-width: 330px;
  display: flex; align-items: flex-start; gap: .5rem;
  box-shadow: 0 8px 28px rgba(0,0,0,.45);
  animation: tin .22s ease;
}
.toast.tg { border-color: rgba(63,185,80,.4); }
.toast.tr { border-color: rgba(248,81,73,.4); }
.toast.tb { border-color: rgba(88,166,255,.4); }
.t-ico { font-size: .88rem; flex-shrink: 0; margin-top: .05rem; }
.t-msg { color: var(--text); line-height: 1.4; }
@keyframes tin { from{transform:translateX(16px);opacity:0} to{transform:translateX(0);opacity:1} }

/* ── Spinner ── */
.spin {
  display: inline-block; width: 12px; height: 12px;
  border: 2px solid rgba(255,255,255,.18); border-top-color: #fff;
  border-radius: 50%; animation: rot .6s linear infinite; vertical-align: middle;
}
@keyframes rot { to{transform:rotate(360deg)} }

/* ── Responsive ── */
@media (max-width: 960px) { .metrics-grid { grid-template-columns: repeat(2,1fr); } }
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

<!-- Main -->
<main class="main">

  <!-- Metric Cards -->
  <div class="metrics-grid">
    <div class="metric-card c-blue">
      <div class="metric-top">
        <span class="metric-label">Cron Job</span>
        <span class="metric-icon">&#128260;</span>
      </div>
      <div class="metric-value" id="cronStatus">&mdash;</div>
      <div class="metric-detail" id="cronExpr">Schedule not loaded</div>
    </div>

    <div class="metric-card c-purple">
      <div class="metric-top">
        <span class="metric-label">Last Sync</span>
        <span class="metric-icon">&#9200;</span>
      </div>
      <div class="metric-value" id="lastSync" style="font-size:1rem;word-break:break-all">&mdash;</div>
      <div class="metric-detail">Timezone &mdash; IST &bull; UTC+5:30</div>
    </div>

    <div class="metric-card c-green">
      <div class="metric-top">
        <span class="metric-label">Backup Storage</span>
        <span class="metric-icon">&#128451;</span>
      </div>
      <div class="metric-value" id="backupCount">&mdash;</div>
      <div class="metric-detail" id="backupSize">&mdash;</div>
    </div>

    <div class="metric-card c-orange">
      <div class="metric-top">
        <span class="metric-label">Log Files</span>
        <span class="metric-icon">&#128203;</span>
      </div>
      <div class="metric-value" id="logCount">&mdash;</div>
      <div class="metric-detail">14 files kept per retention</div>
    </div>
  </div>

  <!-- Controls -->
  <div class="control-panel">
    <span class="panel-title">&#9881; Quick Actions</span>
    <div class="action-row">
      <button class="btn btn-primary" id="btnEnable"  onclick="cronAction('enable')" disabled>&#10003; Enable Cron</button>
      <button class="btn btn-danger"  id="btnDisable" onclick="cronAction('disable')" disabled>&#10007; Disable Cron</button>
      <button class="btn btn-blue"    id="btnRunJob"  onclick="runJobNow()" disabled>&#9654; Run Job Now</button>
      <button class="btn btn-outline" onclick="refresh()">&#8635; Refresh</button>
      <span class="countdown" id="countdown"></span>
    </div>
  </div>

  <!-- Log Reports -->
  <div class="log-section">
    <div class="log-section-header">
      <span class="panel-title">&#128203; Log Reports</span>
      <span id="logMeta" style="font-size:.75rem;color:var(--text-muted)"></span>
    </div>
    <div class="log-layout">
      <!-- Sidebar: file list -->
      <div class="log-sidebar" id="logSidebar">
        <div class="log-empty">Connect with your API token<br>to browse log files</div>
      </div>
      <!-- Content: log viewer -->
      <div class="log-content">
        <div class="log-ph" id="logPh">
          <div class="log-ph-icon">&#128196;</div>
          <p>Select a log file from the left panel</p>
        </div>
        <div class="log-viewer" id="logViewer" style="display:none">
          <div class="log-toolbar">
            <span id="logViewerTitle" style="font-size:.75rem"></span>
            <button class="btn btn-xs btn-outline" onclick="scrollBottom()">&#8595; Bottom</button>
          </div>
          <div class="log-body" id="logBody">
            <div id="logLines"></div>
          </div>
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

<!-- Toasts -->
<div class="toast-container" id="toastWrap"></div>

<script>
// ─── State ────────────────────────────────────────────────────────────────────
let token     = sessionStorage.getItem('erp_token') || '';
let cdVal     = 30;
let cdTimer   = null;

// ─── Boot ─────────────────────────────────────────────────────────────────────
document.getElementById('tokenInput').addEventListener('keydown', e => {
  if (e.key === 'Enter') saveToken();
});
document.getElementById('tokenInput').addEventListener('input', () => {
  token = document.getElementById('tokenInput').value.trim();
  updateButtonState();
});
if (token) {
  document.getElementById('tokenInput').value = token;
  setConn(true);
  updateButtonState();
  boot();
} else {
  updateButtonState();
  loadStatus();
  startCd();
}

function saveToken() {
  token = document.getElementById('tokenInput').value.trim();
  sessionStorage.setItem('erp_token', token);
  setConn(!!token);
  updateButtonState();
  if (token) boot();
}
function setConn(on) {
  document.getElementById('connDot').classList.toggle('on', on);
  document.getElementById('connLabel').textContent = on ? 'Connected' : 'Not connected';
}
function hdrs() { return { 'X-API-Token': token, 'Content-Type': 'application/json' }; }
async function boot() { await loadStatus(); await loadLogs(); startCd(); }
async function refresh() { await loadStatus(); if (token) await loadLogs(); cdVal = 30; }

// ─── Status ───────────────────────────────────────────────────────────────────
async function loadStatus() {
  try {
    const d = await fetch('/api/status').then(r => r.json());
    const on = d.cron_enabled;
    document.getElementById('cronStatus').innerHTML = on
      ? '<span class="sbadge sbadge-green"><span class="sbadge-dot"></span>ENABLED</span>'
      : '<span class="sbadge sbadge-gray"><span class="sbadge-dot"></span>DISABLED</span>';
    document.getElementById('cronExpr').textContent    = d.cron_expr   || 'No schedule registered';
    document.getElementById('lastSync').textContent    = d.last_sync   || 'Never synced';
    document.getElementById('backupCount').textContent = d.backup_count + ' file' + (d.backup_count !== 1 ? 's' : '');
    document.getElementById('backupSize').textContent  = d.backup_size_gb + ' GB used on disk';
    document.getElementById('logCount').textContent    = d.log_count + ' file' + (d.log_count !== 1 ? 's' : '');
  } catch(e) { console.error('Status error:', e); }
}

// ─── Log list ─────────────────────────────────────────────────────────────────
async function loadLogs() {
  if (!token) return;
  const r = await fetch('/api/logs', { headers: hdrs() });
  if (!r.ok) return;
  const logs = await r.json();
  const sb   = document.getElementById('logSidebar');
  document.getElementById('logMeta').textContent = logs.length ? logs.length + ' file' + (logs.length!==1?'s':'') : '';
  if (!logs.length) {
    sb.innerHTML = '<div class="log-empty">No log files found</div>';
    return;
  }
  sb.innerHTML = logs.map(l =>
    `<div class="log-file-item" onclick="viewLog('${x(l.name)}',this)">
       <div class="log-file-name">${x(l.name)}</div>
       <div class="log-file-meta">${x(l.modified)} &nbsp;&middot;&nbsp; ${l.size_kb} KB</div>
     </div>`
  ).join('');
}

// ─── Log viewer ───────────────────────────────────────────────────────────────
async function viewLog(name, el) {
  document.querySelectorAll('.log-file-item').forEach(i => i.classList.remove('active'));
  el.classList.add('active');
  document.getElementById('logPh').style.display     = 'none';
  document.getElementById('logViewer').style.display = 'flex';
  document.getElementById('logViewerTitle').textContent = name;
  document.getElementById('logLines').innerHTML =
    '<div style="padding:1rem;color:var(--text-dim)"><span class="spin"></span> Loading\u2026</div>';

  const r = await fetch('/api/logs/' + encodeURIComponent(name), { headers: hdrs() });
  if (!r.ok) {
    document.getElementById('logLines').innerHTML = '<div style="padding:1rem;color:var(--red)">&#10007; Failed to load log.</div>';
    return;
  }
  const d = await r.json();
  document.getElementById('logLines').innerHTML = d.lines.map((line, i) => {
    let cls = '';
    if (line.includes('[ERROR]'))                                     cls = 'll-err';
    else if (line.includes('[WARN]'))                                 cls = 'll-warn';
    else if (line.includes('Sync Finished') ||
             line.includes('Restore complete') ||
             line.includes('[OK]'))                                   cls = 'll-ok';
    else if (line.includes('=====') || line.includes('DB Sync'))      cls = 'll-head';
    else if (line.trim() === '')                                      cls = 'll-dim';
    return `<div class="log-line ${cls}"><span class="ln">${i+1}</span><span class="lt">${x(line)}</span></div>`;
  }).join('');
  scrollBottom();
}
function scrollBottom() {
  const b = document.getElementById('logBody');
  if (b) b.scrollTop = b.scrollHeight;
}

// ─── Token validation & button state ──────────────────────────────────────────
function updateButtonState() {
  const hasToken = !!token;
  ['btnEnable', 'btnDisable', 'btnRunJob'].forEach(id => {
    const btn = document.getElementById(id);
    if (btn) btn.disabled = !hasToken;
  });
}

// ─── Cron control ─────────────────────────────────────────────────────────────
async function cronAction(action) {
  if (!token) { toast('Enter your API token first', 'r'); return; }
  const msg = action === 'enable' ? 'Enable the cron job?' : 'Disable the cron job?';
  if (!confirm(msg)) return;
  const btn      = document.getElementById(action === 'enable' ? 'btnEnable' : 'btnDisable');
  const origHTML = btn.innerHTML;
  btn.disabled   = true;
  btn.innerHTML  = `<span class="spin"></span>${action === 'enable' ? 'Enabling\u2026' : 'Disabling\u2026'}`;
  try {
    const r = await fetch('/api/cron/' + action, { method: 'POST', headers: hdrs() });
    const d = await r.json();
    toast(d.status.replace(/_/g, ' '), r.ok ? 'g' : 'r');
    await loadStatus();
  } finally { btn.disabled = false; btn.innerHTML = origHTML; }
}

// ─── Run Job Now ──────────────────────────────────────────────────────────────
let isRunning = false;
async function runJobNow() {
  if (!token) { toast('Enter your API token first', 'r'); return; }
  if (isRunning) return; // Prevent double execution
  if (!confirm('Run the sync job now?')) return;
  isRunning = true;
  const btn      = document.getElementById('btnRunJob');
  const origHTML = btn.innerHTML;
  btn.disabled   = true;
  btn.innerHTML  = '<span class="spin"></span>Running\u2026';
  try {
    const r = await fetch('/api/cron/run', { method: 'POST', headers: hdrs() });
    const d = await r.json();
    r.ok
      ? toast('Job started \u2014 ' + d.log, 'b')
      : toast(d.error || 'Failed to run job', 'r');
    if (r.ok) setTimeout(() => { loadStatus(); loadLogs(); }, 5000);
  } finally { isRunning = false; btn.disabled = false; btn.innerHTML = origHTML; }
}

// ─── Countdown ────────────────────────────────────────────────────────────────
function startCd() {
  if (cdTimer) clearInterval(cdTimer);
  cdVal = 30; updCd();
  cdTimer = setInterval(() => {
    cdVal--;
    if (cdVal <= 0) {
      cdVal = 30;
      loadStatus();
      if (token) loadLogs();
    }
    updCd();
  }, 1000);
}
function updCd() {
  document.getElementById('countdown').textContent = 'Auto-refresh in ' + cdVal + 's';
}

// ─── Utilities ────────────────────────────────────────────────────────────────
function x(s) {
  return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
}
function toast(msg, type) {
  const icons = { g: '&#10003;', r: '&#10007;', b: '&#8505;' };
  const t = Object.assign(document.createElement('div'), {
    className: 'toast t' + (type || 'b'),
    innerHTML: `<span class="t-ico">${icons[type]||icons.b}</span><span class="t-msg">${x(msg)}</span>`
  });
  document.getElementById('toastWrap').appendChild(t);
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
    print(f"  Auth token : {'SET' if API_TOKEN else 'NOT SET - add API_TOKEN to .env'}\n")
    app.run(host="0.0.0.0", port=port, debug=False)
