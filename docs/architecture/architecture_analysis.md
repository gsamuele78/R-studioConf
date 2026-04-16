# Comparative Architecture Analysis: Legacy Workstation vs. BIOME-CALC Proxmox/NFS

Deep technical analysis comparing the manual "Luchetti workstation" RStudio deployment with the automated BIOME-CALC infrastructure on Proxmox VMs with TrueNAS/NFS + Nextcloud storage.

---

## 1. Architectural Paradigms

### 1.1 The Legacy Architecture (Standalone Workstation — "Luchetti")

From `00_Installazione_workstation_luchetti.txt`:

| Aspect | Implementation | Risk |
|:---|:---|:---|
| **OS install** | Manual `apt install r-base`, manual `gdebi rstudio-server-*.deb` | Not reproducible; drift across rebuilds |
| **BLAS library** | `openblas-pthread` via `update-alternatives` (hardcoded) | `SIGSEGV` in `blas_thread_server` when ≥2 users run `solve()`/`crossprod()` simultaneously — see [rstudio/rstudio#7031](https://github.com/rstudio/rstudio/issues/7031) |
| **Thread tuning** | `OPENBLAS_NUM_THREADS=32`, `OMP_NUM_THREADS=32` hardcoded in `/etc/environment` | 5 users × 32 threads = 160 threads on 72-core machine → CPU thrashing, context-switch storm |
| **Temp storage** | Default OS `/tmp` (often RAM-backed `tmpfs`) | NIMBLE `compileNimble()` → `cc1plus` can spike 8–15 GB temp; fills tmpfs → kernel OOM kill |
| **User data** | `/BIGDATA1/r_projects/$USER` on local VM disk | Hardware failure = total data loss; no snapshots |
| **Authentication** | Manual `pam_mkhomedir.so` insertion, manual `sssd.conf` edits | Non-idempotent; copy-paste errors across machines |
| **R packages** | Manual `install.packages()` from CRAN source | 30+ minutes to compile `sf`/`terra`; requires manual `libgdal-dev` setup |
| **bspm** | Installed but `bspm::enable()` only; no sudo config for domain users | Fails silently in RStudio web console (no polkit agent) |
| **Network edge** | Direct RStudio port 8787, `www-address=137.204.142.248` | No TLS, no reverse proxy, no session iframe isolation |
| **User .Renviron** | `config_rstudio.sh` in `/etc/profile.d/` overrides `HOME=$RUSERPATH` | Breaks `~` expansion; conflicts with NFS home patterns |

### 1.2 The New Architecture (BIOME-CALC v10.0 — Proxmox + NFS)

| Aspect | Implementation | Benefit |
|:---|:---|:---|
| **Provisioning** | `50_setup_nodes.sh` — 12 idempotent steps, menu-driven, `--dry-run` mode | Full node rebuild in ~15 min; version-controlled via git |
| **BLAS** | `libopenblas0-serial` pinned; `libopenblas0-pthread` actively removed | Eliminates SIGSEGV entirely; serial BLAS has no internal thread pool |
| **Thread tuning** | Dynamic: `update_resources()` runs per-callback, reads `/proc` for active `rsession` count, divides vCores fairly | Single user gets ≤16 threads (MAX_BLAS_THREADS cap); 5 users get ~6 each |
| **CORETYPE** | Auto-detected at 3 levels: boot (`/etc/profile.d/biome-coretype.sh`), rsession spawn (`rsession-profile`), R init (`Rprofile_site.R`) | Survives Proxmox live-migration across heterogeneous CPU hosts without `SIGILL` |
| **Temp storage** | Dedicated 400GB virtio disk at `/Rtmp` (ext4, not tmpfs, not NFS, not OS `/tmp`) | Zero RAM consumed; NIMBLE/TMB compile scratch isolated from OS; daily cleanup via `systemd-tmpfiles` |
| **User data** | NFS share from TrueNAS at `/nfs/home/<user>` | ZFS snapshots, RAID, enterprise backup; VM is disposable |
| **Nextcloud** | Iframe wrapper via `31_setup_web_portal.sh` + NGINX reverse proxy | Drag-and-drop file upload from laptop → appears in R session instantly |
| **Authentication** | Auto-detected SSSD/Samba backends (`detect_auth_backend()`) with scripted PAM + nsswitch | Reproducible; supports both AD backends; pamtester validation built-in |
| **R packages** | `bspm` with `r2u` binary repo + `sudoers.d/99-bspm-domain-users` | `install.packages("sf")` → 5 seconds (binary); no compilation needed |
| **Memory guards** | `solve()`, `dist()`, `outer()`, `expand.grid()`, `distm()` intercepted with RAM-aware thresholds | Warns and auto-reduces threads before OOM; never crashes silently |
| **Orphan cleanup** | `cleanup_r_orphans.sh` via cron (hourly), with 8-level deep process ancestry check | Kills stale `Rscript`/`future`/`PSOCK` workers left by crashed sessions; emails user with fix suggestion |
| **Network edge** | NGINX with TLS (Let's Encrypt or self-signed), PAM auth, iframe wrappers, `www-root-path=/rstudio-inner` | SSL, origin checks, secure cookies, SameSite=None for iframe |

---

## 2. Feature Comparison Matrix

| Feature | Legacy (Luchetti) | BIOME-CALC v10.0 | User Impact |
|:---|:---|:---|:---|
| **OOM Crashes** | No protection; kernel OOM killer fires randomly | `solve()` guard checks `MemAvailable`, drops threads to 2, warns user | Session survives; colleagues unaffected |
| **BLAS Crash (SIGSEGV)** | `openblas-pthread` ← crashes on multi-user | `openblas-serial` ← no internal thread pool | Zero SIGSEGV on `crossprod()` — ever |
| **CPU Fairness** | 32 static threads per user (race condition) | Dynamic: `floor(vCores / active_users)` capped at 16 | Slower solo; stable with 20 users simultaneously |
| **Temp Disk vs RAM** | Default tmpfs (eats RAM) | 400GB local disk at `/Rtmp` | Full VM RAM available for R; NIMBLE compiles freely |
| **NIMBLE/MCMC** | Crashes if tmpfs fills, no reboot safety | Compilation to NFS `$HOME/.nimble_compile/session_<PID>`; scratch on `/Rtmp` | 16-hour MCMC chains survive VM reboots |
| **File Access** | SSH/SFTP only | Nextcloud web UI + NFS mount | Drag-and-drop CSVs from laptop into R session |
| **Package Install** | Source compile (30 min for `sf`) | Binary via `bspm`/`r2u` (5 seconds) | Researchers self-serve without sysadmin help |
| **CPU Migration** | `SIGILL` if VM moves to different CPU host | 3-level CORETYPE auto-detection (profile.d + rsession-profile + R) | Transparent Proxmox live-migration |
| **Session Logging** | None | Per-user syslog to `/var/log/biome-log/r_biome_system.log` | Sysadmin can trace who ran what, when |
| **Orphan Processes** | Accumulate indefinitely | Hourly cron with 8-level ancestry check + SIGTERM/SIGKILL escalation | No zombie `Rscript` workers consuming RAM for days |
| **AI Assistant** | None | `ask_ai("How do I run a PERMANOVA?")` via local Ollama (cgroup-limited 24GB) | Researchers get instant R help without internet search |
| **save()/load()** | Standard (no checks) | `biome_save_session()` checks disk quota, `biome_load_session()` checks RAM | Prevents silent "save to full disk" or "load into OOM" |
| **Diagnostics** | Manual | `status()`, `biome_plot_budget()`, `biome_tutorial()`, `biome_help()` | Users self-diagnose before emailing sysadmin |

---

## 3. Deep Dive: Critical Optimizations

### 3.1 The OpenBLAS Pthread Collision (SIGSEGV)

> [!CAUTION]
> **This is the #1 stability fix.** The legacy server uses `openblas-pthread`, whose internal thread pool collides with RStudio rsession's own pthreads. During `solve()` or `crossprod()`, the OpenBLAS `blas_thread_server` routine and RStudio's event loop race on the same thread IDs → `SIGSEGV`.

**BIOME-CALC fix chain** (defense in depth):
1. **apt-level**: `setup_nodes_dependencies()` installs `libopenblas-serial-dev`, removes `libopenblas0-pthread`
2. **alternatives-level**: `setup_nodes_blas()` pins BLAS/LAPACK alternatives to serial paths
3. **env-level**: `Renviron.site` sets `OPENBLAS_NUM_THREADS=1` (belt-and-suspenders; serial ignores it, but if someone reinstalls pthread, this prevents the crash)
4. **R-level**: `Rprofile_site.R` Section -1.5 detects pthread at runtime, forces `OPENBLAS_NUM_THREADS=1`, emits `CRITICAL` warning with fix instructions

### 3.2 Memory Guards (OOM Prevention)

The `Rprofile_site.R.template` intercepts 6 base R functions at load time:

| Function | Guard Behavior | Threshold |
|:---|:---|:---|
| `solve(a)` | If `a` > 5000×5000 and workspace > 80% RAM: drops BLAS threads to 2, `on.exit` restores | 2.06× matrix size |
| `dist(x)` | If lower-triangle > 5 GB and > 50% RAM: warns OOM, suggests sparse methods | O(n²) check |
| `outer(X, Y)` | If result > 5 GB and > 50% RAM: warns, suggests chunking | n1 × n2 |
| `expand.grid(...)` | If rows × cols > 2 GB and > 50% RAM: warns, suggests `data.table::CJ()` | Exponential product |
| `geosphere::distm()` | If result > 5 GB: warns; if > 50% RAM: hard warning with NNGP alternatives | O(n²) matrix |
| `doParallel::registerDoParallel()` | Wraps with `biome_make_cluster()`, forces 1 BLAS thread per worker | Prevents thread fan-out |

### 3.3 Storage Architecture (Decoupled Compute/Data)

```
┌─────────────────────┐     ┌────────────────────────┐
│   Proxmox VM (node) │     │   TrueNAS Server       │
│                     │     │                        │
│  /Rtmp   (400GB     │     │  /nfs/home/<user>      │
│   local virtio)     │     │   = ZFS pool           │
│                     │ NFS │   = daily snapshots    │
│  /nfs/home/<user> ──┼─────┤   = RAID-Z2            │
│   (mount)           │     │                        │
│                     │     │  Nextcloud ──────────── │──→ Web UI
│  RStudio Server     │     │   (WebDAV bridge)      │
│  NGINX (TLS)        │     └────────────────────────┘
│  Ollama AI          │
└─────────────────────┘
```

> [!IMPORTANT]
> **Key insight for users**: If the VM dies, your data is safe on TrueNAS. We can rebuild the VM from `50_setup_nodes.sh` in 15 minutes. On the old server, if the disk failed, everything was gone.

### 3.4 NIMBLE/TMB Compilation Safety

NIMBLE's `compileNimble()` triggers: `rsession → R → system2(sh) → make → sh → g++ → cc1plus` (6-7 process levels). This creates two risks:
1. **Temp spike**: `cc1plus` writes 8-15 GB of temporary `.o` files
2. **Long runtime**: Multi-chain MCMC can run 16+ hours

**BIOME-CALC solution**:
- Compilation outputs → NFS `$HOME/.nimble_compile/session_<PID>` (survives reboots)
- Compiler scratch (`.o` files) → `/Rtmp` automatically (fast local disk)
- Thread cap: `max(2, min(4, bt))` per chain (4 chains × 4 threads = 16 = VM max)
- Orphan cleanup: 8-level ancestry check (`MAX_PARENT_DEPTH=8`) recognizes `R CMD → make → g++ → cc1plus` chain as valid, not orphan

---

## 4. Pros and Cons

### Pros

1. **Multi-Tenant Stability**: Memory guards + dynamic threads + orphan cleanup = no single user can crash the server for others
2. **Data Integrity**: NFS + TrueNAS ZFS = hardware failure on compute nodes = zero data loss
3. **Reproducible Infrastructure**: Everything is git-versioned bash scripts; new node in 15 min
4. **Self-Service**: Binary packages (5 sec install), Nextcloud file upload, AI assistant, diagnostic tools
5. **Live Migration**: 3-level CORETYPE detection → transparent Proxmox migration without SIGILL
6. **Audit Trail**: Per-section syslogs, 87KB R audit script, deployment summary emails

### Cons

1. **Perceived Performance Drop**: "My script used 32 cores!" — yes, because with 5 concurrent users, 32×5=160 threads caused thrashing. Now you get `floor(32/5)` ≈ 6 fair-share threads, but they actually complete faster (no thrashing)
2. **Warning Messages**: Guards emit yellow warnings (`BIOME-CALC: dist() on 20,000 obs (~1.5 GB)`). These are intentional — they prevent silent OOM kills
3. **Environment Rigidity**: Users cannot set `OMP_NUM_THREADS` in `.Renviron` (it gets stripped by `setup_nodes_migrate_users()`). This is by design — static values conflict with dynamic allocation
4. **NFS Latency**: Small-file I/O on NFS is slower than local disk. BIOME-CALC mitigates this by routing all temp I/O to local `/Rtmp`, but `install.packages()` writes to NFS library paths
5. **Complexity**: The `Rprofile_site.R` is 1,458 lines (74KB). A bug here affects every user. Mitigation: template integrity self-check, syntax validation on deploy, backup+rollback in `setup_nodes_config_files()`

---

## 5. Missing Features / Improvement Opportunities

| Gap | Severity | Recommendation |
|:---|:---|:---|
| **No per-user cgroup limits** | Medium | Proxmox can't cgroup individual rsessions. Consider `systemd-run --slice` per user via PAM hook |
| **No GPU passthrough** | Low | Current VMs are CPU-only (`CUDA_VISIBLE_DEVICES=-1`). If deep learning demand grows, add GPU slice |
| **No Renv/Conda isolation** | Medium | System-wide packages work for 80% of users; heavy reproducibility users need per-project `renv`. Document workflow |
| **NFS write-back cache** | Low | TrueNAS default sync writes are safe but slow. For large terra raster writes, consider `async` mount option with UPS |
