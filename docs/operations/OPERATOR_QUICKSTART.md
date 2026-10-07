<!-- docs/operations/OPERATOR_QUICKSTART.md -->
---
title: "BIOME-CALC Operator Quickstart"
audience: operator
status: current
tier: T1
source_path: docs/operations/OPERATOR_QUICKSTART.md
last_verified: 2026-10-06
---

# Operator Quickstart

## Operating boundary

T1 host automation is authoritative. Fix the system, profile, fragments, environment, mounts or cgroups before considering user code. Never silently edit a researcher's `.R` file. Run one AD backend per host: SSSD **or** Samba/Winbind.

Current runtime facts:

- `RPROFILE_VERSION="12.10"`;
- `/etc/R/Rprofile.site` plus 14 lexical fragments in `/etc/R/Rprofile_site.d/`;
- `libopenblas0-serial`, never pthread;
- local ext4 `/Rtmp` (400 GB configured expectation);
- NFS homes at `/nfs/home`; local user libraries at `/var/lib/biome-Rlibs/<user>/<R-major.minor>/`;
- generic harness 1.4, Lussu overlay 1.6, profile health 2.0, environment troubleshooter 1.4.0.

## Start of shift

```bash
sudo bash scripts/99_health_check.sh
sudo bash scripts/99_check_rprofile_health.sh --static-only
systemctl is-active rstudio-server nginx ttyd botanical-telemetry
findmnt -T /Rtmp
findmnt -T /nfs/home
```

Check only the configured identity backend:

```bash
systemctl is-active sssd
# OR
systemctl is-active smbd winbind
```

## User says "RStudio will not start"

```bash
sudo bash scripts/99_troubleshoot_env.sh --rstudio --auth --test-user <user>
sudo bash scripts/99_verify_domain_join.sh
sudo bash scripts/99_check_rprofile_health.sh --user <user>
journalctl -u rstudio-server -n 200 --no-pager
```

Do not run profile probes as root without `--user`; health 2.0 deliberately skips the runtime tier to avoid root-owned user directories.

## User says "my script hangs/crashes"

Run as the user against the unchanged script:

```bash
sudo su - <user> -c '/usr/local/bin/99_diagnose_user_script.sh --timeout 600 /path/to/user.R'
```

For the known terra/GDAL/mclapply pattern:

```bash
sudo su - <user> -c '/usr/local/bin/99_diagnose_lussu_hang.sh --timeout 1800 --progress-window 120 /path/to/user.R'
```

Read `/tmp/user_diag_<user>_<timestamp>/report.md` or `/tmp/lussu_diag_<user>_<timestamp>/report.md`.

| Verdict | Action |
|---|---|
| L0 fails | Repair storage, cgroup, kernel or BLAS evidence. |
| L3s passes, L3 fails | Personal startup files: preview `99_check_rprofile_health.sh --user <user> --fix`; apply only with `--commit`. |
| L2 passes, L3s fails | Fragment regression: bisect `BIOME_DISABLE_FRAGMENTS`, patch T1, redeploy option 3. |
| L1 passes, L2/L3s fail | Dispatcher/load contract. |
| L3 is `PROGRESSING` | Increase timeout; no failure is proven. |
| All production layers fail | Continue to the clean-VM L4 SOP. |
| L3 passes with exit 4 | Infrastructure passed; report contains HIGH lint findings. Share evidence; do not auto-edit. |

## Storage ticket

```bash
sudo bash scripts/99_troubleshoot_env.sh --storage --test-user <user>
df -hT /Rtmp /nfs/home /mnt/ProjectStorage
findmnt -T /Rtmp
findmnt -T /nfs/home
findmnt -T /mnt/ProjectStorage
```

- Home `EDQUOT` with free space in `df`: inspect TrueNAS ZFS `userquota` by numeric UID; see Troubleshooting §4.4.
- `/mnt/ProjectStorage` direct write returns `Permission denied`: observed CIFS mount is root-owned (`uid=0,gid=0`, `0755`).
- A stalled soft CIFS mount can return `EIO`; preserve that observation and escalate storage-side.

## Known one-shot repairs

```bash
sudo bash scripts/fix_pam_segfault_inplace.sh --check
sudo bash scripts/fix_pam_segfault_inplace.sh          # apply
sudo bash scripts/fix_pam_segfault_inplace.sh --rollback

sudo bash scripts/fix_login_script_rlibs_inplace.sh    # dry-run
sudo bash scripts/fix_login_script_rlibs_inplace.sh --commit

sudo bash scripts/tools/hotfix_smtp_site_overrides.sh --dry-run
sudo bash scripts/tools/hotfix_smtp_site_overrides.sh
```

## Redeploy and verify

```bash
sudo bash scripts/50_setup_nodes.sh
# 3 = profile/fragments/Renviron
# L = local R libraries + NFS audit
# H = minimal profile + harnesses
sudo bash scripts/50_setup_nodes.sh --verify
sudo bash scripts/99_check_rprofile_health.sh --static-only
```

Restarting `rstudio-server` terminates sessions. Use a maintenance window.

## Do not

- do not reference the broken sandbox as validation;
- do not install pthread BLAS or move R temp to `/tmp`;
- do not run both identity join scripts;
- do not run `20_configure_rstudio.sh` options 1, 3, 4, 5 or 9 on a populated node while the hazards in `CHANGELOG.md` remain open;
- do not treat a `touch` test as quota verification; use the 1 MiB+fsync test in `99_troubleshoot_env.sh`.

**Unverified:** live service state, mount options and TrueNAS quota values are not represented by repository files; collect them from the affected host.
