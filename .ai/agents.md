# R-studioConf — Agent Context Document

> **Version:** 2.0.0 | **Last Updated:** 2026-03-12
> **Maintainer:** JFS — IT Officer (Funzionario Tecnico Informatico), BiGeA, Università di Bologna
> **Audience:** Any AI coding assistant (Claude, Gemini, Copilot, Cursor, etc.)

---

## 0. How to Use This File

This document is the **single source of truth** for any AI agent working on this codebase. Before writing or modifying ANY file, you MUST:

1. Read this entire document.
2. Identify which subsystem (RStudio Backend, Nginx Portal, Telemetry, AI, Sandbox) your task touches.
3. Apply ALL relevant constraints from Section 4 (Invariants).
4. Validate your output against Section 5 (Anti-Patterns) before presenting it.

**If a constraint in this document conflicts with a general best-practice, the constraint in this document wins.** This project is governed by Pessimistic System Engineering — we assume failure, not success.

---

## 1. Project Identity

### 1.1 What This Is

A production-grade **Infrastructure-as-Code (IaC)** system providing a secure, high-performance RStudio data science portal:

- **RStudio Backends:** Dockerized RStudio Server environments integrated with Active Directory via SSSD or Samba (Winbind).
- **Nginx Portal:** A frontend reverse proxy that serves a custom glassmorphism landing page and routes to RStudio.
- **OIDC Authentication:** Integration with central Identity Providers via `oauth2-proxy`.
- **Telemetry API:** A Python-based API to monitor host and container metrics.
- **AI Engine:** Integrated Ollama instance (`botanical-ai-ollama`) for local, private machine learning inference inside RStudio.
- **Automation Scripts:** Shell toolkit for host bootstrapping, SSSD/Samba domain joining, resource optimization, and telemetry.
- **Sandbox:** A Vagrant/libvirt environment (`rstudio-host`) that safely mirrors production topology for testing.

### 1.2 Who This Is For

The BIOME research group (Biodiversity & MacroEcology) at the Department of Biological, Geological and Environmental Sciences (BiGeA), University of Bologna. End users are researchers doing geospatial analysis, machine learning, and statistical ecology.

### 1.3 Organizational Context

- **Operator:** Single sysadmin (LPIC-3 certified).
- **Network:** Constrained university uplink. Servers communicate via private RFC-1918 networks.
- **Active Directory:** `*.personale.dir.unibo.it` for user federation.
- **Branding:** All user-facing UIs must use the Unibo Red palette (`#C80E0F`), Inter/system-ui fonts, and glassmorphism styling matching `bigea.unibo.it`.

---

## 2. Architecture

### 2.1 Production Topology (Single Node / Docker Compose)

```
┌────────────────────────────────────────────────────────┐
│                   R-studioConf Host                    │
│                                                        │
│ ┌──────────────┐    ┌──────────────┐    ┌────────────┐ │
│ │ Nginx Portal │◄───┤ oauth2-proxy │◄───┤ Remote IdP │ │
│ │ (Front Door) │    │ (OIDC Auth)  │    └────────────┘ │
│ └──────┬───────┘    └──────────────┘                   │
│        │                                               │
│ ┌──────▼───────┐    ┌──────────────┐    ┌────────────┐ │
│ │ rstudio-sssd │◄───┤  ollama-ai   │◄───┤ Telemetry  │ │
│ │ (or samba)   │    │ (Local LLM)  │    │ API        │ │
│ └──────┬───────┘    └──────────────┘    └─────┬──────┘ │
│        │                                      │        │
│ ┌──────▼───────┐    ┌──────────────┐          │        │
│ │ Host Active  │    │ docker-socket│◄─────────┘        │
│ │ Directory    │    │ -proxy       │                   │
│ └──────────────┘    └──────────────┘                   │
└────────────────────────────────────────────────────────┘
```

### 2.2 Container Inventory (`docker-deploy/docker-compose.yml`)

| Service | Image | Role | User | Ephemeral? |
|-------|-------|------|------|------------|
| `rstudio-sssd` | `rstudio-botanical-sssd` | Primary R workspace (SSSD backend) | Custom/Root | No |
| `rstudio-samba` | `rstudio-botanical-samba` | Alternate R workspace (Samba backend) | Custom/Root | No |
| `nginx-portal` | `botanical-portal-nginx` | Frontend UI and reverse proxy | Nginx | No |
| `oauth2-proxy` | `quay.io/oauth2-proxy/...` | OIDC Sidecar | Non-root | Yes |
| `docker-socket-proxy` | `tecnativa/docker-socket-proxy` | Safely expose Docker API reading | root | No |
| `telemetry-api` | `botanical-telemetry-api` | Host metrics API | Non-root | Yes |
| `ollama-ai` | `botanical-ai-ollama` | Local LLM inference engine | Non-root | No |

---

## 3. Invariants (MUST NEVER Be Violated)

These are non-negotiable constraints inherited from the `project.yml` hard rules:

### 3.1 Pessimistic System Engineering
- **Every container MUST have `deploy.resources.limits` for both `memory` and `cpus`**.
- **All scripts MUST begin with `set -euo pipefail`**.
- **Deploy scripts MUST exit 1 if chown/permission setup fails**.
- **No external CDN calls for fonts or CSS in UI themes** (Zero-Trust/Airgap requirement).
- **Use `jq` for JSON manipulation — never `sed`/`awk` on JSON**.

### 3.2 Storage
- **BIND MOUNTS only — zero named Docker volumes**. Volumes are opaque; bind mounts are auditable and rsync-friendly.
- **Tmpfs configuration for RStudio:** RStudio requires rapidly churning temporary directories mappings (e.g. `/tmp:rw,size=16G`).

### 3.3 Secrets & Dependencies
- **Passwords MUST be written to files — never passed as CLI arguments**.
- **All Dockerfiles bake dependencies at build time — no runtime package installation**.
- **Pin ALL upstream image versions — no `:latest` tag**.
- **`.env` files are NEVER committed to git**.

### 3.4 Networking & Security
- **The Telemetry/Renewer container NEVER mounts `/var/run/docker.sock` directly**. Must use `docker-socket-proxy`.
- Containers operate in `network_mode: "host"` primarily to interface smoothly with host-level SSSD/Samba pipes, while still dropping bounding capabilities (`SYS_CHROOT`).

---

## 4. Anti-Patterns (Common Agent Mistakes)

| Anti-Pattern | Correct Approach |
|---|---|
| Creating named Docker volumes | Use Host Bind Mounts (`./data:/path`) |
| `apk add` or `apt-get install` in entrypoints | Bake into Dockerfile at build time |
| Omitting `deploy.resources.limits` | Always bound CPU and RAM |
| Using `latest` tag for upstream images | Pin exact versions in Compose / Dockerfiles |
| Hardcoding IPs in compose files | Use `.env` variables |
| Using `sed` for JSON manipulation | Use `jq` |
| Bypassing `docker-socket-proxy` | Any API reading uses the proxy on TCP |

---

## 5. Script Inventory

### 5.1 Host & Integration Scripts (`scripts/`)
- `01_optimize_system.sh`: CPU governor, open files limits, tuning.
- `02_configure_time_sync.sh`: Chrony/NTP sync.
- `10_join_domain_sssd.sh`: Active Directory join via SSSD.
- `11_join_domain_samba.sh`: Active Directory join via Samba/Winbind.
- `20_configure_rstudio.sh`: Bind mounts, container paths, RProfile assembly.
- `30_install_nginx.sh`: Deploys portal proxy.
- `40_install_telemetry.sh`: System metrics API bootstrap.
- `99_health_check.sh`: Stack operational validation.
- `legacy_sysadmin_stress_test.R`: Advanced R memory/worker parallel test.

---

## 6. Sandbox Testing Protocol

The Sandbox (`sandbox/Vagrantfile`) provides a 1:1 test bed for the R-studioConf containers utilizing a dedicated VM (`rstudio-host` at 192.168.56.40).

- To validate changes:
  1. `cd sandbox`
  2. `vagrant up` (provisions the host, installs docker, syncs configs)
  3. Tests execute against `.env.sandbox` variables.

**Testing constraints:** Do not attempt to alter the core `docker-deploy/docker-compose.yml` to fit the sandbox; the sandbox operates on the same production compose, injected with mock variables from `.env.sandbox`.

---
*This document governs all agent operations working in R-studioConf.*
