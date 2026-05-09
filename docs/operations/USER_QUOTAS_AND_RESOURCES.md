<!-- docs/operations/USER_QUOTAS_AND_RESOURCES.md -->
# BIOME-CALC — Resource Optimization & User Quotas

> **Tier:** T1 (host) — authoritative.
> **Audience:** sysadmin / operators. End-user view → `docs/user_guides/User_guide.md`.
> **Cross-refs:** `docs/architecture/architecture_analysis.md` (cgroup model),
> `docs/architecture/USER_CONTRACT.md` (HC-13: adapt the system, not the user script),
> `docs/operations/TROUBLESHOOTING.md`, `docs/operations/DIAGNOSTICS_INDEX.md`.

This document explains **how user resources are bounded on BIOME-CALC** —
RAM, CPU, scratch disk, BLAS threads — and how to grant temporary
exemptions without breaking portability of user code.

---

## 0. Hard Rules (HC-13)

1. **Never edit a user `.R` script** to enforce limits. All enforcement
   lives in `Renviron.site`, `Rprofile_site.d/*.R`, systemd cgroups, and
   PAM limits.
2. **`detectCores()` is wrapped** to return cgroup fair-share, not 128.
   Users write `parallel::makeCluster(detectCores() - 1)` portably.
3. **Scratch goes to `/Rtmp` (400 GB local ext4)**. Never `/tmp` (tmpfs).
4. **BLAS/OMP threads = 1 by default**. Set inside the system profile —
   not in user scripts.
5. **OOM-kill is preferred over swap thrashing.** `systemd-oomd` enabled
   on Ubuntu 24.04 LTS.

---

## 1. Parquet Sync — Transparent Dataset Acceleration

The system maintains a nightly mirror that converts massive CSV / FST
datasets into Parquet alongside the original.

- **Transparency:** users keep writing `read.csv()` / `data.table::fread()`.
- **Path swap:** if `<file>.csv` has a sibling `<file>.parquet` with a
  newer mtime, the system profile redirects the read transparently.
- **Implementation:** `Rprofile_site.d/40_parquet_swap.R` (loads
  `arrow::read_parquet`).
- **Conversion daemon:** `scripts/tools/converter_final.R` (cron, nightly).

User-facing speedup: 5–10× on first-touch loads; 0× cost when no Parquet
twin exists.

---

## 2. RAM Fair-Share (`unix::rlimit_as`)

BIOME-CALC partitions the 450 GB RAM pool by **live user count**
(measured from `who | wc -l` at session start) and applies an address-space
limit to each R session.

| Live users | Per-user soft cap | Mechanism |
|------------|-------------------|-----------|
| 1          | 360 GB            | `unix::rlimit_as()` |
| 2          | 200 GB            | recomputed on session start |
| 3–4        | 110 GB            | systemd cgroup `MemoryHigh=` |
| ≥ 5        | 80 GB             | with OOM-killer fallback |

- **Set by:** `Rprofile_site.d/20_resource_quota.R` at session boot.
- **Enforced by Linux:** systemd user slice `user-<UID>.slice` with
  `MemoryHigh=` and `MemoryMax=` (see
  `templates/biome-calc-user.slice.d/quota.conf`).
- **Forced GC:** a `taskCallback` triggers `gc()` automatically when RSS
  crosses 80 % of the soft cap, before the kernel does.

### 2.1 Admin override (isolated critical job)

Run the override **inside the user's R session** (e.g. via a power-user
ttyd console), never inside their `.R` script:

```R
# disable the auto-quota recalculation callback
removeTaskCallback(1)

# raise the per-process limit to 300 GB
unix::rlimit_as(300 * 1e9)
```

Cgroup ceiling still applies — to lift it, edit the slice override:

```bash
sudo systemctl edit user-$(id -u <username>).slice
# under [Slice]: MemoryHigh=350G  MemoryMax=400G
sudo systemctl daemon-reload
```

Document every override in `/var/log/biome-calc/quota_overrides.log`.

---

## 3. CPU Fair-Share & BLAS Threads

| Layer       | Mechanism                                              | File / origin                         |
|-------------|--------------------------------------------------------|---------------------------------------|
| **CPU pool**   | systemd `CPUQuota=` per user-slice                  | `templates/biome-calc-user.slice.d/`  |
| **`detectCores()`** | wrapped to return `min(quota, host_cores)`     | `Rprofile_site.d/10_core_quota.R`     |
| **BLAS**       | `RhpcBLASctl::blas_set_num_threads(1)` at boot      | `Rprofile_site.d/15_blas_serial.R`    |
| **OpenMP**     | `OMP_NUM_THREADS=1` in `Renviron.site`              | `templates/Renviron.template`         |
| **terra**      | `terraOptions(threads = 1, memfrac = 0.6)`          | `Rprofile_site.d/35_terra_safe.R`     |
| **CMDSTANR**   | `cmdstanr_output_dir` to `/Rtmp/cmdstan-<PID>`      | `Rprofile_site.d/50_cmdstanr_local.R` |

**Why threads=1 by default:** users routinely call `parallel::makeCluster()`
on top of multi-threaded BLAS. Without the cap, a 64-worker × 16-thread BLAS
explosion saturates the host in seconds. Workers inherit the cap; if a user
genuinely needs 8 threads in a serial section they email the admin.

---

## 4. Scratch Storage — `/Rtmp` (NOT `/tmp`)

| Path     | Backend           | Size   | Default for                               |
|----------|-------------------|--------|-------------------------------------------|
| `/tmp`   | tmpfs (RAM)       | ~16 GB | OS only — **NEVER** large R temporaries   |
| `/Rtmp`  | local ext4 (NVMe) | 400 GB | `tempdir()`, `terra`, `cmdstanr`, NIMBLE  |
| `~/`     | NFS               | quota  | persistent user files                     |

- **Set by:** `templates/Renviron.template` → `TMPDIR=/Rtmp` (re-rendered
  per session by `Rprofile_site.d/05_tempdir.R` to give a unique
  `/Rtmp/Rtmp<PID>`).
- **Cleanup:** `systemd-tmpfiles` daily prunes `/Rtmp/Rtmp*` older than
  48 h *and* not held open by any process.
- **Legacy env:** `BIOME_FORCE_NFS_TMP` is a **no-op** since v12.0; do
  not document it. `templates/Rprofile_site_optimized.R.template` and
  `templates/old/` still mention it (LEGACY).

---

## 5. systemd-oomd / PSI Policy

Ubuntu 24.04 LTS ships `systemd-oomd` enabled by default. BIOME-CALC
keeps it on.

- Triggers on **memory pressure (PSI)** *or* **swap saturation**, not on
  absolute RSS.
- Kills the **single worst offender** in the user slice — typically the
  runaway `R` worker, never the RStudio Server parent.
- Configured in `/etc/systemd/oomd.conf.d/biome.conf`:

  ```ini
  [OOM]
  DefaultMemoryPressureLimit=60%
  DefaultMemoryPressureDurationSec=30s
  ```

- Sysadmin observability:

  ```bash
  journalctl -u systemd-oomd.service --since today
  oomctl     # current pressure
  ```

This is **preferred over OOM-killer + swap** because swap thrashing
freezes the whole host for all users; PSI-based killing isolates the
blast radius to one process.

---

## 6. Quotas Summary Table

| Resource     | Default cap         | Mechanism              | Override path                              |
|--------------|---------------------|------------------------|--------------------------------------------|
| RAM (R proc) | 80–360 GB (dynamic) | `rlimit_as` + cgroup   | `removeTaskCallback(1)` + `systemctl edit` |
| CPU          | fair-share          | `CPUQuota=`            | `systemctl edit user-<UID>.slice`          |
| Cores reported| cgroup share       | `detectCores()` wrapper| n/a — wrapper respects cgroup              |
| BLAS threads | 1                   | `blas_set_num_threads` | per-session `RhpcBLASctl::blas_set_num_threads(N)` |
| OMP threads  | 1                   | `OMP_NUM_THREADS=1`    | per-session `Sys.setenv(OMP_NUM_THREADS=N)`|
| Scratch      | `/Rtmp` 400 GB      | `TMPDIR=/Rtmp`         | n/a — symlink, do not redirect             |
| Disk (home)  | NFS quota           | LDAP/NFS               | quota tool on file server                  |

---

## 7. Cross-References

- **Architecture:** `docs/architecture/architecture_analysis.md` — full
  cgroup model, CORETYPE policy, threading rationale.
- **User contract:** `docs/architecture/USER_CONTRACT.md` — formal
  HC-13 ("adapt the system, not the user script").
- **End-user view:** `docs/user_guides/User_guide.md`,
  `docs/user_guides/BOTANIST_CHEATSHEET.md`.
- **Triage:** `docs/operations/TROUBLESHOOTING.md` § OOM,
  `docs/operations/DIAGNOSTICS_INDEX.md` (`99_diagnose_user_script.sh`).
- **R runtime modules:** `templates/Rprofile_site.d/README.md`.
