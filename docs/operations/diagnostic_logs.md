<!-- docs/operations/diagnostic_logs.md -->
---
title: "BIOME-CALC Diagnostic and Forensic Logs"
audience: operator
status: current
tier: T1
source_path: docs/operations/diagnostic_logs.md
last_verified: 2026-10-07
sharepoint_section: Operations Hub
---
# BIOME-CALC Diagnostic and Forensic Logs

**Audience:** sysadmin / on-call  
**Last verified:** 2026-10-06

## R runtime

| Path | Producer | Condition |
|---|---|---|
| `/var/log/biome-log/r_biome_system.log` | `sys_log()` in the dispatcher/fragments | Persistent site R events; configured by `LOG_FILE` in `config/setup_nodes.vars.conf`. |
| `/tmp/biome_boot_errors_<pid>.log` | `/etc/R/Rprofile.site` | Early bootstrap fallback when normal system logging is unavailable. |
| `/tmp/biome_frag_errors_<pid>.log` | fragment loader | A fragment raised an error; session startup continues. |
| `/tmp/biome_debug_<user>_<pid>.log` | dispatcher | Created when `BIOME_DEBUG=1` is set before R starts. |
| `/tmp/biome_worker_<pid>.log` | PSOCK worker fast path | Created when `BIOME_WORKER_DEBUG=1`. |
| `/Rtmp/biome_<user>/cluster_logs/` | `biome_make_cluster()` / PSOCK factory | Worker stdout/stderr files. |
| `/Rtmp/biome_thread_guard/` | fragments 05/55 | Per-user thread/options guard audit files. |
| `~/biome_audit.log` | deployed `00_audit_v28.R` | Per-user audit run log. |

## Diagnostic tools

| Tool | Output |
|---|---|
| `99_diagnose_user_script.sh` | `/tmp/user_diag_<user>_<timestamp>/` or `BIOME_DIAG_OUT_DIR`; `report.md`, `summary.tsv`, layer logs. |
| `99_diagnose_lussu_hang.sh` | `/tmp/lussu_diag_<user>_<timestamp>/`; generic report plus `lussu_overlay.tsv`, probe logs and shims. |
| `99_troubleshoot_env.sh --collect` | `/tmp/rstudio_debug_bundle_<epoch>.tar.gz`. |
| `99_postmortem_forensics.sh --output FILE` | Requested file; without `--output`, the report is printed to stdout. |
| `99_check_pkg_drift.sh` | `/var/lib/biome-calc/drift_reports/drift_<timestamp>.json`; baseline `/var/lib/biome-calc/pkg_baseline.rds`. |
| `scripts/tools/deployment_summary.sh` | `/tmp/node_deployment_report_<hostname>_<YYYYMMDD>.log`. |
| `scripts/tools/hw_report.sh` | A fresh `mktemp -d` directory printed at completion, containing text/HTML and optionally PDF. |

## Services and deployment

| Path / command | Component |
|---|---|
| `/var/log/biome-log/core/<script>.log` | `r_env_manager.sh` and numbered T1 scripts using common logging. |
| `journalctl -u rstudio-server` and `/var/log/rstudio/` | RStudio Server (the exact file layout is package-version dependent). |
| `/var/log/nginx/access.log`, `/var/log/nginx/error.log` | Nginx. |
| `journalctl -u botanical-telemetry.service` | Telemetry API. |
| `journalctl -u ttyd.service` and `/var/log/secure_access/` | ttyd / secure-access wrapper. |
| `journalctl -u sssd` and `/var/log/sssd/` | SSSD backend. |
| `journalctl -u smbd -u winbind` and `/var/log/samba/` | Samba/Winbind backend. |
| `/var/log/r_orphan_cleanup/` | Orphan cleanup/notification/report templates deployed by `50_setup_nodes.sh`. |
| `/var/log/biome-log/biome_archive/` | Project archiver (`ARCHIVE_LOG_DIR`). |

## Collection rule

Before attaching logs, remove usernames, home paths, internal hostnames/IPs, Kerberos material, cookies, tokens and site overlay contents. `99_troubleshoot_env.sh --collect` is the repository-provided collection path, but the operator must still inspect the archive before transfer.

**Unverified:** `~/ULTIMO_CRASH_RAM.txt` is referenced in older documentation but no current producer was found in `scripts/`, `lib/`, or `templates/`; do not rely on it as an OOM signal. Use kernel/systemd logs and cgroup events.
