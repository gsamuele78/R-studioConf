<!-- docs/architecture/architecture_analysis.md -->
---
title: "BIOME-CALC Architecture Analysis"
audience: architect
status: current
tier: T1
source_path: docs/architecture/architecture_analysis.md
last_verified: 2026-10-06
---

# BIOME-CALC Architecture Analysis

## 1. Current architectural position

BIOME-CALC is not one uniform deployment. It has three code surfaces with
different maturity:

- **T1 host:** authoritative and continuously fixed.
- **T2 Docker:** migration in progress and required to mirror T1 except for
  recorded `tier_deltas`.
- **T3 Kubernetes:** skeleton, not ready for deployment.

The main architectural strength is the T1 R runtime and storage separation.
The main weakness is the T1 web authentication design, which still forwards
AD credentials from browser JavaScript and differs materially from the
optional T2 OIDC design.

## 2. Legacy workstation context

The original version of this document compared T1 with a manual workstation
installation called “Luchetti.” The current repository does not contain an
authoritative deployment definition for that workstation, so exact historical
claims about its IP address, core count, package-install duration, disk layout,
or failure rate are not repeated as facts.

**Unverified:** the historical workstation reportedly used manually installed
RStudio Server, `libopenblas0-pthread`, fixed thread counts, direct port 8787,
and OS-default temporary storage. Those claims require the external historical
installation record and were not used to define the current architecture.

## 3. Verified T1 decisions

| Area | Active implementation | Operational effect |
|---|---|---|
| Provisioning | `init.sh` → `r_env_manager.sh` → numbered scripts | Version-controlled, menu-driven host configuration |
| AD identity | SSSD **or** Samba/Winbind | PAM and NSS integration without mixing both backends |
| Web edge | Nginx TLS on 80/443 | RStudio, ttyd, Nextcloud proxy, telemetry, and static portal share one gateway |
| RStudio | OSS on `127.0.0.1:8787`, PAM auth | Backend is not directly network-facing when deployed as configured |
| Terminal | ttyd on `127.0.0.1:2222`, Nginx PAM | Header-based identity is bounded by loopback and gateway authentication |
| BLAS | `libopenblas0-serial` | Avoids the pthread BLAS/rsession crash pattern |
| R temporary storage | `/Rtmp`, 400 GiB local ext4 | Keeps compiler and package scratch off RAM-backed `/tmp` and NFS |
| Persistent homes | `/nfs/home/<user>` on TrueNAS SCALE | Compute nodes do not own the canonical user home data |
| User R packages | `/var/lib/biome-Rlibs/<user>/<R-ver>/` first, NFS fallback | Reduces NFS lookup storms during parallel worker startup |
| Project archive | `/mnt/ProjectStorage` CIFS | Separate project/archive surface |
| Resource control | systemd `user-.slice` | Per-user memory, task, CPU-weight, and I/O-weight enforcement |
| R runtime | Rprofile 12.11 dispatcher plus 14 fragments | System-side guards without rewriting portable user scripts |
| Telemetry | FastAPI on 8000 plus node exporter on 9100 | Aggregated status and metrics through Nginx |
| Local AI | Optional Ollama on loopback 11434 | Local `ask_ai()` support when installed and running |

## 4. Storage and compute separation

```text
Compute VM
  /Rtmp                              local 400 GiB ext4, disposable scratch
  /var/lib/biome-Rlibs/<u>/<R-ver>   local compiled R packages
  /nfs/home/<u>                      NFSv4.2 persistent home
  /mnt/ProjectStorage                CIFS project/archive storage

TrueNAS SCALE
  zpool/home                         NFS home dataset
  per-user ZFS quotas                server-side capacity enforcement
```

The architecture does not claim zero data loss. NFS homes are outside the
compute VM and protected by TrueNAS storage controls, but actual snapshot,
replication, and backup schedules are not encoded in this repository.

**Unverified:** snapshot frequency, RAID layout, off-site backup, and recovery
point objectives for the TrueNAS server.

## 5. R runtime design

### 5.1 Kernel enforcement

`config/setup_nodes.vars.conf` defines:

- `MemoryHigh=300G` and `MemoryMax=400G` per user slice;
- `MemorySwapMax=4G`;
- `TasksMax=4096`;
- `CPUWeight=100` and `IOWeight=100` for users;
- `MemoryMin=16G`, `MemoryLow=24G`, and `CPUWeight=200` for system services.

This is weighted CPU sharing, not a fixed `floor(vCores / active_users)` quota.
One user can consume available CPU when the node is otherwise idle; weights
determine competition under load.

### 5.2 Rprofile 12.11

The dispatcher and fragments implement:

- local R-library bootstrap (`04`);
- cgroup-aware core discovery (`05`, `20`);
- PSOCK cluster creation (`30`);
- compile and scratch routing (`35`);
- wrapper installation and opt-in install blocking (`40`, `42`);
- memory guards (`45`);
- package hooks including cgroup-aware `terraOptions` (`50`);
- fork-to-PSOCK `mclapply` routing with package and global-object replication
  (`52`);
- `mc.cores` clamping (`55`);
- guarded `setwd` (`60`);
- persistent diagnostic and helper tools (`70`, `80`).

NIMBLE does not compile to `$HOME/.nimble_compile`. R starts with
`TMPDIR=/Rtmp`, so each process receives its own local R temporary directory.
Fragment 35 also provides explicit compile-routing helpers. Stan output and
Rcpp caches are routed to local per-session paths where the active code defines
supported controls.

### 5.3 Failure boundary

The runtime is designed to fail open for most optional guards: fragment errors
are logged and the loader continues. The `setwd` guard deliberately fails in
batch mode for a missing path. The install blocker is dormant by default.

Kernel cgroups remain the final resource boundary. R warnings and wrappers do
not guarantee that a process cannot exhaust its user slice.

## 6. Active web architecture

The active T1 web path is:

```text
Browser → Nginx TLS
  ├── portal Basic/PAM credential check
  ├── browser POST to RStudio auth-do-sign-in → RStudio PAM
  ├── browser credential seeding → PAM-protected ttyd
  └── browser POST to configured Nextcloud login endpoint
```

This differs from the architecture described in the root README and generated
agent context, which summarize the target stack as OIDC via oauth2-proxy. The
code shows oauth2-proxy only in T2's optional `oidc` profile. T1 has no
oauth2-proxy service or Nginx `auth_request` configuration.

The Nextcloud wrapper, proxy locations, discovery redirects, and portal tile
are active source, not archived templates.

**Unverified:** whether the site currently operates a compatible Nextcloud
backend and whether every T1 node has ttyd enabled in production.

## 7. T2 analysis

T2 has useful controls:

- exact upstream image pins;
- CPU and memory limits on every service;
- bind mounts only;
- optional SSSD or Samba RStudio profile;
- optional oauth2-proxy `oidc` profile;
- Step-CA root trust bootstrap;
- docker-socket-proxy v0.5.0 published only on loopback;
- health checks and bounded logging.

It is not a current replacement for T1 because `TD-T2-01` remains open: the
container runtime uses a monolithic Rprofile snapshot and audit v27 rather than
T1's v12.11 fragments and audit v28. T2 also intentionally omits bspm/r2u
(`TD-T2-05`).

The T2 RStudio containers mount `/tmp` as tmpfs. That is a container-tier
implementation detail, not permission to move T1 R temporary storage away
from `/Rtmp`.

## 8. T3 analysis

The 2026-10-01 back-port added NetworkPolicies and pinned custom images, but T3
remains `SKELETON_NOT_READY`. `.ai/project.yml` still records identity,
storage, PKI rotation, and deployment gaps. `kubernetes-deploy/configmaps.yaml`
also contains development values that do not match T1's active R runtime.

T3 must not be described as dormant production infrastructure or as a validated
HA cluster.

## 9. Current risks and contradictions

| Finding | Impact | Evidence |
|---|---|---|
| Browser-side AD password handling remains active | Password reaches JavaScript, URL construction, and multiple login POSTs | `portal_index.html.template` |
| oauth2-proxy is absent from T1 | Architecture summaries can overstate OIDC coverage | no T1 script/template match; T2 Compose profile only |
| T1 portal loads Google Fonts | Violates no-CDN hard constraint | `portal_index.html.template` |
| `20_configure_rstudio.sh` can append NFS temp settings | Can override `/Rtmp` if unsafe menu actions are run | `configure_rstudio.vars.conf`, repo `CHANGELOG.md` |
| `20_configure_rstudio.sh` and ttyd wrapper lack active strict mode | Violates HC-03 | script line 2 in each file |
| T2 runtime lags T1 | Container testing does not validate current fragment behavior | `TD-T2-01` |
| Per-user quota is server-side | `df` can look healthy while writes fail with `EDQUOT` | `99_troubleshoot_env.sh`, troubleshooting runbook |

## 10. Architecture verdict

T1's R runtime, cgroup controls, local scratch, and local package-library design
match the platform's heavy spatial and Bayesian workloads. Those controls are
implemented and testable from the repository.

The web authentication surface is older and more fragile than the runtime. It
should be documented as Basic/PAM plus credential forwarding until T1 actually
adopts a different flow. T2's optional OIDC profile is not evidence of a T1
migration.

No current repository evidence supports claims of high availability,
session roaming, automatic user-to-node routing, zero data loss, or a
production-ready Kubernetes deployment.

## 11. Verification sources

- `.ai/project.yml`
- `config/setup_nodes.vars.conf`
- `config/configure_rstudio.vars.conf`
- `scripts/03_install_secure_access.sh`
- `scripts/20_configure_rstudio.sh`
- `scripts/30_install_nginx.sh`
- `scripts/40_install_telemetry.sh`
- `scripts/50_setup_nodes.sh`
- `templates/Renviron.template`
- `templates/Rprofile_site.R.template`
- `templates/Rprofile_site.d/*.R.template`
- `templates/nginx_proxy_location.conf.template`
- `templates/portal_index.html.template`
- `docker-deploy/docker-compose.yml`
- `CHANGELOG.md`

---

*Last verified against active repository code: 2026-10-06.*
