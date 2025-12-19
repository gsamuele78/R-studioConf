from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse, PlainTextResponse
import uvicorn
import psutil
import shutil
import os
from prometheus_client import generate_latest, Gauge, CollectorRegistry

app = FastAPI(title="Botanical Telemetry API", version="1.0.0")

# --- Prometheus Metrics ---
registry = CollectorRegistry()

# User Metrics
RSTUDIO_SESSIONS = Gauge('botanical_rstudio_sessions_total', 'Number of active RStudio sessions (rsession processes)', registry=registry)
TTYD_SESSIONS = Gauge('botanical_terminal_sessions_total', 'Number of active Web Terminal sessions (ttyd connections)', registry=registry)

# Storage Metrics
PROJECTS_DISK_TOTAL = Gauge('botanical_projects_disk_bytes_total', 'Total capacity of projects storage', registry=registry)
PROJECTS_DISK_USED = Gauge('botanical_projects_disk_bytes_used', 'Used capacity of projects storage', registry=registry)
PROJECTS_DISK_FREE = Gauge('botanical_projects_disk_bytes_free', 'Free capacity of projects storage', registry=registry)

DATA_DISK_TOTAL = Gauge('botanical_data_disk_bytes_total', 'Total capacity of data storage', registry=registry)
DATA_DISK_USED = Gauge('botanical_data_disk_bytes_used', 'Used capacity of data storage', registry=registry)
DATA_DISK_FREE = Gauge('botanical_data_disk_bytes_free', 'Free capacity of data storage', registry=registry)

# Configuration
R_PROJECTS_DIR = os.getenv("R_PROJECTS_ROOT", "/media/r_projects")
DATA_DIR = os.getenv("DATA_ROOT", "/media/data") # Example second volume

def count_processes_by_name(name_substring):
    count = 0
    for proc in psutil.process_iter(['name', 'cmdline']):
        try:
            # Check name or cmdline
            if name_substring in proc.info['name'] or \
               (proc.info['cmdline'] and any(name_substring in arg for arg in proc.info['cmdline'])):
                count += 1
        except (psutil.NoSuchProcess, psutil.AccessDenied, psutil.ZombieProcess):
            pass
    return count

def update_metrics():
    # 1. Active User Sessions
    # Count rsession processes. Note: one per active user session.
    rsessions = count_processes_by_name('rsession')
    RSTUDIO_SESSIONS.set(rsessions)

    # Count ttyd child processes (bash/login) or ttyd itself?
    # ttyd spawns 'login' processes.
    # A simple proxy is checking established connections to ttyd port, but psutil process count is easier.
    # Searching for 'login' processes started by root/ttyd might be tricky in containerless.
    # Simpler: ttyd usually runs as a single process manager, serving clients.
    # We might trust ttyd's internal metrics if exposed, but standard ttyd doesn't expose prom metrics easily.
    # let's count 'login' processes that might be interactive?
    # For now, let's just count 'ttyd' to ensure it's up, or look for its children.
    # Actually, counting 'login' might include SSH logins.
    # Best guess: Count connections to port 7681 (default ttyd).
    try:
        connections = len([c for c in psutil.net_connections(kind='tcp') if c.laddr.port == 7681 and c.status == 'ESTABLISHED'])
        TTYD_SESSIONS.set(connections)
    except Exception:
        TTYD_SESSIONS.set(0) # Fallback if permission issues

    # 2. Disk Usage
    if os.path.exists(R_PROJECTS_DIR):
        usage = shutil.disk_usage(R_PROJECTS_DIR)
        PROJECTS_DISK_TOTAL.set(usage.total)
        PROJECTS_DISK_USED.set(usage.used)
        PROJECTS_DISK_FREE.set(usage.free)
    
    # Optional Data Dir
    if os.path.exists(DATA_DIR):
        usage = shutil.disk_usage(DATA_DIR)
        DATA_DISK_TOTAL.set(usage.total)
        DATA_DISK_USED.set(usage.used)
        DATA_DISK_FREE.set(usage.free)

@app.get("/metrics")
async def metrics():
    """Expose metrics in Prometheus format."""
    update_metrics()
    return PlainTextResponse(generate_latest(registry))

@app.get("/status")
async def status():
    """Human readable status."""
    update_metrics()
    return {
        "status": "ok",
        "rstudio_sessions": RSTUDIO_SESSIONS._value.get(),
        "terminal_sessions": TTYD_SESSIONS._value.get(),
        "storage": {
            "projects_free_gb": PROJECTS_DISK_FREE._value.get() / (1024**3)
        }
    }

if __name__ == "__main__":
    # Run on localhost only, Nginx will proxy
    uvicorn.run(app, host="127.0.0.1", port=8000)
