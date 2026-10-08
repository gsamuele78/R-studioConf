<!-- docs/architecture/SYSTEM_OVERVIEW.md -->
---
title: "BIOME-CALC System Architecture Overview"
audience: architect
status: current
tier: T1
source_path: docs/architecture/SYSTEM_OVERVIEW.md
last_verified: 2026-10-06
sharepoint_section: Sysadmin / Operator Hub
---

# BIOME-CALC System Architecture Overview

## 1. Scope and deployment tiers

BIOME-CALC is a shared RStudio Server OSS platform for ecological and botanical
workloads. This document describes the repository state on 2026-10-06. The
host deployment is authoritative; container and Kubernetes material is not a
statement of production readiness.

| Tier | Repository surface | Status | Entry point |
|---|---|---|---|
| T1 host | `init.sh`, `r_env_manager.sh`, `scripts/`, `lib/`, `config/`, `templates/` | `AUTHORITATIVE_CONTINUOUSLY_FIXED` | `init.sh` → `r_env_manager.sh` → numbered scripts |
| T2 Docker | `docker-deploy/` | `MIGRATION_IN_PROGRESS` | `docker-deploy/deploy.sh` → `docker compose` |
| T3 Kubernetes | `kubernetes-deploy/` | `SKELETON_NOT_READY` | `kubernetes-deploy/scripts/deploy_k8s.sh` |

Bugs are fixed in T1 first and then ported T1 → T2 → T3. Recorded exceptions
are in `.ai/project.yml` under `tier_deltas`.

## 2. Active T1 topology

```text
Browser
  │ HTTPS :443
  ▼
Nginx on the host
  ├── /                         static portal
  ├── /rstudio/                RStudio wrapper
  ├── /rstudio-inner/          127.0.0.1:8787 (RStudio Server OSS)
  ├── /terminal/               ttyd wrapper, PAM-protected
  ├── /terminal-inner/         127.0.0.1:2222 (ttyd), PAM-protected
  ├── /files/                  Nextcloud wrapper
  ├── /files-inner/            configured external Nextcloud target
  ├── /api/, /metrics          127.0.0.1:8000 (telemetry API)
  ├── /monitoring/             127.0.0.1:8000, LAN/VPN allow-list
  └── /monitoring/node/        127.0.0.1:9100 (node exporter), LAN/VPN allow-list

RStudio / ttyd / Nginx PAM
  └── system PAM and NSS
        └── exactly one AD backend: SSSD or Samba/Winbind

R sessions
  ├── $HOME under /nfs/home/<user>
  ├── compiled user libraries under /var/lib/biome-Rlibs/<user>/<R-ver>/
  ├── temporary files under /Rtmp
  └── systemd user-.slice resource controls
```

T1 does **not** configure oauth2-proxy. The repository contains oauth2-proxy
v7.6.0-alpine as the optional T2 Compose profile `oidc`, listening on host
loopback port 4180. The active T1 templates contain no `auth_request` or
oauth2-proxy upstream.

## 3. T1 web and authentication flow

### 3.1 Portal authentication

The active portal is not an OIDC-only portal. `portal_index.html.template`
contains an AD credential modal. The browser builds an HTTP Basic
`Authorization` header and calls `/auth-check`; Nginx validates the request
with `ngx_http_auth_pam_module` and PAM service `nginx`.

After a successful check, portal JavaScript currently:

1. POSTs the username, password, and a client-generated CSRF token to
   `/rstudio-inner/auth-do-sign-in`.
2. POSTs the credentials to the configured Nextcloud login path.
3. Rewrites the terminal tile with a credential-bearing URL so the browser can
   seed HTTP Basic authentication for `/terminal/`.

This is the active implementation, not a recommended future design. Its risks
are recorded in [SECURITY_MODEL.md](SECURITY_MODEL.md).

### 3.2 RStudio Server OSS

`scripts/20_configure_rstudio.sh` configures RStudio Server to:

- listen on `127.0.0.1:8787`;
- authenticate through `/etc/pam.d/rstudio`, which includes the system
  `common-auth`, `common-account`, `common-password`, and `common-session`
  stacks;
- use `www-root-path=/rstudio-inner` after Nginx integration;
- set `www-frame-origin=same`, `www-same-site=none`,
  `www-enable-origin-check=1`, `auth-encrypt-password=0`, and
  `auth-cookies-force-secure=1`.

Nginx terminates TLS, supports WebSocket upgrades, disables response and
request buffering for the RStudio proxy, permits uploads up to 10 GiB, and
uses the R session timeout from `config/configure_rstudio.vars.conf` (currently
2,880 minutes) for proxy read and send timeouts.

### 3.3 ttyd terminal

`scripts/03_install_secure_access.sh` installs ttyd and deploys
`templates/ttyd.service.override.template`. The service binds to
`127.0.0.1:2222`, uses `/terminal-inner` as its base path, trusts the
`X-Forwarded-User` header, and starts `/usr/local/bin/ttyd_login_wrapper.sh`.
Nginx protects both `/terminal/` and `/terminal-inner/` with PAM before setting
that header. The loopback bind is therefore part of the trust boundary.

### 3.4 Nextcloud proxy

The T1 Nginx and portal templates still deploy `/files/` and
`/files-inner/`, including WebDAV discovery redirects. The backend URL is the
operator-supplied `NEXTCLOUD_TARGET_URL` from `config/install_nginx.vars.conf`.

**Unverified:** the repository cannot prove that a Nextcloud backend is
currently deployed or reachable at the site-specific target.

### 3.5 Telemetry and Ollama

`scripts/40_install_telemetry.sh` installs the host telemetry API as
`botanical-telemetry.service` on port 8000 and node exporter on port 9100.
Nginx exposes aggregated status endpoints under `/api/`, a `/metrics` endpoint,
and LAN/VPN-restricted monitoring paths. These endpoints are not all
internal-only: `/api/` and `/metrics` are present in the public TLS vhost and
are rate-limited.

`scripts/50_setup_nodes.sh` can install Ollama unless `SKIP_OLLAMA=true`.
The configured API is `127.0.0.1:11434`, the service memory limit is 24 GiB,
and Rprofile tools include `ask_ai()` when the service is available.

## 4. Identity

T1 supports one AD integration backend per host:

- `scripts/10_join_domain_sssd.sh` for SSSD; or
- `scripts/11_join_domain_samba.sh` for Samba/Winbind.

The backends provide PAM authentication and NSS user/group resolution for
RStudio, Nginx, ttyd login, and SSH. `scripts/12_lib_kerberos_setup.sh`
manages Kerberos setup. Running both AD join paths on the same host violates
the project XOR invariant.

## 5. Storage

| Path | Backing | Active use |
|---|---|---|
| `/nfs/home/<user>/` | TrueNAS SCALE dataset `zpool/home`, NFSv4.2, `sec=sys` | Persistent home, scripts, results, and fallback user R library |
| `/var/lib/biome-Rlibs/<user>/<R-ver>/` | Local ext4, root filesystem or optional dedicated disk | Primary per-user compiled R packages when `ENABLE_R_LIBS_LOCAL=true` |
| `/Rtmp/` | Dedicated 400 GiB local ext4 disk per VM | `TMPDIR`, `TMP`, `TEMP`, `R_TEMPDIR`, package and compiler scratch |
| `/mnt/ProjectStorage/` | CIFS/SMB | Project archive and shared project storage |
| `/tmp/` | OS temporary directory | Small system and diagnostic files only; not R temporary storage |

TrueNAS enforces per-user ZFS quotas. The client-side storage diagnostic writes
and fsyncs 1 MiB so it can detect `EDQUOT`; free space reported by `df` does not
prove that a user has quota remaining.

No active T1 R configuration should point R temporary files at `/tmp` or
`/nfs/home/Rtmp`. `templates/Renviron.template` sets all four R temporary
variables to `/Rtmp`. `config/configure_rstudio.vars.conf` still contains the
stale value `GLOBAL_RSTUDIO_TMP_DIR=/nfs/home/Rtmp`; the repo changelog warns
operators not to run the affected `20_configure_rstudio.sh` menu actions on a
populated node because they can override the authoritative `50_setup_nodes.sh`
deployment.

## 6. R runtime

The active host profile is version **12.11**. `scripts/50_setup_nodes.sh`
renders `/etc/R/Rprofile.site`, `/etc/R/Renviron.site`, and the following
fragments into `/etc/R/Rprofile_site.d/` in lexical order:

```text
04_user_lib_bootstrap     05_thread_guard
20_cgroup_reader          30_psock_factory
35_compile_routing        40_wrapper_installer
42_install_block          45_memory_guards
50_pkg_hooks              52_mclapply_guard
55_options_guard          60_safe_setwd
70_persistent_tools       80_tools_ext
```

The main runtime controls are:

- `libopenblas0-serial`; `libopenblas0-pthread` is prohibited because it has
  caused RStudio `rsession` crashes.
- systemd `user-.slice` controls: `MemoryHigh=300G`, `MemoryMax=400G`,
  `MemorySwapMax=4G`, `TasksMax=4096`, `CPUWeight=100`, and `IOWeight=100`.
- cgroup-aware `parallel::detectCores()` and `options(mc.cores)` guards.
- PSOCK cluster construction and automatic `mclapply()` rerouting when
  fork-unsafe packages are loaded.
- NIMBLE/TMB/Stan and package temporary work on `/Rtmp`.
- memory guards around `solve`, `dist`, `outer`, `expand.grid`, and cluster
  creation.
- `terra` temporary routing to `/Rtmp`, default `todisk=TRUE`, and cgroup-aware
  memory limits.
- an install-block fragment that is shipped **off by default** and can be
  armed with `BIOME_FORCE_INSTALL_BLOCK=1` or a template change and redeploy.

Fragment failures are isolated and logged; PSOCK workers use a reduced startup
path. The HC-13 diagnostic ladder distinguishes OS/NFS, minimal R, fragments,
the full system profile, and user startup files before attributing a failure to
user code.

## 7. T2 and T3 differences

T2 is not a byte-for-byte runtime match for T1. The recorded open delta
`TD-T2-01` states that T2 still ships a monolithic Rprofile snapshot and audit
v27 instead of T1's v12.11 fragments and audit v28. Other active T2 differences
include:

- optional oauth2-proxy v7.6.0-alpine on port 4180;
- Step-CA trust bootstrap in `rstudio-init`;
- RStudio containers using `/tmp` tmpfs;
- no bspm/r2u in RStudio images (`TD-T2-05`);
- docker-socket-proxy v0.5.0 published only on `127.0.0.1:2375`.

T3 remains `SKELETON_NOT_READY`. Its manifests and ConfigMaps are development
material and contain unresolved parity and site-configuration issues; they do
not define the active platform.

## 8. Known active contradictions

- T1 portal authentication is still Basic/PAM plus browser-side credential
  forwarding; T2 alone contains the OIDC sidecar.
- The active portal template calls Google Fonts, contrary to HC-11's no-CDN
  rule.
- `scripts/20_configure_rstudio.sh` and `scripts/ttyd_login_wrapper.sh` still
  have strict mode commented out, contrary to HC-03.
- T1 still deploys ttyd and Nextcloud proxy support; they are not legacy-only
  components in this checkout.
- The sandbox is known broken and is not a validation path.

## 9. Source map

- Web edge: `scripts/30_install_nginx.sh`, `scripts/31_setup_web_portal.sh`,
  `templates/nginx_site.conf.template`,
  `templates/nginx_proxy_location.conf.template`,
  `templates/portal_index.html.template`.
- RStudio and PAM: `scripts/20_configure_rstudio.sh`,
  `config/configure_rstudio.vars.conf`.
- ttyd: `scripts/03_install_secure_access.sh`,
  `templates/ttyd.service.override.template`, `scripts/ttyd_login_wrapper.sh`.
- Runtime: `scripts/50_setup_nodes.sh`, `config/setup_nodes.vars.conf`,
  `templates/Renviron.template`, `templates/Rprofile_site.R.template`,
  `templates/Rprofile_site.d/`.
- Tier status and deltas: `.ai/project.yml`, `docker-deploy/docker-compose.yml`,
  `kubernetes-deploy/configmaps.yaml`.

---

*Authoritative source: [`docs/architecture/SYSTEM_OVERVIEW.md`](https://github.com/gsamuele78/R-studioConf/blob/main/docs/architecture/SYSTEM_OVERVIEW.md) — last verified 2026-10-06. The Markdown file in git is the source of truth.*
