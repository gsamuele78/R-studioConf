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
import asyncio
import json
import base64
import smtplib
from email.message import EmailMessage

import dns.resolver  # type: ignore[import]
import psutil  # type: ignore[import]
from pydantic import BaseModel, Field  # type: ignore[import]
from fastapi import FastAPI, HTTPException  # type: ignore[import]
from fastapi.middleware.cors import CORSMiddleware  # type: ignore[import]
from fastapi.responses import PlainTextResponse, StreamingResponse, HTMLResponse  # type: ignore[import]
from fastapi.openapi.docs import get_swagger_ui_html  # type: ignore[import]
from prometheus_client import CollectorRegistry, Gauge, generate_latest  # type: ignore[import]
import uvicorn  # type: ignore[import]

# ---------------------------------------------------------------------------
# Models
# ---------------------------------------------------------------------------

class CpuStatus(BaseModel):
    """CPU status and utilization metrics."""
    pct: float = Field(..., description="Utilisation %", example=42.1)
    cores: int = Field(..., description="Logical CPU cores", example=32)
    load_1m: float = Field(..., example=1.2)
    load_5m: float = Field(..., example=0.9)

class RamStatus(BaseModel):
    """RAM usage metrics."""
    pct: float
    used_gb: float
    total_gb: float

class SwapStatus(BaseModel):
    """Swap memory usage metrics."""
    pct: float
    total_gb: float

class DiskInfo(BaseModel):
    """Information for a specific disk partition."""
    available: bool
    pct: float = 0
    free_gb: float = 0
    used_gb: float = 0
    total_gb: float = 0

class DiskStatus(BaseModel):
    """Overall disk status across monitored partitions."""
    nfs_home: DiskInfo
    projects: DiskInfo
    tmp: DiskInfo

class RSession(BaseModel):
    """Details for a single active R session."""
    label: str
    cpu_pct: float
    mem_mb: float
    age_min: int

class SessionCounts(BaseModel):
    """Counts of active user sessions."""
    rstudio: int
    terminal: int

class ServicesStatus(BaseModel):
    """Status flags for background services."""
    ollama: bool

class StatusResponse(BaseModel):
    """Comprehensive system status payload."""
    ts: int = Field(..., description="Unix timestamp of snapshot")
    hostname: str
    cache_age_s: float
    cpu: CpuStatus
    ram: RamStatus
    swap: SwapStatus
    sessions: SessionCounts
    disk: DiskStatus
    r_sessions: list[RSession]
    services: ServicesStatus

class HealthResponse(BaseModel):
    """Basic structural health check response."""
    status: str = Field(..., example="ok")
    cache_age_s: float = Field(..., example=3.1)

class ProblemReport(BaseModel):
    """Payload for submitting a problem report."""
    message: str
    application: str = Field(default="Biome Portal", description="The application where the report was generated")
    user_contact: str = Field(default="", description="Optional user contact email")
    images: list[str] = Field(default_factory=list, description="List of base64 data URIs for images")
    context: dict = Field(default_factory=dict, description="Additional context info")

# ---------------------------------------------------------------------------
# App
# ---------------------------------------------------------------------------
app = FastAPI(
    title="Biome Telemetry API",
    description="""
Real-time system metrics for the **Biome Big Data Calculus** research platform.

Metrics are collected every 5 seconds by a background daemon and served
with <1 ms latency from an in-memory cache.

### Authentication
Public endpoints (`/api/v1/*`) are rate-limited at 30 req/min per IP by Nginx.
Prometheus (`/metrics`) and legacy (`/status`) endpoints are LAN-only.

### Push streaming
Use `GET /api/v1/stream` (SSE) to receive updates the instant the cache
refreshes — no polling needed. The browser `EventSource` API reconnects
automatically on disconnect.
    """,
    version="4.0.0",
    docs_url=None,          # overridden below with custom top-bar
    redoc_url="/api/redoc",
    openapi_url="/api/openapi.json",
    contact={"name": "Biome Research Platform"},
    openapi_tags=[
        {"name": "Public status",  "description": "Rate-limited via Nginx proxy"},
        {"name": "Streaming",      "description": "SSE push — no polling required"},
        {"name": "Health",         "description": "Liveness probes"},
        {"name": "Monitoring",     "description": "LAN-only Prometheus + legacy"},
    ],
)

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


def _get_primary_ip() -> str:
    """Gets the routing IP, bypassing the frequent 127.0.1.1 /etc/hosts issue on Ubuntu."""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.settimeout(0.5)
        # Doesn't actually send packet, just checks routing table
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return socket.gethostbyname(socket.gethostname())


def _check_service_active(svc_name: str) -> str:
    """Quickly check if a systemd service is active without heavy subprocess piping."""
    try:
        import subprocess
        res = subprocess.run(["systemctl", "is-active", svc_name], capture_output=True, text=True, timeout=1, check=False)
        return res.stdout.strip()
    except Exception:
        return "unknown"


def _get_system_snapshot() -> dict:
    """Safely gathers a realistic point-in-time snapshot of the OS state and active users."""
    snapshot = {
        "ip": _get_primary_ip(),
        "uptime_hrs": 0.0,
        "load_avg": (0.0, 0.0, 0.0),
        "memory_pct": 0.0,
        "swap_pct": 0.0,
        "disk_root_pct": 0.0,
        "disk_tmp_pct": 0.0,
        "disk_projects_pct": 0.0,
        "top_processes": [],
        "services": {},
        "app_metrics": {"rstudio_mem_mb": 0, "php_fpm_mem_mb": 0},
        "terminal_users": [],
        "rstudio_users": set(),
        "error": None
    }
    try:
        snapshot["uptime_hrs"] = round((time.time() - psutil.boot_time()) / 3600, 1)
        snapshot["load_avg"] = os.getloadavg()
        snapshot["memory_pct"] = psutil.virtual_memory().percent
        snapshot["swap_pct"] = psutil.swap_memory().percent
        
        # Disk Space (Crucial for crashes ENOSPC)
        snapshot["disk_root_pct"] = _disk_info("/").get("pct", 0.0)
        snapshot["disk_tmp_pct"] = _disk_info("/tmp").get("pct", 0.0)
        snapshot["disk_projects_pct"] = _disk_info("/media/r_projects").get("pct", 0.0)
        
        # CPU/Mem Top processes (identify runaway processes instantly)
        procs = []
        for p in psutil.process_iter(["name", "cpu_percent", "memory_percent"]):
            try:
                if p.info["cpu_percent"] is not None:
                    procs.append({
                        "name": p.info["name"], 
                        "cpu": p.info["cpu_percent"] or 0, 
                        "mem": p.info["memory_percent"] or 0
                    })
            except Exception:
                pass
        procs.sort(key=lambda x: x["cpu"], reverse=True)
        snapshot["top_processes"] = [f"{p['name']} (CPU: {round(p['cpu'],1)}%, Mem: {round(p['mem'],1)}%)" for p in procs[:3]]
        
        snapshot["services"] = {
            "rstudio-server": _check_service_active("rstudio-server"),
            "nginx": _check_service_active("nginx"),
            "php-fpm": _check_service_active("php8.3-fpm") or _check_service_active("php8.1-fpm"), # common versions
            "ttyd": _check_service_active("ttyd")
        }
        
        # OS-level logged in users (SSH, TTYd)
        for u in psutil.users():
            user_str = f"{u.name} ({u.terminal})"
            if user_str not in snapshot["terminal_users"]:
                snapshot["terminal_users"].append(user_str)
                
        # App-specific Deep Dives
        rsession_mem = 0
        php_mem = 0
        for p in psutil.process_iter(["name", "username", "memory_info"]):
            try:
                name = p.info.get("name") or ""
                user = p.info.get("username") or ""
                mem = p.info.get("memory_info")
                
                if "rsession" in name:
                    if mem: rsession_mem += mem.rss
                    if user not in ("root", "rstudio-server", "www-data"):
                        snapshot["rstudio_users"].add(user)
                        
                if "php-fpm" in name and mem:
                    php_mem += mem.rss
            except Exception:
                pass
                
        snapshot["app_metrics"]["rstudio_mem_mb"] = round(rsession_mem / 1e6, 1)
        snapshot["app_metrics"]["php_fpm_mem_mb"] = round(php_mem / 1e6, 1)
                
    except Exception as e:
        snapshot["error"] = str(e)
        
    snapshot["rstudio_users"] = list(snapshot["rstudio_users"])
    return snapshot


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

def _load_email_config() -> dict[str, str]:
    config = {
        "SMTP_HOST": "localhost",
        "SMTP_PORT": "25",
        "SENDER_EMAIL": "noreply@localhost",
        "BIOME_CONTACT": "support@localhost",
        "SMTP_DNS_SERVERS": "8.8.8.8"
    }
    # Note: 50_setup_nodes copies this to /etc/biome-calc/conf/setup_nodes.vars.conf
    # but the service runs as root and might have issues with some permissions or paths.
    cfg_paths = [
        "/etc/biome-calc/conf/setup_nodes.vars.conf",
        "/home/administrator/configServices/R-studioConf/config/setup_nodes.vars.conf"
    ]
    
    for cfg_path in cfg_paths:
        if os.path.exists(cfg_path):
            try:
                with open(cfg_path, "r", encoding="utf-8") as f:
                    for line in f:
                        line = line.strip()
                        if not line or line.startswith("#") or "=" not in line:
                            continue
                        k, v = line.split("=", 1)
                        v = v.strip("\"'")
                        if k in config:
                            config[k] = v
                break # Found a valid config file, stop trying others
            except Exception as e:
                print(f"Error loading {cfg_path}: {e}")
            
    # As requested, ensure the sender is hostname@unibo.it
    config["SENDER_EMAIL"] = f"{socket.gethostname()}@unibo.it"
    return config

def _load_admin_recipients() -> list[str]:
    recipients = []
    paths = [
        "/etc/biome-calc/conf/admin_recipients.txt",
        "/home/administrator/configServices/R-studioConf/config/admin_recipients.txt"
    ]
    for p in paths:
        if os.path.exists(p):
            try:
                with open(p, "r", encoding="utf-8") as f:
                    for line in f:
                        line = line.strip()
                        if line and not line.startswith("#"):
                            recipients.append(line)
                if recipients:
                    break
            except Exception as e:
                print(f"Error loading {p}: {e}")
    
    if not recipients:
        recipients.append("Lifewatch_Biome_internal@live.unibo.it")
    return recipients

@app.post("/api/v1/report-problem", tags=["Support"], summary="Send a problem report via email")
async def report_problem(report: ProblemReport):
    """Send a user-submitted problem report to the configured admin email."""
    config = _load_email_config()
    admin_emails = _load_admin_recipients()
    
    app_name = report.application
    msg = EmailMessage()
    subject = f"[{app_name}] Problem Report from {socket.gethostname()}"
    msg['Subject'] = subject
    msg['From'] = config["SENDER_EMAIL"]
    msg['To'] = ", ".join(admin_emails)

    sys_snap = _get_system_snapshot()

    body_lines = [
        f"A new problem has been reported from {app_name} on {socket.gethostname()} ({sys_snap['ip']}).",
        f"User Contact: {report.user_contact if report.user_contact else 'Not provided'}",
        "",
        "--- User Message ---",
        report.message,
        "--------------------",
        ""
    ]
    
    # 1. Attach Client Context (Browser/JS)
    body_lines.append("--- Client Context ---")
    for k, v in report.context.items():
        body_lines.append(f"{k}: {v}")
    body_lines.append("----------------------")
    body_lines.append("")
    
    # 2. Attach Realistic Server Snapshot (Sysadmin Best Practice)
    body_lines.append("--- Server Snapshot (Point-of-Failure) ---")
    body_lines.append(f"Uptime: {sys_snap['uptime_hrs']} hours")
    body_lines.append(f"Load Average: {sys_snap['load_avg']}")
    body_lines.append(f"Memory / Swap Usage: {sys_snap['memory_pct']}% / {sys_snap['swap_pct']}%")
    body_lines.append(f"Disk Usage: Root ({sys_snap['disk_root_pct']}%), Tmpfs ({sys_snap['disk_tmp_pct']}%), Projects ({sys_snap['disk_projects_pct']}%)")
    body_lines.append(f"Core Services: RStudio ({sys_snap['services'].get('rstudio-server')}), Nginx ({sys_snap['services'].get('nginx')}), Nextcloud PHP ({sys_snap['services'].get('php-fpm')}), TTYd ({sys_snap['services'].get('ttyd')})")
    body_lines.append(f"App Memory (Total): RStudio Sessions ({sys_snap['app_metrics']['rstudio_mem_mb']} MB), Nextcloud PHP ({sys_snap['app_metrics']['php_fpm_mem_mb']} MB)")
    body_lines.append(f"Top 3 Processes (CPU): {', '.join(sys_snap['top_processes']) or 'None'}")
    body_lines.append(f"Terminal/SSH Users: {', '.join(sys_snap['terminal_users']) or 'None'}")
    body_lines.append(f"RStudio Users: {', '.join(sys_snap['rstudio_users']) or 'None'}")
    if sys_snap.get("error"):
        body_lines.append(f"Snapshot Error: {sys_snap['error']}")
    body_lines.append("------------------------------------------")
        
    msg.set_content("\n".join(body_lines))

    for i, data_uri in enumerate(report.images):
        if data_uri.startswith("data:"):
            try:
                header, encoded = data_uri.split(",", 1)
                mime_type = header.split(";")[0].split(":")[1]
                maintype, subtype = mime_type.split("/")
                img_data = base64.b64decode(encoded)
                msg.add_attachment(img_data, maintype=maintype, subtype=subtype, filename=f"screenshot_{i+1}.{subtype}")
            except Exception as e:
                print(f"Failed to attach image {i}: {e}")

    smtp_host = config["SMTP_HOST"]
    
    # Try custom DNS resolution if SMTP_DNS_SERVERS is provided
    try:
        dns_servers = [s.strip() for s in config.get("SMTP_DNS_SERVERS", "").split() if s.strip()]
        
        if dns_servers and not smtp_host.replace('.', '').isdigit():
            resolver = dns.resolver.Resolver(configure=False)
            resolver.nameservers = dns_servers
            resolver.lifetime = 5.0
            answers = resolver.resolve(smtp_host, 'A')
            if answers:
                smtp_host = answers[0].to_text()
                print(f"[telemetry] Resolved {config['SMTP_HOST']} to {smtp_host} using {dns_servers}")
    except Exception as e:
        print(f"[telemetry] Custom DNS resolution failed for {smtp_host}: {e}. Falling back to default.")

    try:
        with smtplib.SMTP(smtp_host, int(config["SMTP_PORT"])) as server:
            server.send_message(msg)
        return {"status": "success", "message": "Problem report sent successfully."}
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to send email: {str(e)}") from e

# ---------------------------------------------------------------------------
# Custom API Docs page (Swagger UI + status-page top-bar)
# ---------------------------------------------------------------------------

_TOP_BAR_HTML = """
<style>
  :root {
    --sage-green: #8FBC8F;
    --glass-border: rgba(255,255,255,0.15);
    --text-dim: rgba(240,255,240,0.6);
    --mono: 'JetBrains Mono', monospace;
  }
  @import url('https://fonts.googleapis.com/css2?family=Outfit:wght@400;600&family=JetBrains+Mono:wght@400;600&display=swap');
  #biome-top-bar {
    position: sticky;
    top: 0;
    z-index: 99999;
    background: rgba(10,26,26,0.97);
    backdrop-filter: blur(16px);
    -webkit-backdrop-filter: blur(16px);
    border-bottom: 1px solid var(--glass-border);
    padding: 0.55rem 2rem;
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 1rem;
    font-family: 'Outfit', sans-serif;
    box-sizing: border-box;
    width: 100%;
  }
  #biome-top-bar .brand {
    display: flex;
    align-items: center;
    gap: 0.8rem;
  }
  #biome-top-bar a.back {
    color: var(--sage-green);
    text-decoration: none;
    font-size: 0.9rem;
    display: flex;
    align-items: center;
    gap: 0.4rem;
    transition: opacity 0.2s;
  }
  #biome-top-bar a.back:hover { opacity: 0.8; }
  #biome-top-bar h1 {
    font-size: 1.05rem;
    font-weight: 600;
    letter-spacing: 0.4px;
    color: #F0FFF0;
    margin: 0;
  }
  #biome-update-badge {
    font-family: var(--mono);
    font-size: 0.75rem;
    color: var(--text-dim);
    background: rgba(255,255,255,0.05);
    padding: 0.25rem 0.75rem;
    border-radius: 20px;
    border: 1px solid var(--glass-border);
  }
  #biome-refresh-btn {
    background: rgba(143,188,143,0.15);
    border: 1px solid rgba(143,188,143,0.3);
    color: var(--sage-green);
    padding: 0.32rem 0.9rem;
    border-radius: 20px;
    cursor: pointer;
    font-size: 0.82rem;
    font-family: 'Outfit', sans-serif;
    transition: all 0.2s;
  }
  #biome-refresh-btn:hover { background: rgba(143,188,143,0.25); }
  /* Push Swagger UI below the bar */
  #swagger-ui { padding-top: 0; }
  .swagger-ui .topbar { display: none !important; }  /* hide default Swagger topbar */
</style>

<div id="biome-top-bar">
  <div class="brand">
    <a class="back" href="javascript:void(0)" onclick="Biome.goBack()" title="Back to Portal">
      &#8592; Biome Portal
    </a>
    <span style="color:var(--glass-border)">&#x2502;</span>
    <h1 id="biome-hostname">&#128421;&#65039; &mdash; API Documentation</h1>
  </div>
  <div style="display:flex;align-items:center;gap:0.75rem;">
    <span id="biome-update-badge">&ndash;</span>
    <button id="biome-refresh-btn" onclick="location.reload()">&#x21BA; Refresh</button>
  </div>
</div>

<script src="/biome-portal.js"></script>
<script>
  // Start live clock using shared library
  Biome.startClock('biome-update-badge');
  // Fetch hostname once from telemetry API
  fetch('/api/v1/status', {cache:'no-store'})
    .then(function(r){ return r.json(); })
    .then(function(d){
      var h = document.getElementById('biome-hostname');
      if (h && d.hostname) h.textContent = '🖥️ ' + d.hostname + ' — API Documentation';
    })
    .catch(function(){});
</script>
"""


@app.get("/api/docs", include_in_schema=False)
async def custom_swagger_ui() -> HTMLResponse:
    """Swagger UI with the Biome Portal status top-bar injected."""
    # Get the standard Swagger HTML from FastAPI
    swagger_resp = get_swagger_ui_html(
        openapi_url=app.openapi_url or "/api/openapi.json",
        title=app.title + " — API Docs",
        swagger_favicon_url="data:;base64,iVBORw0KGgo=",
    )
    # Inject our top-bar HTML immediately after <body>
    html = swagger_resp.body.decode("utf-8")
    html = html.replace("<body>", "<body>" + _TOP_BAR_HTML, 1)
    return HTMLResponse(content=html, status_code=200)


@app.get("/api/v1/status", response_model=StatusResponse, tags=["Public status"], summary="Full system snapshot")
async def public_status():
    """Public portal status — returns pre-computed cache, always < 1 ms."""
    payload, ts = _cache.read_status()
    payload["cache_age_s"] = round(time.time() - ts, 1)
    # FastAPI automatically validates and serializes the dict to the response_model
    return payload


@app.get("/api/v1/stream", tags=["Streaming"], summary="Server-Sent Events — push on every cache refresh")
async def stream_status():
    """Stream continuous status updates via Server-Sent Events."""
    async def event_generator():
        last_ts = 0
        while True:
            data, _ = _cache.read_status()
            if data and data.get("ts", 0) != last_ts:
                last_ts = data["ts"]
                yield f"data: {json.dumps(data)}\n\n"
            await asyncio.sleep(1)

    return StreamingResponse(
        event_generator(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "X-Accel-Buffering": "no"
        }
    )


@app.get("/api/v1/health", response_model=HealthResponse, tags=["Health"], summary="Liveness probe")
async def health():
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
