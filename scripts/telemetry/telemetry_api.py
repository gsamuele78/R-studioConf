"""
telemetry_api.py — Botanical Big Data Calculus Telemetry API v3.2
-----------------------------------------------------------------
Background thread refreshes ALL metrics every REFRESH_INTERVAL seconds.
HTTP endpoints return the pre-built cache instantly (< 1 ms, no blocking).

NOTE: fastapi, uvicorn, psutil, prometheus_client are installed in the
      dedicated venv /opt/botanical-telemetry — NOT in the system Python.
      "Unable to import" IDE warnings are expected; the service runs fine
      from the venv via the systemd ExecStart.
"""

from __future__ import annotations

import os
import shutil
import socket
import threading
import time

import psutil  # type: ignore[import]
from fastapi import FastAPI  # type: ignore[import]
from fastapi.middleware.cors import CORSMiddleware  # type: ignore[import]
from fastapi.responses import JSONResponse, PlainTextResponse  # type: ignore[import]
from prometheus_client import CollectorRegistry, Gauge, generate_latest  # type: ignore[import]
import uvicorn  # type: ignore[import]

# ---------------------------------------------------------------------------
# App
# ---------------------------------------------------------------------------
app = FastAPI(title="Botanical Telemetry API", version="3.2.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["GET"],
    allow_headers=["*"],
)

# ---------------------------------------------------------------------------
# Configuration  (env-overridable)
# ---------------------------------------------------------------------------
R_PROJECTS_DIR = os.getenv("R_PROJECTS_ROOT", "/media/r_projects")
DATA_DIR = os.getenv("DATA_ROOT", "/media/data")
NFS_HOME_DIR = os.getenv("NFS_HOME", "/nfs/home")
TMP_DIR = "/tmp"
REFRESH_INTERVAL = int(os.getenv("TELEMETRY_REFRESH_SEC", "5"))
TOP_SESSIONS = 5

# ---------------------------------------------------------------------------
# Prometheus metrics
# ---------------------------------------------------------------------------
registry = CollectorRegistry()
RSTUDIO_SESSIONS = Gauge(
    "botanical_rstudio_sessions_total",
    "Active RStudio sessions",
    registry=registry,
)
TTYD_SESSIONS = Gauge(
    "botanical_terminal_sessions_total",
    "Active terminal sessions",
    registry=registry,
)
PROJECTS_DISK_FREE = Gauge(
    "botanical_projects_disk_bytes_free",
    "Free projects disk bytes",
    registry=registry,
)
DATA_DISK_FREE = Gauge(
    "botanical_data_disk_bytes_free",
    "Free data disk bytes",
    registry=registry,
)


# ---------------------------------------------------------------------------
# Thread-safe cache  (class avoids `global` statement)
# ---------------------------------------------------------------------------
class _Cache:
    """Holds the pre-built status payload and Prometheus bytes."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self.status: dict = {}
        self.prometheus: bytes = b""
        self.ts: float = 0.0

    def write(self, status: dict, prometheus: bytes) -> None:
        """Atomically update the cached status payload and Prometheus metrics."""
        with self._lock:
            self.status = status
            self.prometheus = prometheus
            self.ts = time.time()

    def read_status(self) -> tuple[dict, float]:
        """Return a copy of the status dict and the timestamp of the last refresh."""
        with self._lock:
            return dict(self.status), self.ts

    def read_prometheus(self) -> bytes:
        """Return the latest Prometheus metrics bytes."""
        with self._lock:
            return self.prometheus


_cache = _Cache()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _count_procs(name_sub: str) -> int:
    count = 0
    for p in psutil.process_iter(["name", "cmdline"]):
        try:
            name = p.info["name"] or ""
            cmdline = p.info["cmdline"] or []
            if name_sub in name or any(name_sub in a for a in cmdline):
                count += 1
        except (psutil.NoSuchProcess, psutil.AccessDenied, psutil.ZombieProcess):
            pass
    return count


def _disk_info(path: str) -> dict:
    if not os.path.exists(path):
        return {"available": False}
    try:
        u = shutil.disk_usage(path)
        pct = round(u.used / u.total * 100, 1) if u.total else 0
        return {
            "available": True,
            "total_gb": round(u.total / 1e9, 1),
            "used_gb": round(u.used / 1e9, 1),
            "free_gb": round(u.free / 1e9, 1),
            "pct": pct,
        }
    except OSError:
        return {"available": False}


def _top_r_sessions(n: int = 5) -> list:
    """Top N rsession processes by CPU, fully anonymised (no usernames)."""
    attrs = ["pid", "name", "cpu_percent", "memory_info", "create_time"]
    sessions = []
    for p in psutil.process_iter(attrs):
        try:
            if "rsession" in (p.info["name"] or ""):
                sessions.append({
                    # interval=None uses the cached value psutil stores between calls
                    "cpu_pct": round(p.cpu_percent(interval=None), 1),
                    "mem_mb": round(p.info["memory_info"].rss / 1e6, 1),
                    "age_min": round((time.time() - p.info["create_time"]) / 60),
                })
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            pass
    sessions.sort(key=lambda x: x["cpu_pct"], reverse=True)
    return [{"label": f"Session {i + 1}", **s} for i, s in enumerate(sessions[:n])]


def _ttyd_connections() -> int:
    try:
        return sum(
            1 for c in psutil.net_connections(kind="tcp")
            if c.laddr.port == 7681 and c.status == "ESTABLISHED"
        )
    except (psutil.AccessDenied, OSError):
        return 0


def _ollama_active() -> bool:
    if _count_procs("ollama") > 0:
        return True
    try:
        return any(
            c.laddr.port == 11434 and c.status == "ESTABLISHED"
            for c in psutil.net_connections(kind="tcp")
        )
    except (psutil.AccessDenied, OSError):
        return False


# ---------------------------------------------------------------------------
# Background refresh
# ---------------------------------------------------------------------------

def _collect() -> None:
    """
    Collect all metrics and write to cache.
    cpu_percent(interval=0.5) blocks for ~0.5 s — safe here in the background thread.
    """
    try:
        cpu_pct = psutil.cpu_percent(interval=0.5)
        cpu_count = psutil.cpu_count(logical=True) or 1
        mem = psutil.virtual_memory()
        swap = psutil.swap_memory()
        load_avg = os.getloadavg()
    except OSError:
        cpu_pct, cpu_count = 0.0, 1
        mem, swap, load_avg = None, None, (0.0, 0.0, 0.0)

    r_sessions = _count_procs("rsession")
    ttyd_conns = _ttyd_connections()
    tmp_disk = _disk_info(TMP_DIR)
    nfs_disk = _disk_info(NFS_HOME_DIR)
    proj_disk = _disk_info(R_PROJECTS_DIR)
    top_r = _top_r_sessions(TOP_SESSIONS)
    ollama = _ollama_active()

    # Prometheus gauges
    RSTUDIO_SESSIONS.set(r_sessions)
    TTYD_SESSIONS.set(ttyd_conns)
    if proj_disk.get("available"):
        PROJECTS_DISK_FREE.set(proj_disk["free_gb"] * 1e9)
    data_d = _disk_info(DATA_DIR)
    if data_d.get("available"):
        DATA_DISK_FREE.set(data_d["free_gb"] * 1e9)

    payload: dict = {
        "ts": int(time.time()),
        "hostname": socket.gethostname(),
        "cpu": {
            "pct": round(cpu_pct, 1),
            "cores": cpu_count,
            "load_1m": round(load_avg[0], 2),
            "load_5m": round(load_avg[1], 2),
        },
        "ram": {
            "total_gb": round(mem.total / 1e9, 1) if mem else 0,
            "used_gb": round(mem.used / 1e9, 1) if mem else 0,
            "pct": round(mem.percent, 1) if mem else 0,
        },
        "swap": {
            "total_gb": round(swap.total / 1e9, 1) if swap else 0,
            "pct": round(swap.percent, 1) if swap else 0,
        },
        "sessions": {
            "rstudio": r_sessions,
            "terminal": ttyd_conns,
        },
        "disk": {
            "tmp": tmp_disk,
            "nfs_home": nfs_disk,
            "projects": proj_disk,
        },
        "services": {
            "ollama": ollama,
        },
        "r_sessions": top_r,
    }
    _cache.write(payload, generate_latest(registry))


def _background_loop() -> None:
    """Daemon: refresh every REFRESH_INTERVAL seconds."""
    while True:
        try:
            _collect()
        except Exception as exc:  # pylint: disable=broad-exception-caught
            print(f"[telemetry] refresh error: {exc}", flush=True)
        time.sleep(REFRESH_INTERVAL)


# Prime cache at module load, then start background daemon
try:
    _collect()
except Exception as exc:  # pylint: disable=broad-exception-caught
    print(f"[telemetry] initial collect error: {exc}", flush=True)

threading.Thread(
    target=_background_loop,
    daemon=True,
    name="telemetry-refresh",
).start()


# ---------------------------------------------------------------------------
# HTTP Endpoints
# ---------------------------------------------------------------------------

@app.get("/api/v1/status")
async def public_status() -> JSONResponse:
    """Public portal status — returns pre-computed cache, always < 1 ms."""
    payload, ts = _cache.read_status()
    payload["cache_age_s"] = round(time.time() - ts, 1)
    return JSONResponse(content=payload)


@app.get("/api/v1/health")
async def health() -> dict:
    """Liveness probe."""
    _, ts = _cache.read_status()
    return {"status": "ok", "cache_age_s": round(time.time() - ts, 1)}


@app.get("/metrics")
async def metrics() -> PlainTextResponse:
    """Prometheus metrics (LAN-restricted by Nginx /monitoring/)."""
    return PlainTextResponse(_cache.read_prometheus())


@app.get("/status")
async def status_legacy() -> dict:
    """Legacy human-readable status (LAN-restricted)."""
    c, _ = _cache.read_status()
    return {
        "status": "ok",
        "rstudio_sessions": c.get("sessions", {}).get("rstudio", 0),
        "terminal_sessions": c.get("sessions", {}).get("terminal", 0),
        "cpu_pct": c.get("cpu", {}).get("pct", 0),
        "ram_pct": c.get("ram", {}).get("pct", 0),
    }


if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=8000, log_level="warning")
