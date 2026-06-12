<!-- docs/architecture/SYSTEM_OVERVIEW.md -->
# BIOME-CALC — System Architecture Overview

> **Audience:** architect, sysadmin
> **Status:** current (rewritten 2026-06-08)
> **Tier:** T1 (host authoritative)

---

## 1. Introduction

BIOME-CALC is a shared high-performance computing platform for botanical
and ecological research. It provides authenticated access to:

- **RStudio Server** — statistical computing environment with cgroup-bound
  resources, modular Rprofile_site guards, and local SSD scratch (`/Rtmp`).
- **Nginx Portal** — glassmorphism landing page, reverse proxy, and TLS
  termination point.
- **OAuth2 Proxy** — OIDC authentication frontend (oauth2-proxy v7.6.0)
  integrated with the platform's identity backend.
- **SSSD / Samba** — Active Directory integration for user authentication
  and home-directory access via NFS.
- **Telemetry API** — lightweight FastAPI service for system health
  monitoring and resource usage reporting.
- **Ollama** — local LLM inference for botanical AI workloads (optional,
  GPU-accelerated where available).

## 2. Deployment Tier Model

| Tier | Location | Status | Description |
|------|----------|--------|-------------|
| **T1** | Host (bare-metal / VM) | **AUTHORITATIVE — continuously fixed** | All scripts, configs, and templates in `scripts/`, `config/`, `templates/`. The source of truth. |
| **T2** | `docker-deploy/` | **Migration in progress** | Docker Compose mirror of T1. Must match T1 behavior; deviations documented in `tier_deltas`. |
| **T3** | `kubernetes-deploy/` | **Skeleton — not production-ready** | Kubernetes manifests. Deferred until T2 is stable and validated. |

**Rule:** Bugs are fixed in T1 first, then ported forward T1 → T2 → T3.
Never patch T2/T3 in a way that masks a T1 defect (HC-03).

## 3. High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        USER BROWSER                              │
│                    (HTTPS / port 443)                            │
└───────────────────────────┬─────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│                     NGINX (TLS termination)                      │
│  - Reverse proxy for all backend services                       │
│  - Static portal landing page                                   │
│  - Proxy buffer / timeout tuning for long-lived RStudio sessions│
│  - Rate limiting, request filtering                             │
└───────┬───────────────┬──────────────┬──────────────┬───────────┘
        │               │              │              │
        ▼               ▼              ▼              ▼
┌───────────────┐ ┌────────────┐ ┌──────────┐ ┌──────────────┐
│ RStudio       │ │ OAuth2     │ │ Telemetry│ │ Ollama       │
│ Server        │ │ Proxy      │ │ API      │ │ (optional)   │
│ (port 8787)   │ │ (port 4180)│ │(port 8000)│ │(port 11434)  │
└───────┬───────┘ └─────┬──────┘ └──────────┘ └──────────────┘
        │               │
        ▼               ▼
┌─────────────────────────────────────────────────────────────────┐
│                   IDENTITY & STORAGE LAYER                        │
│  - SSSD (AD integration, PAM, NSS)                              │
│  - Samba (CIFS/SMB for legacy clients, optional)                │
│  - NFS home directories (/nfs/home/<user>)                      │
│  - Local R library disk (/var/lib/biome-Rlibs/<user>/<R-ver>/)  │
│  - Local scratch disk (/Rtmp, 400 GB ext4)                      │
│  - Shared project storage (/media/r_projects/<project>/)        │
└─────────────────────────────────────────────────────────────────┘
```

### 3.1 Nginx — TLS Termination and Reverse Proxy

Nginx is the single entry point for all HTTPS traffic. It:

- Terminates TLS (Let's Encrypt certificates, auto-renewed).
- Serves the static glassmorphism portal landing page.
- Proxies `/rstudio/` to RStudio Server with WebSocket support and
  extended proxy timeouts for long-lived sessions.
- Proxies `/oauth2/` to the OAuth2 proxy for authentication callbacks.
- Proxies `/telemetry/` to the Telemetry API (internal only).
- Applies rate limiting and request size limits.

Nginx does **not** perform authentication itself. Authentication is
delegated to the OAuth2 proxy and the underlying PAM/SSSD stack.

### 3.2 OAuth2 Proxy — Authentication Frontend

[oauth2-proxy](https://github.com/oauth2-proxy/oauth2-proxy) v7.6.0
provides OIDC-based authentication:

- Redirects unauthenticated users to the configured identity provider.
- Validates OIDC tokens and sets session cookies.
- Passes authenticated user identity to backends via `X-Forwarded-User`
  and related headers.
- Runs as a sidecar to RStudio Server, protecting access to RStudio
  sessions.

### 3.3 RStudio Server — Statistical Computing Environment

RStudio Server (Open Source Edition) provides the R IDE to researchers.
Each user session:

- Runs inside a **cgroup user slice** with bounded CPU and memory
  (configured via `config/setup_nodes.vars.conf`).
- Loads the **modular Rprofile_site** system (version 12.10) which
  transparently applies safety guards:
  - `parallel::detectCores()` returns cgroup-effective core count.
  - `parallel::mclapply()` is auto-rerouted to PSOCK when fork-unsafe
    packages (terra, sf, raster) are loaded.
  - `nimble::compileNimble()` routes compilation scratch to `/Rtmp`.
  - `setwd()` with nonexistent paths is caught.
  - Package installation inside scripts is blocked by default (opt-in).
- Uses `/Rtmp` (400 GB local ext4) for temporary files — not `/tmp` and
  not NFS.
- Has a per-user local R library under `/var/lib/biome-Rlibs/<user>/`
  to avoid NFS lookup storms during parallel `library()` calls.

### 3.4 SSSD — Identity and Authentication

SSSD connects the host to Active Directory:

- Provides PAM authentication for RStudio Server and SSH.
- Provides NSS user/group resolution (`getent passwd`, `id`).
- Home directories are auto-created on NFS at first login.
- Kerberos tickets are managed via `lib_kerberos_setup.sh`.

Samba provides optional CIFS/SMB access for legacy Windows clients
and is configured via `join_domain_samba.sh`.

### 3.5 Telemetry API

A lightweight FastAPI service (`scripts/40_install_telemetry.sh`) that:

- Exposes system health endpoints (CPU, memory, disk, NFS mount status).
- Reports per-user resource usage from cgroup statistics.
- Is internal-only (not exposed to the public internet).

### 3.6 Ollama — Local LLM Inference

Optional GPU-accelerated LLM service for botanical AI workloads:

- Runs as a Docker container (T2) or systemd service (T1).
- Provides a REST API compatible with OpenAI chat completions.
- Models are pinned to specific versions in the platform configuration.

## 4. Design Principles

### 4.1 Pessimistic System Engineering

Every component is designed with the assumption that it **will** fail.
Resources are bounded, defaults are conservative, and the system degrades
gracefully rather than crashing catastrophically.

- **Resource limits are mandatory** — every container and every user
  session has explicit CPU and memory bounds.
- **No silent failures** — errors are logged, surfaced, and actionable.
- **Fail fast, recover cleanly** — hung sessions are terminated by
  cgroup OOM killer or session timeout, not left to accumulate.

### 4.2 Smallest Blast Radius

- Each RStudio session is isolated in its own cgroup slice.
- A single user's runaway process cannot starve other users.
- NFS is used only for persistent home directories; all scratch I/O
  goes to local SSD (`/Rtmp`).

### 4.3 Adapt the System, Not the User Script (HC-13)

The platform **never edits user R scripts**. All safety guards are
implemented transparently in:

- `Rprofile_site.d/` fragments loaded at R startup.
- Environment variables set in `Renviron.site`.
- cgroup resource controls enforced by systemd.
- PAM session limits.

When a user script has a problem (e.g., `mclapply` hang with `terra`),
the fix goes in the platform, not in the user's code. The user writes
portable R; the platform makes it safe.

### 4.4 Honest Documentation

Documentation describes the system as it actually is, not as we wish
it were:

- T2 Docker Compose is **migration in progress**, not production-ready.
- T3 Kubernetes is **skeleton only**, not deployable.
- The Vagrant sandbox is **known broken** and not a validation path.
- `/Rtmp` is 400 GB ext4 local disk — it is not a RAM disk, not `/tmp`,
  and not infinite.

## 5. Key Technical Decisions

| Decision | Rationale | Constraint |
|---|---|---|
| **OpenBLAS serial** (not pthread) | `libopenblas0-pthread` causes SIGSEGV under R's fork+thread model | HC-R-BLAS |
| **Local R library disk** (`/var/lib/biome-Rlibs`) | Eliminates NFS lookup storms when PSOCK workers call `library()` simultaneously | v12.4 |
| **Modular Rprofile_site fragments** | Each safety guard is an independent, versioned fragment; sysadmin can disable individual guards without rebuilding | HC-14 |
| **cgroup user slices** | Per-user CPU/memory limits enforced by the kernel; no userspace quota daemon needed | v12.0 |
| **PSOCK-only parallel** | Fork is unsafe with spatial packages (terra, sf, raster); the platform auto-reroutes `mclapply` to PSOCK when these are loaded | HC-13 |
| **OAuth2 proxy** (not Basic Auth) | Eliminates credential handling in JavaScript; delegates auth to a dedicated, audited proxy | v7.6.0 migration |
| **BIND MOUNTS only** (no named Docker volumes) | Host filesystem is the authoritative storage; no Docker-managed volume lifecycle surprises | HC-06 |

## 6. Component Interaction — Authentication Flow

```
User → Nginx (TLS) → OAuth2 Proxy → Identity Provider (OIDC)
                          │
                          ▼ (authenticated)
                   RStudio Server (PAM via SSSD → AD)
                          │
                          ▼
                   User session with cgroup limits
                   Rprofile_site guards active
                   /Rtmp scratch available
                   NFS home mounted
```

1. User navigates to `https://biome-calc.example.com/`.
2. Nginx serves the static portal page.
3. User clicks "RStudio" → Nginx proxies to OAuth2 Proxy.
4. OAuth2 Proxy redirects to the OIDC identity provider for login.
5. On successful authentication, OAuth2 Proxy sets session cookie and
   proxies to RStudio Server.
6. RStudio Server authenticates the user via PAM (SSSD → AD).
7. RStudio session starts with cgroup limits, Rprofile_site guards,
   and `/Rtmp` scratch available.

## 7. Storage Layout

| Path | Type | Purpose | Size |
|------|------|---------|------|
| `/nfs/home/<user>/` | NFS | Persistent home directories | Shared NAS |
| `/var/lib/biome-Rlibs/<user>/<R-ver>/` | Local ext4 | Per-user compiled R packages | ~80 GB per VM |
| `/Rtmp/` | Local ext4 | Session scratch / temporary files | 400 GB |
| `/media/r_projects/<project>/` | NFS | Shared project data | Shared NAS |
| `/tmp/` | tmpfs (small) | System temporary files (NOT for R scratch) | RAM-based |

## 8. Future Directions

See [`docs/FUTURE_MIGRATION.md`](../FUTURE_MIGRATION.md) for the full roadmap.
Key items under evaluation (not yet adopted):

- **Positron** — Posit's next-generation IDE. Currently desktop-only;
  Positron Pro (server) requires Posit Workbench, which is not in scope.
- **Open OnDemand** — HPC portal framework. Under evaluation as potential
  replacement for the custom Nginx portal.
- **Keycloak / Authentik** — Full IAM solutions. The current OAuth2 proxy
  - AD model may evolve toward a dedicated IdP.
- **Kubernetes (T3)** — Deferred until T2 Docker Compose is stable and
  validated in production.

## 9. Official References

| Component | Official Documentation | Key Points for BIOME-CALC |
|---|---|---|
| RStudio Server | [Posit RStudio Server Admin Guide](https://docs.posit.co/ide/server-pro/) | PAM authentication, session limits, `rsession.conf` configuration |
| oauth2-proxy | [oauth2-proxy Documentation](https://oauth2-proxy.github.io/oauth2-proxy/) | OIDC provider configuration, cookie settings, `--upstream` for RStudio |
| Nginx | [nginx documentation](https://nginx.org/en/docs/) | Reverse proxy, WebSocket proxying, `proxy_read_timeout` for long-lived sessions |
| SSSD | [SSSD Documentation](https://sssd.io/docs/) | AD integration, PAM/NSS, `enumerate=false` default and its implications |
| systemd cgroups | [Control Group Interfaces](https://www.freedesktop.org/wiki/Software/systemd/ControlGroupInterface/) | `MemoryHigh`, `MemoryMax`, `CPUQuota` for per-user slices |
| R `parallel` | [Parallel R](https://stat.ethz.ch/R-manual/R-devel/library/parallel/doc/parallel.pdf) | PSOCK vs FORK semantics, `detectCores()`, `mclapply()` fork safety |

---

*Authoritative source: [`docs/architecture/SYSTEM_OVERVIEW.md`](https://github.com/gsamuele78/R-studioConf/blob/main/docs/architecture/SYSTEM_OVERVIEW.md) — last verified 2026-06-08.*
