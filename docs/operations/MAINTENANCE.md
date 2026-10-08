<!-- docs/operations/MAINTENANCE.md -->
---
title: "BIOME-CALC Maintenance Runbook"
audience: operator
status: current
tier: T1
source_path: docs/operations/MAINTENANCE.md
last_verified: 2026-10-06
---

# Maintenance Runbook

## Daily / automated jobs

`50_setup_nodes.sh` installs cron jobs in `/etc/cron.d/r_orphan_cleanup` using these defaults from `config/setup_nodes.vars.conf`:

| Job | Default schedule | Deployed command |
|---|---|---|
| orphan cleanup | `15 * * * *` | `/etc/biome-calc/script/cleanup_r_orphans.sh` |
| orphan notification | `00 18 * * *` | `/etc/biome-calc/script/notify_r_orphans.sh` |
| orphan report | `00 08 * * 1-5` | `/etc/biome-calc/script/r_orphan_report.sh` |

Nginx temp cleanup is installed by `15_setup_nginx_cleanup.sh`; certificate renewal uses Certbot's timer. Verify the actual host rather than assuming defaults:

```bash
sudo cat /etc/cron.d/r_orphan_cleanup
sudo systemctl list-timers --all | grep -E 'certbot|cleanup|orphan'
sudo crontab -l
```

## Weekly

```bash
sudo bash scripts/99_health_check.sh
sudo bash scripts/99_check_rprofile_health.sh --static-only
sudo bash scripts/99_check_pkg_drift.sh
sudo bash scripts/99_check_user_renviron_overrides.sh
df -hT /Rtmp /var /nfs/home
findmnt -T /nfs/home
findmnt -T /mnt/ProjectStorage
```

Package-drift exit codes are `0` no drift, `1` medium/unknown drift, `2` high risk, `3` internal failure. Update the baseline only after review:

```bash
sudo bash scripts/99_check_pkg_drift.sh --update
```

Do not treat `CLEAN_VM_BASELINE.md` as a node rebuild procedure; it is an L4 diagnostic baseline.

## Monthly and after changes

### R runtime/profile

Current `RPROFILE_VERSION` is `12.11`.

```bash
sudo bash scripts/50_setup_nodes.sh --verify
sudo bash scripts/99_check_rprofile_health.sh --static-only
sudo bash scripts/99_audit_r_environment.sh
```

After changing `templates/Rprofile_site.R.template`, `templates/Rprofile_site.d/`, or `templates/Renviron.template`, run `50_setup_nodes.sh` and select option `3` (config files only), then verify. Restarting `rstudio-server` terminates sessions; use a maintenance window.

### Local R libraries

```bash
sudo bash scripts/50_setup_nodes.sh
# option L: local R library root/warmup plus read-only NFS audit
sudo bash scripts/99_check_user_renviron_overrides.sh
```

`04_user_lib_bootstrap.R` covers new and high-UID AD users at first R start. If the deployed login script still writes `R_LIBS_USER`, preview and apply the targeted hotfix before enabling local libraries:

```bash
sudo bash scripts/fix_login_script_rlibs_inplace.sh
sudo bash scripts/fix_login_script_rlibs_inplace.sh --commit
```

Do not use `20_configure_rstudio.sh` options 1, 3, 4, 5 or 9 on a populated node until the open hazards recorded in `CHANGELOG.md` are resolved.

### Problem Reporter SMTP overlay

```bash
sudo bash scripts/tools/hotfix_smtp_site_overrides.sh --dry-run
sudo bash scripts/tools/hotfix_smtp_site_overrides.sh
```

This patches six site-local mail keys in `/etc/biome-calc/conf/setup_nodes.vars.conf`; the telemetry API rereads the file per request, so no restart is required.

### Identity

Use exactly one identity backend per host. Verify before rejoining:

```bash
sudo bash scripts/99_verify_domain_join.sh
```

Then run either `10_join_domain_sssd.sh` or `11_join_domain_samba.sh`, never both.

## Quarterly

```bash
sudo bash scripts/tools/hw_report.sh
sudo bash scripts/tools/deployment_summary.sh
sudo bash scripts/fix_pam_segfault_inplace.sh --check
sudo bash scripts/99_audit_r_environment.sh
sudo bash scripts/99_postmortem_forensics.sh --all-recent --hours 24 --quick
```

Review `/var/lib/biome-calc/drift_reports/`, `/var/log/r_orphan_cleanup/`, `/var/log/biome-log/core/`, `/var/log/nginx/`, identity logs, `/Rtmp`, and backup retention.

## Backups and rollback

`r_env_manager.sh` stores run trees below `/var/backups/r_env_manager/files/`. Inspect the actual backup before restoring. The current `restore_config()` implementation restores the newest `run_<timestamp>` tree and restarts services only after at least one file is restored.

```bash
sudo ls -lt /var/backups/r_env_manager/files/
```

Use the orchestrator's restore path where possible; for manual file restore, preserve owner/mode and validate the service configuration before restart (`nginx -t`, R parse/health check, or identity-specific checks).

## Storage observations

- Homes: TrueNAS SCALE `zpool/home`, NFSv4.2 `sec=sys`, mounted at `/nfs/home`, with server-side per-user ZFS `userquota`.
- Project share: CIFS `/mnt/ProjectStorage`; observed mount is `soft`, `uid=0,gid=0`, mode `0755`. Users therefore see `Permission denied` on direct writes. A stalled soft mount can return `EIO`; record this as storage evidence rather than changing user code.
- Scratch: local ext4 `/Rtmp`, expected size 400 GB and mode `1777`.

**Unverified:** the exact live `/etc/fstab` options and TrueNAS quota values are not stored in git. Confirm them with `findmnt` and server-side `zfs get/userspace` on each maintenance cycle.
