# R-studioConf — Agent Context Document

> **Version:** 3.0.0 | **Updated:** 2026-04-23 | **Paradigm:** Pessimistic System Engineering
> **Operator:** JFS — IT Officer (Funzionario Tecnico Informatico), BiGeA, Università di Bologna
> **Audience:** Any AI coding assistant (Claude, Gemini, Copilot, Cursor, Antigravity, etc.)

**Project constraints win over general best-practices. If in doubt, fail safe — not optimistic.**

---

## 1. Project Identity

**What:** Production-grade Infrastructure-as-Code (IaC) system providing a secure, high-performance RStudio data science portal for ecological research.

**Stack (all Dockerized, single-host Compose):**
- `rstudio-sssd` / `rstudio-samba` — RStudio Server integrated with Active Directory via SSSD or Samba/Winbind.
- `nginx-portal` — Frontend reverse proxy + custom glassmorphism landing page.
- `oauth2-proxy` — OIDC sidecar (central university IdP).
- `ollama-ai` — Local LLM inference engine (private, airgapped).
- `telemetry-api` — Host + container metrics Python API.
- `docker-socket-proxy` — Safe Docker API exposure (read-only, TCP).

**Who:** BIOME research group (Biodiversity & MacroEcology), BiGeA dept., Università di Bologna.
End users: researchers doing NIMBLE MCMC, geospatial analysis, large-scale matrix statistics.

**Operator context:**
- Single sysadmin (LPIC-3). No babysitting capacity.
- Network: constrained university uplink. RFC-1918 private inter-host network.
- AD domain: `*.personale.dir.unibo.it`.
- Branding: Unibo Red `#C80E0F`, Inter/system-ui fonts, glassmorphism UI — local assets only, zero CDN.
- Funded projects: PNRR LifeWatch-Plus, PON LifeWatch-Plus, Life4Pollinators.

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
│ │ rstudio-sssd │◄───┤  ollama-ai   │    │ Telemetry  │ │
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
|---------|-------|------|------|------------|
| `rstudio-sssd` | `rstudio-botanical-sssd` | Primary R workspace (SSSD backend) | Custom/Root | No |
| `rstudio-samba` | `rstudio-botanical-samba` | Alternate R workspace (Samba backend) | Custom/Root | No |
| `nginx-portal` | `botanical-portal-nginx` | Frontend UI and reverse proxy | Nginx | No |
| `oauth2-proxy` | `quay.io/oauth2-proxy/oauth2-proxy:v7.6.0` | OIDC Sidecar | Non-root | Yes |
| `docker-socket-proxy` | `tecnativa/docker-socket-proxy:0.3.0` | Safe Docker API (read-only TCP) | root | No |
| `telemetry-api` | `botanical-telemetry-api` | Host metrics API | Non-root | Yes |
| `ollama-ai` | `botanical-ai-ollama` | Local LLM inference engine | Non-root | No |

> **HC-07 Local Image Exception:** `botanical-*` and `rstudio-botanical-*` images use `:latest` by convention because they are **locally built** and never pulled from a registry. This is an intentional exception to HC-07. Only externally sourced images (oauth2-proxy, docker-socket-proxy) must have pinned semver tags.

---

## 3. Invariants (MUST NEVER Be Violated)

These 12 hard constraints are the non-negotiable engineering rules.

### 3.1 Pessimistic System Engineering
- **HC-01:** Every container MUST have `deploy.resources.limits` for both `memory` and `cpus`. Prevents OOM cascades on shared hosts.
- **HC-03:** All scripts MUST begin with `set -euo pipefail`. Fail-fast on undefined vars, pipe failures, any error.
- **HC-10:** Deploy scripts MUST `exit 1` if `chown`/permission setup fails. Prevents cryptic Permission Denied errors buried in container logs.
- **HC-11:** No external CDN calls for fonts or CSS in UI themes. Airgap/Zero-Trust requirement.
- **HC-12:** Use `jq` for JSON manipulation — never `sed`/`awk` on JSON. `sed` breaks on special chars; no schema validation.

### 3.2 Storage
- **HC-02:** BIND MOUNTS only — zero named Docker volumes. Named volumes are opaque, hard to backup, impossible to inspect or rsync.
- **Tmpfs:** RStudio requires tmpfs for `/tmp` (e.g., `size=16G`). Rapidly churning temp files must not fill host root.
- **`/Rtmp` disk:** 400GB ext4 local disk at `/Rtmp` (validated by `50_setup_nodes.sh` step 5). Replaced old tmpfs for NIMBLE MCMC and big-data matrix workloads. Do NOT reference `/tmp` for large R temp storage — use `/Rtmp`.

### 3.3 Secrets & Dependencies
- **HC-04:** Passwords MUST be written to files — never passed as CLI arguments. Prevents leakage in `ps aux`, `/proc/*/cmdline`, `docker inspect`, shell history.
- **HC-06:** All Dockerfiles bake dependencies at build time — no runtime package installation. Eliminates failures if package mirrors are offline.
- **HC-07:** Pin ALL external upstream image versions — no `:latest` tag for registry-sourced images.
- **HC-08:** `.env` files are NEVER committed to git. Contains passwords, tokens, fingerprints.

### 3.4 Networking & Security
- **HC-09:** The Telemetry/Renewer container NEVER mounts `/var/run/docker.sock` directly. Full host control = container escape vector. Use `docker-socket-proxy`.
- **HC-05:** PostgreSQL ports are NEVER exposed to the host. DB is internal-only.
- Containers operate in `network_mode: "host"` to interface with host-level SSSD/Samba pipes, while dropping bounding capabilities (`SYS_CHROOT`).

---

## 4. Anti-Patterns (Agent Failure Modes)

| Anti-Pattern | Correct Approach |
|---|---|
| Creating named Docker volumes | Host bind mounts only (`./data:/path`) |
| `apk add` / `apt-get install` in entrypoints | Bake into Dockerfile at build time |
| Omitting `deploy.resources.limits` | Always bound CPU and RAM |
| Using `:latest` tag for **registry** images | Pin exact semver (local botanical images exempt) |
| Hardcoding IPs in compose files | Use `.env` variables |
| Using `sed` for JSON manipulation | Use `jq` |
| Bypassing `docker-socket-proxy` | Any API reading uses the proxy on TCP |
| Referencing `/tmp` for large R temp storage | Use `/Rtmp` (400GB ext4 disk) |
| Using `source .env` in scripts | `grep "^VAR=" .env \| cut -d= -f2- \| tr -d '"'` |
| Hardcoded absolute paths in scripts | `SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"` |
| Suggesting Rust/biome_core_rust integration | Dormant — not applied (see §8) |
| Validating changes against sandbox | Sandbox BROKEN (see §7) — use user/researcher testing |

---

## 5. Script Inventory

### 5.1 Host Bootstrap (`scripts/` — run by sysadmin on host, interactive OK)

| Script | Purpose |
|--------|---------|
| `01_optimize_system.sh` | CPU governor, open-files limits, kernel tuning |
| `02_configure_time_sync.sh` | Chrony/NTP sync |
| `03_install_secure_access.sh` | SSH hardening, fail2ban |
| `10_join_domain_sssd.sh` | Active Directory join via SSSD |
| `11_join_domain_samba.sh` | Active Directory join via Samba/Winbind |
| `12_lib_kerberos_setup.sh` | Kerberos keytab setup library |
| `15_setup_nginx_cleanup.sh` | Nginx port/socket cleanup pre-install |
| `20_configure_rstudio.sh` | Bind mounts, container paths, RProfile assembly |
| `21_helper_rstudio_version.sh` | Queries installed RStudio Server version |
| `30_install_nginx.sh` | Deploys portal reverse proxy |
| `31_optimize_system.sh` | Post-install performance tuning (CPU/mem) |
| `31_setup_web_portal.sh` | Deploys glassmorphism web UI |
| `32_setup_letsencrypt.sh` | TLS cert automation (Let's Encrypt / ACME) |
| `40_install_telemetry.sh` | System metrics API bootstrap |
| `50_setup_nodes.sh` | **BIOME-CALC NODE SETUP** — deploys OpenBLAS-serial, Rprofile.site, Renviron.site, `/Rtmp` disk validation, kernel tuning, R packages, Python geospatial venv. Depends: `lib/common_utils.sh`, `config/setup_nodes.vars.conf`, `templates/Rprofile_site.R.template` |

### 5.2 Operational / Diagnostic Scripts

| Script | Purpose |
|--------|---------|
| `99_audit_r_environment.sh` | Deploys parameterized audit R script from `templates/00_audit_v28.R.template`, runs via Rscript |
| `99_health_check.sh` | Stack operational validation (all containers healthy) |
| `99_postmortem_forensics.sh` | Automated crash data collection for R session failures; designed for sysadmins supporting non-technical researchers |
| `99_troubleshoot_env.sh` | Aggregates logs, system state, active integration tests; includes `--rprofile` subsystem check for BIOME-CALC Rprofile v11.0 + audit v28 |
| `99_verify_domain_join.sh` | Validates AD/SSSD/Samba domain join state |
| `test_rstudio_login.sh` | Curl-based RStudio plaintext login test (interactive — reads password from stdin) |
| `ttyd_login_wrapper.sh` | Wraps ttyd terminal login for web-based shell access |
| `update_nginx_templates.sh` | Regenerates Nginx config files from templates using current variables |
| `legacy_sysadmin_stress_test.R` | Advanced R memory/worker parallel load test |

### 5.3 Root-Level Orchestrators

| File | Purpose |
|------|---------|
| `r_env_manager.sh` | R Environment Manager v2.0.0 — orchestrates complete R environment setup on Debian: Java/rJava config, package management, system integration. Self-contained. Idempotent. |

### 5.4 Script Dependency Chain

```
50_setup_nodes.sh
  ├── lib/common_utils.sh
  ├── config/setup_nodes.vars.conf
  ├── templates/Rprofile_site.R.template → /etc/R/Rprofile.site (on target nodes)
  └── r_env_manager.sh configure_java_for_r()
        └── /etc/biome-calc/profile.d/   (modular R config loader, if deployed)
              └── RStudio container (sources on session start)

configure_rstudio.sh → .env → docker-deploy/docker-compose.yml → RStudio Container
```

**Before modifying what a script READS or PRODUCES, trace the full chain above.**

---

## 6. R Runtime Hardening (added 2026-Q1/Q2)

These architectural decisions are not obvious from code alone. Agents MUST respect them.

### 6.1 BLAS: OpenBLAS Serial (not pthread)
- **Installed:** `libopenblas0-serial` (enforced by `50_setup_nodes.sh`).
- **Removed:** `libopenblas0-pthread` (causes `SIGSEGV` crashes when RStudio's rsession threads + OpenBLAS pthread threads collide).
- **BLAS/LAPACK alternatives** set to serial variant via `update-alternatives`.
- **Detection:** `/etc/profile.d/biome-coretype.sh` auto-detects CPU and sets `OPENBLAS_CORETYPE`.
- **Do NOT suggest** re-installing pthread variant or changing BLAS backend.

### 6.2 Storage: `/Rtmp` Local Disk (not tmpfs)
- **Mount:** `/Rtmp` — 400GB ext4 local disk, high-performance mount options.
- **Purpose:** NIMBLE MCMC compilation artifacts, large matrix temp files, R `tempdir()` override.
- **Replaces:** the old `/tmp` tmpfs approach (16G RAM-based), which caused OOM on heavy workloads.
- **Validated by:** `50_setup_nodes.sh` Step 5 (`TMP_DISK_GB=400` check).
- **Config templates** must reference `/Rtmp`, NOT `/tmp`, for large R temp storage.

### 6.3 Modular R Configuration (`profile.d/`)
- **Location:** `/etc/biome-calc/profile.d/` on target nodes.
- **Pattern:** A thin `Rprofile.site` loader sources all `.R` files in `profile.d/` with error isolation.
- **Deployed by:** `50_setup_nodes.sh` via `templates/Rprofile_site.R.template`.
- **Audit coverage:** `templates/00_audit_v28.R.template` validates the full modular structure.

### 6.4 Session Resilience (NGINX)
- NGINX configured with extended `proxy_read_timeout`, `client_max_body_size`, and `proxy_buffer_size` to handle large RStudio session payloads (sessions can be 100MB+ for NIMBLE workloads).
- Error code 4 (browser OOM) is a known failure mode for massive workspace payloads — see forensics script `99_postmortem_forensics.sh`.

### 6.5 Memory Guards
- R session memory guards set pessimistically: `options(future.globals.maxSize = ...)` capped, garbage collection triggered proactively.
- NIMBLE parallelism uses explicit core count from `parallel::detectCores(logical=FALSE)`.

---

## 7. Compose Format Rules

- **Compose v2:** NO `version:` key.
- **Command:** `docker compose` (space) — NOT `docker-compose` (hyphen).
- **Required sections for every stateful service:** `deploy.resources.limits`, `healthcheck`, `logging` (json-file with `&default-logging` anchor), `labels` (watchtower enable), `depends_on` (with `condition:`).

---

## 8. Testing Protocol

> [!WARNING]
> **Sandbox status: KNOWN BROKEN — do not use for validation.**
> The Vagrant/libvirt sandbox (`sandbox/Vagrantfile`) mirrors the production topology
> but is currently non-operational. Do NOT reference sandbox steps as a validation path.

**Active testing protocol:**
1. **User testing** — sysadmin validates changes directly against the staging/production host.
2. **Researcher testing** — BIOME researchers validate R session stability, NIMBLE MCMC runs, and geospatial workflows after deployment.
3. **Script:** `99_health_check.sh` — validates stack operational status.
4. **Script:** `99_audit_r_environment.sh` — deploys and runs the full R environment audit.
5. **Script:** `99_postmortem_forensics.sh` — run after any crash to collect diagnostic data.

---

## 9. Known Dormant Components (Do NOT activate without explicit instruction)

| Component | Location | Status | Reason |
|-----------|----------|--------|--------|
| Rust core library | `src/biome_core_rust/` | **DORMANT** | Evaluated but does not measurably speed up R code loading. Not deployed. |
| Kubernetes deployment | `kubernetes-deploy/` | **DORMANT** | Standalone Docker Compose is the production path. |
| `Infra-Iam-PKI.backup/` | repo root | **OFF LIMITS** | Backup directory. Do not read, modify, or reference. |

---

## 10. Anti-Patterns Specific to This Codebase

```
□ Do NOT suggest alternatives to the chosen stack (RStudio, SSSD, Samba, Nginx, Ollama)
□ Do NOT suggest tmpfs for large R temp storage — use /Rtmp
□ Do NOT suggest libopenblas0-pthread — use libopenblas0-serial
□ Do NOT reference Infra-Iam-PKI.backup
□ Do NOT activate src/biome_core_rust — it is dormant
□ Do NOT use sandbox for validation — it is broken
□ Do NOT output partial files ("add this to your script") — always output complete files
□ Do NOT use version: key in Docker Compose files
□ Do NOT mount /var/run/docker.sock except in docker-socket-proxy
□ Do NOT use named Docker volumes
□ Do NOT use :latest for registry-sourced images
```

---

*This document governs all agent operations in R-studioConf. Version 3.0.0 — 2026-04-23.*
