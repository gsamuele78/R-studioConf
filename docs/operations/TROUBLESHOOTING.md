<!-- docs/operations/TROUBLESHOOTING.md -->
---
title: "BIOME-CALC Troubleshooting Runbook"
audience: operator
status: current
tier: T1
source_path: docs/operations/TROUBLESHOOTING.md
last_verified: 2026-10-06
---

# Troubleshooting Runbook

Every section is self-contained and follows **symptom → diagnosis → fix → verification**. Commands target the T1 host. Current runtime: Rprofile v12.10, 14 fragments, OpenBLAS serial, local ext4 `/Rtmp`, NFS homes at `/nfs/home` and local R libraries under `/var/lib/biome-Rlibs`.

## 0. First capture

```bash
sudo bash scripts/99_health_check.sh
sudo bash scripts/99_troubleshoot_env.sh --all --test-user <user>
sudo bash scripts/99_check_rprofile_health.sh --user <user>
```

Use only the configured identity backend when reading service state. Do not run both SSSD and Samba/Winbind join paths.

## 1. RStudio and R runtime

### 1.1 RStudio login loops or "session failed to start"

**Symptom.** Authentication appears to succeed, then the IDE loops, disconnects, or reports that the session could not start.

**Diagnosis.**

```bash
journalctl -u rstudio-server -n 200 --no-pager
sudo bash scripts/99_troubleshoot_env.sh --rstudio --auth --test-user <user>
sudo bash scripts/99_verify_domain_join.sh
sudo bash scripts/99_check_rprofile_health.sh --user <user>
getent passwd <user>
findmnt -T "$(getent passwd <user> | cut -d: -f6)"
```

**Fix.** Repair the failing layer: identity (§3), NFS home (§4.2), PAM (§2), or the user's startup state. For personal startup files, preview and then explicitly commit a reversible repair:

```bash
sudo bash scripts/99_check_rprofile_health.sh --user <user> --fix
sudo bash scripts/99_check_rprofile_health.sh --user <user> --fix --commit
# last resort, reversible quarantine:
sudo bash scripts/99_check_rprofile_health.sh --user <user> --reset-profile --commit
```

**Verification.** Rerun the health check as the user, then perform a fresh portal login. `--undo-reset list` shows reversible quarantines.

### 1.2 R session exits with SIGSEGV during matrix work

**Symptom.** `rsession` exits 139 or kernel/RStudio logs show signal 11, often near `solve()`, `%*%`, `crossprod()` or `blas_thread_server`.

**Diagnosis.**

```bash
sudo bash scripts/99_postmortem_forensics.sh --user <user> --hours 4
journalctl -k --since '-4 hours' | grep -iE 'segfault|signal 11|rsession'
update-alternatives --display libblas.so.3-x86_64-linux-gnu
update-alternatives --display liblapack.so.3-x86_64-linux-gnu
dpkg -l | grep -E 'openblas.*(serial|pthread)'
```

**Fix.** `libopenblas0-pthread` is a known crash source. Redeploy `50_setup_nodes.sh` option 2, which installs/pins the serial variant. Never install pthread BLAS.

```bash
sudo bash scripts/50_setup_nodes.sh
# select 2: BLAS/CORETYPE detection and smoke test
```

Restart `rstudio-server` only in a maintenance window; it terminates sessions.

**Verification.**

```bash
sudo bash scripts/99_check_rprofile_health.sh --static-only
Rscript --vanilla -e 'x <- matrix(runif(250000),500); invisible(crossprod(x)); cat("BLAS OK\n")'
```

The alternatives and health output must resolve to `openblas-serial`, never `openblas-pthread`.

### 1.3 R session is OOM-killed or exits 137

**Symptom.** The browser disconnects, the process exits 137, `cannot allocate vector` appears, or a user slice records OOM events.

**Diagnosis.**

```bash
journalctl -k --since '-2 hours' | grep -iE 'oom|killed process'
journalctl -u systemd-oomd --since '-2 hours'
systemctl show user-$(id -u <user>).slice -p MemoryHigh -p MemoryMax -p MemoryCurrent -p MemorySwapMax
cat /sys/fs/cgroup/user.slice/user-$(id -u <user>).slice/memory.events
df -hT /Rtmp
```

Current configured user-slice limits are `MemoryHigh=300G`, `MemoryMax=400G`, `MemorySwapMax=4G`, `TasksMax=4096`.

**Fix.** If `/Rtmp` is full, use §4.1. If the cgroup setting is wrong for an approved workload, change `config/setup_nodes.vars.conf`, redeploy option 8, and verify. Do not remove limits or enable unbounded swap as an incident shortcut. If the workload itself exceeds the approved envelope, preserve the evidence and use the HC-13 ladder rather than silently rewriting code.

**Verification.**

```bash
sudo bash scripts/50_setup_nodes.sh --verify
systemctl show user-$(id -u <user>).slice -p MemoryHigh -p MemoryMax -p MemorySwapMax -p TasksMax
```

Rerun the unchanged workload and confirm `memory.events` does not gain another `oom_kill`.

### 1.4 `mclapply()` with terra/GDAL stalls or workers accumulate memory

**Symptom.** A long `mclapply()` workload using terra/sf/GDAL on NFS stops making progress, or PSOCK worker RSS climbs despite R-level garbage collection.

**Diagnosis.** Run overlay 1.6 as the affected user:

```bash
sudo su - <user> -c '/usr/local/bin/99_diagnose_lussu_hang.sh --timeout 1800 --progress-window 120 /path/to/user.R'
```

Read `/tmp/lussu_diag_<user>_<timestamp>/report.md` and `lussu_overlay.tsv`. Probe E tests PSOCK reroute, F tests terra spill-to-disk, and G checks allocator variables on workers. `PROGRESSING` is not a hang; increase timeout.

**Fix.** Current v12.10 already contains ForkGuard package/global synchronization, cgroup-aware terra memory and allocator propagation. If a probe exposes drift, redeploy the profile chain rather than patching the user script:

```bash
sudo bash scripts/50_setup_nodes.sh
# select 3
```

**Verification.**

```bash
sudo bash scripts/50_setup_nodes.sh --verify
sudo bash scripts/99_check_rprofile_health.sh --static-only
sudo su - <user> -c '/usr/local/bin/99_diagnose_lussu_hang.sh --timeout 1800 --progress-window 120 /path/to/user.R'
```

See `LUSSU_HANG_BISECTION.md` for verdict mapping.

### 1.5 RStudio Plots pane stays blank

**Symptom.** `plot(1,1)` or `print(ggplot)` completes without error, but no plot reaches the browser.

**Diagnosis.** In the affected interactive RStudio console:

```r
source("scripts/99_diagnose_rstudio_plot_pane.R")
getOption("device")
```

On the host:

```bash
grep -nC8 'ragg::agg_png' /etc/R/Rprofile_site.d/50_pkg_hooks.R
grep -c '!is_interactive_rstudio' /etc/R/Rprofile_site.d/50_pkg_hooks.R
```

The second command must print `1`. Do not test this with `RSTUDIO=1 Rscript`: `Rscript` is non-interactive and correctly selects a file device.

**Fix.** For the current session:

```r
graphics.off()
options(device = "RStudioGD")
plot(1, 1)
```

For stale deployed fragment/bundle, redeploy option 3. Existing sessions must be closed/reopened because the profile is sourced once at session start; a server restart is not required solely for this incident.

**Verification.** The guard grep returns `1`; a new interactive session shows the plot. Check user/project `.Rprofile` for an explicit `options(device=...)` if the system fragment is current.

### 1.6 Local R library missing, unwritable, or still on NFS

**Symptom.** `.libPaths()` lacks `/var/lib/biome-Rlibs/<user>/<R-version>`, first install prompts for a personal library, or high-UID AD users alone are affected.

**Diagnosis.**

```bash
sudo bash scripts/99_check_rprofile_health.sh --user <user>
sudo bash scripts/99_check_user_renviron_overrides.sh
sudo -u <user> R --no-save -e 'cat(.libPaths(), sep="\n")'
id <user>
ls -ld /var/lib/biome-Rlibs /var/lib/biome-Rlibs/<user> 2>/dev/null
```

**Fix.** v12.8/v12.9/v12.9.2 fixed high-UID warmup, NFS-side user enumeration and runtime bootstrap. Redeploy options `L` and `3`. If `/etc/profile.d/00_rstudio_user_logins.sh` still writes `R_LIBS_USER`, patch it first:

```bash
sudo bash scripts/fix_login_script_rlibs_inplace.sh
sudo bash scripts/fix_login_script_rlibs_inplace.sh --commit
sudo bash scripts/50_setup_nodes.sh
# L, then 3
```

Then preview stale personal overrides with `99_check_user_renviron_overrides.sh --fix`. Its current `--fix --commit` path has an open owner-preservation defect if NFS `chown/chmod --reference` fails; verify numeric ownership immediately after use.

**Verification.** A new user R process shows the local path first and the directory is owned by that user's numeric UID/GID.

### 1.7 Package behavior differs between nodes

**Symptom.** The same script/package works on one node and fails on another.

**Diagnosis.**

```bash
sudo bash scripts/99_check_pkg_drift.sh --json=/tmp/drift.json
```

Exit `1` means medium/unknown drift, `2` high-risk drift, `3` detector failure.

**Fix.** Reconcile packages through `config/r_env_manager.conf` and the manager. Do not update the drift baseline until the difference is reviewed.

**Verification.** Rerun the detector; exit must be `0`. Then rerun the unchanged script under the same profile and inputs.

## 2. PAM and password operations

### 2.1 `passwd` segfaults for a local account

**Symptom.** `passwd` exits with a segmentation fault on an AD-joined Ubuntu 24.04 T1 host.

**Diagnosis.**

```bash
sudo bash scripts/fix_pam_segfault_inplace.sh --check
journalctl -t passwd --since '-1 hour' --no-pager
```

The repository incident attributes this to conflicting `libpam-krb5`/custom PAM state, not the user's password.

**Fix.** The installer path is `13_harden_pam_password.sh`. For an existing node:

```bash
sudo bash scripts/fix_pam_segfault_inplace.sh
```

The script backs up `/etc/pam.d/common-*` under `/root/pam-backup-<timestamp>/`, updates `/root/pam-backup-latest`, and supports `--rollback`.

**Verification.** Rerun `--check`, test `passwd` on a controlled local account, and verify the active identity backend still authenticates.

## 3. Identity and login

### 3.1 AD user no longer resolves or authenticates

**Symptom.** `getent passwd <user>`/`id <user>` fails, or RStudio/SSH rejects a known AD account.

**Diagnosis.**

```bash
sudo bash scripts/99_verify_domain_join.sh
realm list
getent passwd <user>
id <user>
chronyc tracking
```

For SSSD use `journalctl -u sssd`; for Samba use `journalctl -u smbd -u winbind`, `wbinfo -t`, and `wbinfo -P`.

**Fix.** Correct clock/DNS/network first. Clear only the active backend's cache and restart it. If the machine trust is broken, rerun **either** `10_join_domain_sssd.sh` **or** `11_join_domain_samba.sh`; never both.

**Verification.** `99_verify_domain_join.sh`, `getent`, `id`, backend trust check, PAM login and home lookup all pass.

### 3.2 Kerberos fails across users

**Symptom.** Ticket acquisition/domain operations fail cluster-wide.

**Diagnosis.**

```bash
chronyc tracking
klist -k /etc/krb5.keytab
sudo journalctl -u chrony -n 100 --no-pager
```

**Fix.** Repair time/DNS, then rerender with `12_lib_kerberos_setup.sh`. Do not put passwords on command lines; use keytabs/files as implemented by the scripts.

**Verification.** Keytab and domain-join verification succeed with acceptable clock skew.

## 4. Storage

### 4.1 `/Rtmp` is full or not local ext4

**Symptom.** R temp creation, terra spill, NIMBLE/TMB compilation or PSOCK startup fails with `No space left on device`.

**Diagnosis.**

```bash
findmnt -no SOURCE,FSTYPE,OPTIONS /Rtmp
stat -c '%a %U:%G %n' /Rtmp
df -hT /Rtmp
sudo bash scripts/tools/bigger_usage_reports.sh
ps -eo pid,ppid,user,rss,etime,args | grep -E 'rsession|Rscript|R --' | grep -v grep
```

**Fix.** Do not delete paths belonging to live sessions. Inspect orphan cleanup first and run its dry-run:

```bash
sudo /etc/biome-calc/script/cleanup_r_orphans.sh --dry-run
sudo /etc/biome-calc/script/cleanup_r_orphans.sh
```

If capacity is genuinely insufficient, use `add_storage_no_reboot.md`. Never redirect large R temp to `/tmp` or NFS.

**Verification.** `/Rtmp` is ext4, writable, mode 1777, has safe free space, and `99_check_rprofile_health.sh --user <user>` passes its runtime checks.

### 4.2 NFS home is unavailable, stale, or slow

**Symptom.** Login hangs/fails, home operations return `Stale file handle`, or all users see long I/O waits.

**Diagnosis.**

```bash
findmnt -T /nfs/home
mountstats /nfs/home 2>/dev/null || true
journalctl -k --since '-1 hour' | grep -iE 'nfs|rpc|stale'
sudo bash scripts/99_troubleshoot_env.sh --storage --test-user <user>
```

**Fix.** Repair the TrueNAS/network/export problem first. Remount only in a maintenance window after stopping dependent workloads; do not use lazy unmount as routine recovery. The repository NFS audit requires at least NFS 4.1 and recommends `nconnect>=4`/normal attribute caching, but intentionally does not remount.

**Verification.** `findmnt` shows the expected NFS mount, real 1 MiB+fsync home write succeeds for representative users, and new RStudio logins work.

### 4.3 `/mnt/ProjectStorage` rejects writes or returns `EIO`

**Symptom.** A user gets `Permission denied` writing to `/mnt/ProjectStorage`, or archive/project I/O returns `Input/output error` while the server stalls.

**Diagnosis.**

```bash
findmnt -T /mnt/ProjectStorage
stat -c '%a %U:%G %n' /mnt/ProjectStorage
sudo -u <user> test -w /mnt/ProjectStorage; echo $?
journalctl -k --since '-1 hour' | grep -iE 'cifs|smb|I/O error'
```

**Finding recorded for the current site:** the CIFS mount is soft, `uid=0,gid=0`, mode `0755`. Direct user writes therefore fail by ownership/mode. A soft CIFS mount can return `EIO` when its server stalls.

**Fix.** Do not chmod/chown the mountpoint or change mount semantics ad hoc. Use the archive tooling/approved project path and escalate the mount/export policy to the storage owner. Record `EIO` as a storage failure, not a user-script defect.

**Verification.** Confirm the approved archive workflow succeeds and `findmnt` reflects the storage-owner-approved mount. Direct user write is not a valid verification if policy keeps the root-owned mount.

### 4.4 Writes to `~` fail with "Disk quota exceeded" but `df` shows free space

**Symptom.** `saveRDS`, `write.csv`, shell writes and the bundled write test fail with `Disk quota exceeded`, while `df` shows free terabytes.

Homes are on TrueNAS SCALE dataset `zpool/home`, exported from `/mnt/zpool/home` with NFSv4.2 `sec=sys` to `/nfs/home`. ZFS server-side `userquota`, `userobjquota`, `groupquota`, `groupobjquota`, dataset quota or refquota can return kernel `EDQUOT`; client `df` and Linux `quota` do not report those limits.

**Diagnosis on the compute node.**

```bash
U=<user>
H=$(getent passwd "$U" | cut -d: -f6)
id "$U"
findmnt -T "$H"
df -hT "$H"
df -i "$H"
sudo bash scripts/99_troubleshoot_env.sh --storage --test-user "$U"
```

The v1.4.0 tool writes 1 MiB and fsyncs it; a bare `touch` is insufficient. If files appear owned by `4294967294`/`65534`, investigate NFSv4 idmapping before changing quotas.

**Diagnosis on TrueNAS (root, numeric IDs).**

```bash
DS=$(zfs list -H -o name,mountpoint | awk '$2=="/mnt/zpool/home"{print $1}')
UID_=<numeric-uid-from-id>
GID_=<numeric-primary-gid-from-id>
zfs get -H quota,refquota,used,available,usedbysnapshots "$DS"
zfs get userquota@$UID_,userused@$UID_,userobjquota@$UID_,userobjused@$UID_ "$DS"
zfs get groupquota@$GID_,groupused@$GID_,groupobjquota@$GID_,groupobjused@$GID_ "$DS"
zfs userspace -n -H -p -o name,used,quota "$DS"
```

A 2026-10 incident was a user quota entered as `150M` rather than `150G`.

**Fix.** Correct the numeric user/group/dataset quota in TrueNAS. Example, only after confirming policy and UID:

```bash
zfs set userquota@$UID_=150G "$DS"
zfs get userquota@$UID_,userused@$UID_ "$DS"
```

No remount or RStudio restart is required.

**Verification.** Rerun `99_troubleshoot_env.sh --storage --test-user`; it must report a successful 1 MiB+fsync write. Then rerun the unchanged user export.

## 5. Nginx, portal and TLS

### 5.1 Portal returns 502 Bad Gateway

**Symptom.** Nginx responds 502 for RStudio, ttyd, telemetry or another configured upstream.

**Diagnosis.**

```bash
sudo nginx -t
sudo tail -100 /var/log/nginx/error.log
ss -ltnp | grep -E '8787|7681|8000|11434'
curl -sSI http://127.0.0.1:8787
curl -sf http://127.0.0.1:8000/api/v1/health
```

**Fix.** Restart only the failed upstream after identifying its error; do not restart every service. If Nginx config is invalid, restore/rerender the T1 template, run `nginx -t`, then reload.

**Verification.** Upstream curl succeeds, `nginx -t` passes, and the external route no longer returns 502.

### 5.2 Portal login crashes an Nginx worker (`auth_pam` regression)

**Symptom.** `/auth-check` causes signal 11 and logs identify `ngx_http_auth_pam_module.so`.

**Diagnosis.**

```bash
dpkg -l | grep -E 'nginx|auth-pam'
sudo journalctl -k --since '-1 hour' | grep -iE 'nginx|segfault'
sudo bash scripts/fix_pam_segfault_inplace.sh --check
```

The confirmed June 2026 T1 incident was Nginx `1.24.0-2ubuntu7.10` with auth-pam `1:1.5.5-2build2`; `1.24.0-2ubuntu7.9` was the known-good node state. `pam_lastlog.so` warnings were non-causal.

**Fix.** Follow `NGINX_AUTH_PAM_REGRESSION_2026-06.md`: use checksummed repacked packages from a working node, hold the package set, and install `/etc/apt/preferences.d/99-block-nginx-bad.pref`. Do not assume an old version remains in APT.

**Verification.** Controlled portal authentication produces no new signal-11/kernel event; package holds and the `.pref` file are present.

### 5.3 Portal frame is blank or CSP blocks RStudio

**Symptom.** Portal loads but the RStudio frame is refused by `frame-ancestors`/CSP.

**Diagnosis.** Browser console plus:

```bash
sudo nginx -T | grep -nE 'frame-ancestors|Content-Security-Policy'
```

**Fix.** Repair `templates/nginx_proxy_location.conf.template`, then:

```bash
sudo bash scripts/update_nginx_templates.sh
sudo nginx -t
sudo systemctl reload nginx
```

**Verification.** Browser console is clear and the frame opens through the portal.

### 5.4 Certificate renewal fails

**Symptom.** Browser shows expiry/trust errors or Certbot timer fails.

**Diagnosis.**

```bash
sudo certbot renew --dry-run
sudo journalctl -u certbot.timer -n 100 --no-pager
sudo nginx -t
```

**Fix.** Restore the ACME challenge location/template and rerun `32_setup_letsencrypt.sh` as designed.

**Verification.** Dry run passes, Nginx config passes, and the served certificate has the expected dates/chain.

## 6. Telemetry and Problem Reporter

### 6.1 Portal says telemetry offline

**Symptom.** Status strip reports offline or `/api/v1/health` fails.

**Diagnosis.**

```bash
systemctl status botanical-telemetry --no-pager
journalctl -u botanical-telemetry -n 100 --no-pager
curl -sf http://127.0.0.1:8000/api/v1/health
```

**Fix.** Repair the logged cause; rerun `40_install_telemetry.sh` only when its deployed service/venv is incomplete.

**Verification.** Health endpoint succeeds and the portal recovers.

### 6.2 Problem Reporter fails with `[Errno -5] No address associated with hostname`

**Symptom.** Report submission fails although telemetry health is green.

**Diagnosis.** The historical cause was sanitized SMTP placeholders copied into `/etc/biome-calc/conf/setup_nodes.vars.conf`.

```bash
sudo bash scripts/tools/hotfix_smtp_site_overrides.sh --dry-run
```

**Fix.** With the gitignored site override populated:

```bash
sudo bash scripts/tools/hotfix_smtp_site_overrides.sh
```

The tool patches exactly six mail/site keys and makes a backup through the shared helper. No service restart is needed because telemetry rereads config per report request.

**Verification.** Submit a controlled problem report and inspect telemetry logs for successful delivery without printing secrets.

## 7. Orphan processes and cleanup

### 7.1 Orphan R workers consume memory or `/Rtmp`

**Symptom.** R/Rscript processes with dead parents remain after a session closes.

**Diagnosis.**

```bash
ps -eo pid,ppid,user,rss,etime,args | awk '$2==1' | grep -E 'Rscript|R --slave|R --no-save|R --no-echo'
sudo cat /etc/cron.d/r_orphan_cleanup
sudo ls -l /etc/biome-calc/script/{cleanup_r_orphans.sh,notify_r_orphans.sh,r_orphan_report.sh}
```

**Fix.** Use the deployed cleanup's ancestry checks, not broad `pkill` commands:

```bash
sudo /etc/biome-calc/script/cleanup_r_orphans.sh --dry-run
sudo /etc/biome-calc/script/cleanup_r_orphans.sh
```

If files/cron are missing, redeploy `50_setup_nodes.sh` option 9.

**Verification.** Dry-run is clear, genuine live worker trees remain, stale orphans are gone, and cron/logs under `/var/log/r_orphan_cleanup/` update.

## 8. R profile health and deployment drift

### 8.1 Welcome banner/guards/tools are missing

**Symptom.** No banner, `status()`/`biome_make_cluster()` is absent, fragments report errors, or sessions are unusually slow only for one user.

**Diagnosis.**

```bash
sudo bash scripts/99_check_rprofile_health.sh --static-only
sudo bash scripts/99_check_rprofile_health.sh --user <user>
sudo bash scripts/50_setup_nodes.sh --verify
```

Health 2.0 checks dispatcher, 14 fragments, byte-compiled bundle, guards, BLAS, Renviron, personal startup, worker survival, runtime load and minimal tools.

**Fix.** Follow the exact finding. System drift is usually corrected by option 3. Personal startup repair uses `--fix`/`--reset-profile` with explicit `--commit`.

**Verification.** Static and user health checks return 0 (or only understood warnings), version is 12.10, fragment count is 14 and runtime worker survival passes.

## 9. Prohibited incident shortcuts

- Never install `libopenblas0-pthread`.
- Never redirect large R temp to `/tmp`, tmpfs or NFS.
- Never patch a user's `.R` to mask T1 behavior.
- Never run both AD backend join scripts.
- Never use the broken sandbox as validation.
- Never run destructive storage commands until the device/mount is proven.
- Never assume `df` disproves a TrueNAS ZFS user quota.

**Unverified:** live node package versions, mounts, service state, quotas and incident-specific inputs cannot be verified from git. Capture them in the incident report before applying a fix.
