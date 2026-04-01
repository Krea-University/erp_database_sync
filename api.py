#!/usr/bin/env python3
"""
api.py  –  Web dashboard + HTTP API for ERP DB sync control
Usage:
  pip3 install -r requirements.txt
  python3 api.py

  Or as a background service:
  nohup python3 api.py >> /var/erp_sync/logs/api.log 2>&1 &
"""
import os
import glob
import subprocess
import datetime
import pathlib
from functools import wraps
from flask import Flask, jsonify, request, render_template_string

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
def _read_crontab():
    r = subprocess.run(["crontab", "-l"], capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else ""


def _write_crontab(content):
    subprocess.run(["crontab", "-"], input=content, text=True, check=True)


def _cron_info():
    """Return (enabled: bool, expression: str|None)"""
    lines = _read_crontab().splitlines()
    for i, line in enumerate(lines):
        if CRON_MARKER in line:
            for j in range(i + 1, min(i + 3, len(lines))):
                cand = lines[j].strip()
                if cand and "sync.sh" in cand:
                    disabled = cand.startswith("#")
                    expr = cand.lstrip("# DISABLED:").strip()
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
    backups = glob.glob(f"{BACKUP_DIR}/dump_all_*.sql.gz")
    size_bytes = sum(os.path.getsize(f) for f in backups if os.path.exists(f))
    return jsonify({
        "cron_enabled": enabled,
        "cron_expr": expr,
        "last_sync": last_sync,
        "log_count": len(logs),
        "backup_count": len(backups),
        "backup_size_gb": round(size_bytes / 1024 ** 3, 2),
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


@app.route("/api/sync/trigger", methods=["POST"])
@require_token
def api_sync_trigger():
    sync_script = str(SCRIPT_DIR / "sync.sh")
    if not os.path.exists(sync_script):
        return jsonify({"error": "sync.sh not found"}), 500
    os.makedirs(LOG_DIR, exist_ok=True)
    ts = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    log_file = f"{LOG_DIR}/manual_sync_{ts}.log"
    with open(log_file, "w") as lf:
        subprocess.Popen(
            ["bash", sync_script],
            stdout=lf, stderr=lf,
            start_new_session=True,
        )
    return jsonify({"status": "triggered", "log": os.path.basename(log_file)})


@app.route("/api/logs")
@require_token
def api_logs():
    all_logs = sorted(
        glob.glob(f"{LOG_DIR}/sync_*.log") + glob.glob(f"{LOG_DIR}/manual_sync_*.log"),
        key=os.path.getmtime, reverse=True
    )[:30]
    return jsonify([{
        "name": os.path.basename(f),
        "size_kb": round(os.path.getsize(f) / 1024, 1),
        "modified": datetime.datetime.fromtimestamp(
            os.path.getmtime(f)
        ).strftime("%Y-%m-%d %H:%M:%S"),
    } for f in all_logs])


@app.route("/api/logs/<path:filename>")
@require_token
def api_log_content(filename):
    safe = os.path.basename(filename)           # prevent path traversal
    log_path = os.path.join(LOG_DIR, safe)
    if not os.path.isfile(log_path):
        return jsonify({"error": "Not found"}), 404
    with open(log_path) as f:
        lines = f.readlines()
    return jsonify({
        "name": safe,
        "lines": [l.rstrip("\n") for l in lines[-500:]],
        "total_lines": len(lines),
    })


# ── Web Dashboard ─────────────────────────────────────────────────────────────
DASHBOARD_HTML = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>ERP Sync Dashboard</title>
<style>
:root {
  --bg:#0f172a; --card:#1e293b; --border:#334155;
  --text:#e2e8f0; --muted:#94a3b8;
  --green:#22c55e; --red:#ef4444; --blue:#3b82f6;
  --yellow:#f59e0b;
}
*{box-sizing:border-box;margin:0;padding:0}
body{background:var(--bg);color:var(--text);font-family:'Segoe UI',sans-serif;min-height:100vh}
header{background:var(--card);border-bottom:1px solid var(--border);padding:1rem 2rem;display:flex;align-items:center;justify-content:space-between;flex-wrap:wrap;gap:.8rem}
header h1{font-size:1.15rem;font-weight:700;color:var(--blue)}
.token-row{display:flex;gap:.5rem;align-items:center}
.token-row input{background:var(--bg);border:1px solid var(--border);color:var(--text);padding:.4rem .8rem;border-radius:6px;font-size:.85rem;width:200px}
.main{padding:1.5rem 2rem;max-width:1100px;margin:0 auto}
.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:1rem;margin-bottom:1.5rem}
.card{background:var(--card);border:1px solid var(--border);border-radius:12px;padding:1.2rem}
.card-label{font-size:.72rem;color:var(--muted);text-transform:uppercase;letter-spacing:.05em;margin-bottom:.5rem}
.card-value{font-size:1.5rem;font-weight:700}
.card-sub{font-size:.78rem;color:var(--muted);margin-top:.3rem}
.green{color:var(--green)} .red{color:var(--red)} .blue{color:var(--blue)} .yellow{color:var(--yellow)}
.actions{display:flex;gap:.8rem;flex-wrap:wrap;margin-bottom:1.5rem}
.btn{padding:.55rem 1.3rem;border-radius:8px;border:none;cursor:pointer;font-size:.88rem;font-weight:600;transition:opacity .15s}
.btn:hover{opacity:.82} .btn:disabled{opacity:.35;cursor:not-allowed}
.btn-green{background:var(--green);color:#000}
.btn-red{background:var(--red);color:#fff}
.btn-blue{background:var(--blue);color:#fff}
.btn-outline{background:transparent;color:var(--text);border:1px solid var(--border)}
.section{background:var(--card);border:1px solid var(--border);border-radius:12px;padding:1.2rem;margin-bottom:1.5rem}
.section-title{font-size:.78rem;font-weight:700;color:var(--muted);text-transform:uppercase;letter-spacing:.06em;margin-bottom:.9rem}
.log-list{display:flex;flex-direction:column;gap:.35rem;max-height:260px;overflow-y:auto}
.log-item{display:flex;align-items:center;justify-content:space-between;padding:.45rem .8rem;background:var(--bg);border-radius:6px;cursor:pointer;border:1px solid transparent;transition:border-color .15s}
.log-item:hover,.log-item.active{border-color:var(--blue)}
.log-name{font-size:.82rem;font-family:monospace;color:var(--blue)}
.log-meta{font-size:.72rem;color:var(--muted);white-space:nowrap;margin-left:.5rem}
.log-viewer{margin-top:1rem;background:#000;border-radius:8px;padding:1rem;max-height:480px;overflow-y:auto;font-family:monospace;font-size:.76rem;line-height:1.55;white-space:pre-wrap;word-break:break-all}
.err{color:var(--red)} .warn{color:var(--yellow)} .ok{color:var(--green)} .dim{color:var(--muted)}
.badge{display:inline-block;padding:.2rem .65rem;border-radius:999px;font-size:.72rem;font-weight:700}
.badge-green{background:rgba(34,197,94,.15);color:var(--green)}
.badge-red{background:rgba(239,68,68,.15);color:var(--red)}
.toast{position:fixed;bottom:1.5rem;right:1.5rem;background:var(--card);border:1px solid var(--border);border-radius:8px;padding:.75rem 1.2rem;font-size:.84rem;z-index:9999;animation:fadeUp .2s ease}
@keyframes fadeUp{from{transform:translateY(12px);opacity:0}to{transform:translateY(0);opacity:1}}
.spin{display:inline-block;width:13px;height:13px;border:2px solid rgba(255,255,255,.25);border-top-color:#fff;border-radius:50%;animation:rot .6s linear infinite;vertical-align:middle;margin-right:5px}
@keyframes rot{to{transform:rotate(360deg)}}
</style>
</head>
<body>
<header>
  <h1>&#9881; ERP Local DB Sync &mdash; Dashboard</h1>
  <div class="token-row">
    <input type="password" id="tokenInput" placeholder="Enter API Token&hellip;" />
    <button class="btn btn-blue" onclick="saveToken()">Connect</button>
  </div>
</header>
<div class="main">

  <!-- Status Cards -->
  <div class="cards">
    <div class="card">
      <div class="card-label">Cron Job</div>
      <div class="card-value" id="cronStatus">&mdash;</div>
      <div class="card-sub" id="cronExpr">&mdash;</div>
    </div>
    <div class="card">
      <div class="card-label">Last Sync</div>
      <div class="card-value blue" id="lastSync" style="font-size:1rem;margin-top:.3rem">&mdash;</div>
    </div>
    <div class="card">
      <div class="card-label">Backups</div>
      <div class="card-value yellow" id="backupCount">&mdash;</div>
      <div class="card-sub" id="backupSize">&mdash;</div>
    </div>
    <div class="card">
      <div class="card-label">Log Files</div>
      <div class="card-value" id="logCount">&mdash;</div>
    </div>
  </div>

  <!-- Actions -->
  <div class="actions">
    <button class="btn btn-green" id="btnEnable"  onclick="cronAction('enable')">&#10003; Enable Cron</button>
    <button class="btn btn-red"   id="btnDisable" onclick="cronAction('disable')">&#9726; Disable Cron</button>
    <button class="btn btn-blue"  id="btnSync"    onclick="triggerSync()">&#9654; Sync Now</button>
    <button class="btn btn-outline" onclick="refresh()">&#8635; Refresh</button>
  </div>

  <!-- Log Viewer -->
  <div class="section">
    <div class="section-title">Log Reports</div>
    <div class="log-list" id="logList">
      <p style="color:var(--muted);font-size:.82rem">Connect with your API token to view logs.</p>
    </div>
    <div class="log-viewer" id="logViewer" style="display:none"></div>
  </div>

</div>

<script>
let token = sessionStorage.getItem('erp_token') || '';
if (token) { document.getElementById('tokenInput').value = token; init(); }
else { loadStatus(); }

document.getElementById('tokenInput').addEventListener('keydown', e => { if (e.key==='Enter') saveToken(); });

function saveToken() {
  token = document.getElementById('tokenInput').value.trim();
  sessionStorage.setItem('erp_token', token);
  init();
}

function hdrs() { return {'X-API-Token': token, 'Content-Type': 'application/json'}; }

async function init() { await loadStatus(); await loadLogs(); }

async function refresh() { await loadStatus(); if (token) await loadLogs(); }

async function loadStatus() {
  try {
    const d = await fetch('/api/status').then(r => r.json());
    const on = d.cron_enabled;
    document.getElementById('cronStatus').innerHTML =
      `<span class="badge ${on?'badge-green':'badge-red'}">${on?'&#9679; ENABLED':'&#9675; DISABLED'}</span>`;
    document.getElementById('cronExpr').textContent   = d.cron_expr  || '(no cron registered)';
    document.getElementById('lastSync').textContent   = d.last_sync  || 'Never';
    document.getElementById('backupCount').textContent= d.backup_count + ' file' + (d.backup_count!==1?'s':'');
    document.getElementById('backupSize').textContent = d.backup_size_gb + ' GB on disk';
    document.getElementById('logCount').textContent   = d.log_count + ' file' + (d.log_count!==1?'s':'');
  } catch(e) { console.error(e); }
}

async function loadLogs() {
  if (!token) return;
  const r = await fetch('/api/logs', {headers: hdrs()});
  if (!r.ok) return;
  const logs = await r.json();
  const el = document.getElementById('logList');
  if (!logs.length) {
    el.innerHTML = '<p style="color:var(--muted);font-size:.82rem">No log files found.</p>';
    return;
  }
  el.innerHTML = logs.map(l =>
    `<div class="log-item" onclick="viewLog('${esc(l.name)}',this)">
       <span class="log-name">${esc(l.name)}</span>
       <span class="log-meta">${esc(l.modified)} &nbsp; ${l.size_kb} KB</span>
     </div>`
  ).join('');
}

async function viewLog(name, el) {
  document.querySelectorAll('.log-item').forEach(i => i.classList.remove('active'));
  el.classList.add('active');
  const v = document.getElementById('logViewer');
  v.style.display = 'block';
  v.innerHTML = '<span class="spin"></span>Loading\u2026';
  const r = await fetch('/api/logs/' + encodeURIComponent(name), {headers: hdrs()});
  if (!r.ok) { v.innerHTML = '<span class="err">Failed to load log.</span>'; return; }
  const d = await r.json();
  v.innerHTML = d.lines.map(line => {
    const s = esc(line);
    if (line.includes('[ERROR]'))        return `<span class="err">${s}</span>`;
    if (line.includes('[WARN]'))         return `<span class="warn">${s}</span>`;
    if (line.includes('Sync Finished') ||
        line.includes('complete') ||
        line.includes('Restore complete')) return `<span class="ok">${s}</span>`;
    if (line.trim() === '' || line.includes('====')) return `<span class="dim">${s}</span>`;
    return s;
  }).join('\n');
  v.scrollTop = v.scrollHeight;
}

async function cronAction(action) {
  if (!token) { toast('Enter API token first', 'red'); return; }
  const btn = document.getElementById(action==='enable'?'btnEnable':'btnDisable');
  const label = action==='enable'?'Enabling\u2026':'Disabling\u2026';
  btn.disabled = true;
  btn.innerHTML = `<span class="spin"></span>${label}`;
  try {
    const r = await fetch(`/api/cron/${action}`, {method:'POST', headers:hdrs()});
    const d = await r.json();
    toast(d.status.replace(/_/g,' '), r.ok?'green':'red');
    await loadStatus();
  } finally {
    btn.disabled = false;
    btn.innerHTML = action==='enable'?'&#10003; Enable Cron':'&#9726; Disable Cron';
  }
}

async function triggerSync() {
  if (!token) { toast('Enter API token first', 'red'); return; }
  const btn = document.getElementById('btnSync');
  btn.disabled = true;
  btn.innerHTML = '<span class="spin"></span>Triggering\u2026';
  try {
    const r = await fetch('/api/sync/trigger', {method:'POST', headers:hdrs()});
    const d = await r.json();
    if (r.ok) {
      toast('Sync triggered \u2014 ' + d.log, 'green');
      setTimeout(() => { loadStatus(); loadLogs(); }, 4000);
    } else {
      toast(d.error || 'Error triggering sync', 'red');
    }
  } finally {
    btn.disabled = false;
    btn.innerHTML = '&#9654; Sync Now';
  }
}

function esc(s) {
  return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
}

function toast(msg, color) {
  const t = document.createElement('div');
  t.className = 'toast';
  t.style.color = color==='green'?'var(--green)':color==='red'?'var(--red)':'var(--text)';
  t.textContent = msg;
  document.body.appendChild(t);
  setTimeout(() => t.remove(), 4000);
}

setInterval(loadStatus, 30000);
</script>
</body>
</html>"""


@app.route("/")
def dashboard():
    return render_template_string(DASHBOARD_HTML)


if __name__ == "__main__":
    port = int(os.environ.get("API_PORT", 8080))
    print(f"ERP Sync Dashboard → http://0.0.0.0:{port}")
    print(f"  Backup dir : {BACKUP_DIR}")
    print(f"  Log dir    : {LOG_DIR}")
    print(f"  Auth token : {'SET' if API_TOKEN else 'NOT SET — add API_TOKEN to .env'}")
    app.run(host="0.0.0.0", port=port, debug=False)
