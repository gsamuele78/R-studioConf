from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse, PlainTextResponse
from fastapi.middleware.cors import CORSMiddleware
import uvicorn
import psutil
import shutil
import os
import subprocess
import time
from prometheus_client import generate_latest, Gauge, CollectorRegistry

app = FastAPI(title="Botanical Telemetry API", version="2.0.0")

# Allow same-origin portal JS to call /api/ (Nginx will further restrict)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["GET"],
    allow_headers=["*"],
)

# --- Prometheus Metrics ---
registry = CollectorRegistry()

RSTUDIO_SESSIONS = Gauge('botanical_rstudio_sessions_total', 'Number of active RStudio sessions (rsession processes)', registry=registry)
TTYD_SESSIONS = Gauge('botanical_terminal_sessions_total', 'Number of active Web Terminal sessions (ttyd connections)', registry=registry)

PROJECTS_DISK_TOTAL = Gauge('botanical_projects_disk_bytes_total', 'Total capacity of projects storage', registry=registry)
PROJECTS_DISK_USED  = Gauge('botanical_projects_disk_bytes_used',  'Used capacity of projects storage',  registry=registry)
PROJECTS_DISK_FREE  = Gauge('botanical_projects_disk_bytes_free',  'Free capacity of projects storage',  registry=registry)

DATA_DISK_TOTAL = Gauge('botanical_data_disk_bytes_total', 'Total capacity of data storage', registry=registry)
DATA_DISK_USED  = Gauge('botanical_data_disk_bytes_used',  'Used capacity of data storage',  registry=registry)
DATA_DISK_FREE  = Gauge('botanical_data_disk_bytes_free',  'Free capacity of data storage',  registry=registry)

# Configuration
R_PROJECTS_DIR = os.getenv("R_PROJECTS_ROOT", "/media/r_projects")
DATA_DIR       = os.getenv("DATA_ROOT",        "/media/data")
NFS_HOME_DIR   = os.getenv("NFS_HOME",         "/nfs/home")
TMP_DIR        = "/tmp"

def count_processes_by_name(name_substring):
    count = 0
    for proc in psutil.process_iter(['name', 'cmdline']):
        try:
            if name_substring in proc.info['name'] or \
               (proc.info['cmdline'] and any(name_substring in arg for arg in proc.info['cmdline'])):
                count += 1
        except (psutil.NoSuchProcess, psutil.AccessDenied, psutil.ZombieProcess):
            pass
    return count

def get_r_session_details():
    """Return list of active rsession processes with username and CPU/RAM."""
    sessions = []
    for proc in psutil.process_iter(['pid', 'name', 'username', 'cpu_percent', 'memory_info', 'create_time', 'cmdline']):
        try:
            if 'rsession' in proc.info['name']:
                mem_mb = round(proc.info['memory_info'].rss / (1024 * 1024), 1)
                sessions.append({
                    "pid":      proc.info['pid'],
                    "user":     proc.info['username'] or "unknown",
                    "cpu_pct":  round(proc.cpu_percent(interval=0.1), 1),
                    "mem_mb":   mem_mb,
                    "age_min":  round((time.time() - proc.info['create_time']) / 60, 0),
                })
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            pass
    return sessions

def get_disk_info(path):
    """Return dict with total/used/free_gb and pct for a mount path."""
    try:
        if os.path.exists(path):
            usage = shutil.disk_usage(path)
            total_gb = usage.total / (1024**3)
            used_gb  = usage.used  / (1024**3)
            free_gb  = usage.free  / (1024**3)
            pct      = round(usage.used / usage.total * 100, 1) if usage.total > 0 else 0
            return {"total_gb": round(total_gb,1), "used_gb": round(used_gb,1),
                    "free_gb": round(free_gb,1), "pct": pct, "available": True}
    except Exception:
        pass
    return {"available": False}

def get_top_r_processes(n=5):
    """Top N rsession processes sorted by CPU."""
    sessions = get_r_session_details()
    sessions.sort(key=lambda x: x['cpu_pct'], reverse=True)
    return sessions[:n]

def update_metrics():
    rsessions = count_processes_by_name('rsession')
    RSTUDIO_SESSIONS.set(rsessions)
    try:
        connections = len([c for c in psutil.net_connections(kind='tcp') if c.laddr.port == 7681 and c.status == 'ESTABLISHED'])
        TTYD_SESSIONS.set(connections)
    except Exception:
        TTYD_SESSIONS.set(0)

    if os.path.exists(R_PROJECTS_DIR):
        u = shutil.disk_usage(R_PROJECTS_DIR)
        PROJECTS_DISK_TOTAL.set(u.total); PROJECTS_DISK_USED.set(u.used); PROJECTS_DISK_FREE.set(u.free)
    if os.path.exists(DATA_DIR):
        u = shutil.disk_usage(DATA_DIR)
        DATA_DISK_TOTAL.set(u.total); DATA_DISK_USED.set(u.used); DATA_DISK_FREE.set(u.free)


@app.get("/metrics")
async def metrics():
    """Prometheus metrics (LAN-restricted by Nginx)."""
    update_metrics()
    return PlainTextResponse(generate_latest(registry))


@app.get("/status")
async def status():
    """Legacy human-readable status (LAN-restricted by Nginx)."""
    update_metrics()
    return {
        "status": "ok",
        "rstudio_sessions": RSTUDIO_SESSIONS._value.get(),
        "terminal_sessions": TTYD_SESSIONS._value.get(),
        "storage": {"projects_free_gb": PROJECTS_DISK_FREE._value.get() / (1024**3)}
    }


@app.get("/api/v1/status")
async def public_status():
    """
    Public portal status endpoint — exposed at /api/status via Nginx.
    Returns aggregated system + service metrics for the portal dashboard.
    No sensitive user data is exposed (no usernames, just counts and load).
    """
    try:
        cpu_pct    = psutil.cpu_percent(interval=0.5)
        cpu_count  = psutil.cpu_count(logical=True)
        mem        = psutil.virtual_memory()
        swap       = psutil.swap_memory()
        load_avg   = os.getloadavg()          # 1min, 5min, 15min
    except Exception:
        cpu_pct = 0; cpu_count = 1; mem = None; swap = None; load_avg = (0,0,0)

    # Active sessions
    r_sessions   = count_processes_by_name('rsession')
    try:
        ttyd_conns = len([c for c in psutil.net_connections(kind='tcp')
                          if c.laddr.port == 7681 and c.status == 'ESTABLISHED'])
    except Exception:
        ttyd_conns = 0

    # Storage
    tmp_disk     = get_disk_info(TMP_DIR)
    nfs_disk     = get_disk_info(NFS_HOME_DIR)
    proj_disk    = get_disk_info(R_PROJECTS_DIR)

    # Top R sessions (CPU, RAM) — no usernames
    top_r = get_top_r_processes(5)
    # Anonymise: replace username with a positional label
    top_r_anon = [{"label": f"Session {i+1}", "cpu_pct": s["cpu_pct"],
                   "mem_mb": s["mem_mb"], "age_min": s["age_min"]}
                  for i, s in enumerate(top_r)]

    # Ollama
    ollama_active = False
    try:
        ollama_conns = [c for c in psutil.net_connections(kind='tcp')
                        if c.laddr.port == 11434 and c.status == 'ESTABLISHED']
        ollama_active = len(ollama_conns) > 0 or count_processes_by_name('ollama') > 0
    except Exception:
        pass

    return {
        "ts": int(time.time()),
        "cpu": {
            "pct":     round(cpu_pct, 1),
            "cores":   cpu_count,
            "load_1m": round(load_avg[0], 2),
            "load_5m": round(load_avg[1], 2),
        },
        "ram": {
            "total_gb": round(mem.total / (1024**3), 1) if mem else 0,
            "used_gb":  round(mem.used  / (1024**3), 1) if mem else 0,
            "pct":      round(mem.percent, 1) if mem else 0,
        },
        "swap": {
            "total_gb": round(swap.total / (1024**3), 1) if swap else 0,
            "pct":      round(swap.percent, 1) if swap else 0,
        },
        "sessions": {
            "rstudio":  r_sessions,
            "terminal": ttyd_conns,
        },
        "disk": {
            "tmp":      tmp_disk,
            "nfs_home": nfs_disk,
            "projects": proj_disk,
        },
        "services": {
            "ollama": ollama_active,
        },
        "r_sessions": top_r_anon,
    }


@app.get("/api/v1/health")
async def health():
    """Simple health probe for Nginx upstream checks."""
    return {"status": "ok"}


if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=8000)
