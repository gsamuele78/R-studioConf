<!-- docs/operations/USER_QUOTAS_AND_RESOURCES.md -->
---
title: "BIOME-CALC User Quotas and Resources"
audience: operator
status: current
tier: T1
source_path: docs/operations/USER_QUOTAS_AND_RESOURCES.md
last_verified: 2026-10-07
---

# User Quotas and Resources

## Enforced T1 limits

`config/setup_nodes.vars.conf` is the source for the user-slice values deployed by `scripts/50_setup_nodes.sh`:

| Resource | Current configured value | Mechanism |
|---|---:|---|
| Soft memory pressure point | `MemoryHigh=300G` | `/etc/systemd/system/user-.slice.d/50-biome-limits.conf` |
| Catastrophic memory ceiling | `MemoryMax=400G` | same user slice; kill is contained to that user's slice |
| Swap ceiling | `MemorySwapMax=4G` | same user slice |
| Process/task ceiling | `TasksMax=4096` | same user slice |
| CPU | `CPUWeight=100` | proportional fair share; no hard CPU quota |
| I/O | `IOWeight=100` | proportional share |
| System protection | `MemoryMin=16G`, `MemoryLow=24G`, `CPUWeight=200` | `system.slice` drop-in |
| Ollama | `MemoryMax=24G`, `MemorySwapMax=0`, `CPUWeight=80` | service drop-ins |

These values are sized for the configured 32-vCPU, 512-GB host model. Verify effective values; do not infer them from config alone:

```bash
sudo bash scripts/50_setup_nodes.sh --verify
systemctl cat user-.slice
systemctl show user-$(id -u <user>).slice -p MemoryHigh -p MemoryMax -p MemorySwapMax -p TasksMax -p CPUWeight -p IOWeight
cat /sys/fs/cgroup/user.slice/user-$(id -u <user>).slice/memory.events
```

## CPU and R threads

- `05_thread_guard.R` makes `parallel::detectCores()` cgroup-aware.
- `55_options_guard.R` clamps `options(mc.cores)`.
- `52_mclapply_guard.R` reroutes fork-unsafe terra/sf/GDAL work to PSOCK.
- `Renviron.site` supplies thread and glibc allocator caps; `30_psock_factory.R` propagates them to PSOCK workers.
- OpenBLAS must be the serial package/alternative.

```bash
sudo bash scripts/tools/check_processor_threads.sh
sudo bash scripts/99_check_rprofile_health.sh --user <user>
sudo -u <user> R --no-save -e 'cat(parallel::detectCores(logical=FALSE), "\n"); print(Sys.getenv(c("OMP_NUM_THREADS","OPENBLAS_NUM_THREADS","MALLOC_ARENA_MAX")))'
```

## RAM/OOM diagnosis

A user seeing exit 137, a disconnected session or `cannot allocate vector` may have reached cgroup pressure/ceiling or host pressure.

```bash
journalctl -k --since '-2 hours' | grep -iE 'oom|killed process'
journalctl -u systemd-oomd --since '-2 hours'
systemctl status user-$(id -u <user>).slice --no-pager
cat /sys/fs/cgroup/user.slice/user-$(id -u <user>).slice/memory.events
```

Do not "fix" this by enabling unbounded swap or editing the user's script. Determine whether the configured limit is wrong for the approved workload, then change `config/setup_nodes.vars.conf`, redeploy option 8 (cgroups), and verify.

## Scratch storage

`/Rtmp` is local ext4 scratch, configured as 400 GB and mode `1777`. It is not a RAM disk and must not be NFS or `/tmp`.

```bash
findmnt -no SOURCE,FSTYPE,OPTIONS /Rtmp
stat -c '%a %U:%G %n' /Rtmp
df -hT /Rtmp
sudo bash scripts/tools/bigger_usage_reports.sh
```

`TMP_WARN_THRESHOLD_PCT=80` is advisory. Full-disk recovery is covered in `TROUBLESHOOTING.md`.

## Local R libraries

With `ENABLE_R_LIBS_LOCAL=true`, `Renviron.site` sets:

```text
/var/lib/biome-Rlibs/%u/%v:${HOME}/R/x86_64-pc-linux-gnu-library/%v
```

`04_user_lib_bootstrap.R` creates and prepends the local directory at R startup. The deploy-time warmup accepts UID ≥1000 except 65534, so high-UID AD users are supported.

```bash
sudo -u <user> R --no-save -e 'cat(.libPaths(), sep="\n")'
ls -ld /var/lib/biome-Rlibs/<user>/*
sudo bash scripts/99_check_user_renviron_overrides.sh
```

If a stale deployed login script re-adds `R_LIBS_USER`, use `fix_login_script_rlibs_inplace.sh` before cleanup. Note the current open defect: `99_check_user_renviron_overrides.sh --fix --commit` can lose ownership if `chown/chmod --reference` fails on NFS. Verify numeric owner after every committed cleanup.

## Persistent home quota

Homes are on TrueNAS SCALE dataset `zpool/home`, mounted with NFSv4.2 `sec=sys` at `/nfs/home`. ZFS server-side `userquota@<uid>` is independent of client `df`; Linux `quota` does not prove remaining ZFS allowance.

```bash
sudo bash scripts/99_troubleshoot_env.sh --storage --test-user <user>
id <user>
```

The bundled test writes 1 MiB and fsyncs it. `EDQUOT` requires server-side `zfs userspace`/`zfs get` by numeric UID. Keep the Troubleshooting §4.4 anchor unchanged when linking it.

### Optional user-visible quota cache (Rprofile v12.11)

`ENABLE_HOME_QUOTA_VIEW=true` deploys step 11g: a root cron fetches the exact
read-only `zfs userspace` output over a restricted SSH key every five minutes
and writes local cache files under `/var/lib/biome-quota` (0711). Each `<uid>`
file is 0400 and owned by that uid; users cannot list or read one another's
files. The cache is local ext4, not NFS, so NFS ACL inheritance and a full user
quota cannot block the update.

User surfaces: `status()` (`Home (~)` line), `biome_quota()` in R,
`biome-quota` in ttyd and a login warning at `QUOTA_WARN_PCT` (90% default).
T2 mounts the same host cache read-only. Step-by-step setup for TrueNAS
SCALE 25.04 and several Ubuntu 24.04 nodes:
[`HOME_QUOTA_VIEW_SETUP.md`](HOME_QUOTA_VIEW_SETUP.md).

```bash
sudo bash scripts/50_setup_nodes.sh     # option QH, or full deploy
sudo -u <user> biome-quota
sudo stat -c '%U %G %a %n' /var/lib/biome-quota/$(id -u <user>)
```

## Project storage

The observed `/mnt/ProjectStorage` CIFS mount is soft, root-owned (`uid=0,gid=0`) and mode `0755`:

- direct user writes can return `Permission denied` by design of that mount state;
- a server stall on a soft mount can surface as `EIO` rather than waiting indefinitely.

These are observations, not a repository-applied fix. Check `findmnt -T /mnt/ProjectStorage` and involve the storage owner.

**Unverified:** per-user ZFS quota sizes and live mount options are site state, not tracked code. Verify them on TrueNAS and the affected compute node.
