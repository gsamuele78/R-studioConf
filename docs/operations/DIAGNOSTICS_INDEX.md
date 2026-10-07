<!-- docs/operations/DIAGNOSTICS_INDEX.md -->
---
title: "BIOME-CALC Diagnostics Index"
audience: operator
status: current
tier: T1
source_path: docs/operations/DIAGNOSTICS_INDEX.md
last_verified: 2026-10-06
---

# Diagnostics Index

This index covers every current `scripts/99_*`, `scripts/fix_*`, and `scripts/tools/*` file. Commands are shown from the repository root unless the entry says the tool is deployed elsewhere.

## Safety classes

- **Read-only:** no intended persistent state change, although runtime profile probes can create normal per-user `/Rtmp` and local-library directories.
- **Dry-run by default:** mutation requires an explicit commit/apply mode.
- **Mutating:** changes the host or user state in its normal mode.

## `scripts/99_*`

### `99_health_check.sh`

- **Use:** broad post-deploy/routine service, identity, Rprofile, BLAS, `/Rtmp` and cgroup checks.
- **Flags:** none.
- **Mutation:** read-only.
- **Run:** `sudo bash scripts/99_health_check.sh`.
- **Output:** stdout; non-zero indicates at least one failed check.

### `99_audit_r_environment.sh`

- **Use:** deploy/run audit v28.
- **Flags:** `--deploy-only`, `--run-only`, `--help`.
- **Mutation:** no arguments or `--deploy-only` writes `/etc/biome-calc/audit/00_audit_v28.R` and backs up the previous file; `--run-only` is read-only apart from audit logs.
- **Run:** `sudo bash scripts/99_audit_r_environment.sh --deploy-only` or `sudo bash scripts/99_audit_r_environment.sh --run-only`.
- **Output:** stdout, `~/biome_audit.log`, and `/var/log/biome-log/r_biome_system.log`. The script does not create a Markdown report directory.
- **Note:** its help text still prints one stale console path without `/audit/`; the deployed `AUDIT_DEST` in code is `/etc/biome-calc/audit/00_audit_v28.R`.

### `99_check_pkg_drift.sh`

- **Use:** compare installed packages with the local baseline.
- **Flags:** `--update`, `--json=PATH`, `--email`, `--help`.
- **Mutation:** normal runs create JSON reports and prune reports older than 30 days; `--update` replaces the baseline; `--email` sends on exit ≥1.
- **State:** baseline `/var/lib/biome-calc/pkg_baseline.rds`; reports `/var/lib/biome-calc/drift_reports/drift_<timestamp>.json`.
- **Exit:** `0` no drift, `1` medium/unknown, `2` high, `3` internal failure.

### `99_check_rprofile_health.sh` — health version 2.0

- **Use:** dispatcher/fragments/bundle/BLAS/Renviron/runtime/worker health and one user's startup state.
- **Flags:** `--user NAME`, `--static-only`, `--allow-root-probes`, `--fix`, `--reset-profile`, `--undo-reset STAMP|list`, `--commit`, `-y|--yes`, `--help`.
- **Mutation:** checks are read-only except normal profile loading may create user runtime directories. Repair/reset/undo are dry-run without `--commit`; system files are never repaired by this tool.
- **Examples:**

```bash
sudo bash scripts/99_check_rprofile_health.sh --static-only
sudo bash scripts/99_check_rprofile_health.sh --user <user>
sudo bash scripts/99_check_rprofile_health.sh --user <user> --fix
sudo bash scripts/99_check_rprofile_health.sh --user <user> --fix --commit
sudo bash scripts/99_check_rprofile_health.sh --user <user> --reset-profile --commit
sudo bash scripts/99_check_rprofile_health.sh --user <user> --undo-reset list
```

- **Exit:** `0` clear, `1` FAIL/CRIT, `2` warnings or skipped runtime tier, `3` invocation/refusal, `4` requested change not fully applied.

### `99_check_user_renviron_overrides.sh`

- **Use:** audit personal `~/.Renviron` overrides.
- **Flags:** `-d DIR`, `-o CSV`, `--fix`, `--commit`, `-y|--yes`, `--help`.
- **Mutation:** read-only by default; `--fix` previews; `--fix --commit` comments matching R library lines after backup.
- **Known open defect:** owner/mode preservation errors are ignored before the temp file is moved. After a committed NFS cleanup, verify numeric ownership and restore the backup if wrong.

### `99_diagnose_user_script.sh` — harness 1.4

- **Use:** HC-13 L0/L0a/optional-L0b/L1/L2/L3s/L3 triage of an unchanged user script.
- **Flags:** `--timeout SECONDS` or `--timeout=SECONDS`; `--progress-window SECONDS` or `=SECONDS`; `--no-lint`; `--smoke`; `--help`; `--`; then script and arguments.
- **Run as:** affected user, not root.

```bash
sudo su - <user> -c '/usr/local/bin/99_diagnose_user_script.sh --timeout 600 /path/to/user.R'
```

- **Mutation:** does not edit the user script; creates `/tmp/user_diag_<user>_<timestamp>/` and normal user runtime files.
- **Overrides:** `BIOME_DIAG_OUT_DIR`, `BIOME_DIAG_R_MIN`, `BIOME_DIAG_FRAG_DIR`, timeout/smoke/lint environment variables.
- **Exit:** `0` L3 pass, `1` L0/L3 fail, `2` invocation error, `3` L3 progressing, `4` L3 pass plus HIGH lint.

### `99_diagnose_lussu_hang.sh` — harness 1.6

- **Use:** generic harness plus known terra/mclapply probes E/F/G.
- **Flags:** `--timeout`, `--progress-window`, `--no-lint`, `--smoke`, `--help`; then script and arguments.
- **Run as:** affected user.
- **Output:** `/tmp/lussu_diag_<user>_<timestamp>/`, including generic report, `lussu_overlay.tsv`, shims and probe logs.
- **Exit:** `0` pass, `1` genuine failure, `2` invocation, `3` progressing, `4` generic HIGH-lint result with probes passing.

### `99_postmortem_forensics.sh`

- **Use:** crash evidence when no live reproduction is available.
- **Flags:** `--user NAME`, `--hours N`, `--output FILE`, `--all-recent`, `--quick`, `--incident`, `--help`.
- **Mutation:** read-only unless `--incident`, which appends `/var/log/biome-log/incident_log.txt`; `--output` writes the requested report.
- **Requirement:** either `--user` or `--all-recent`.

### `99_troubleshoot_env.sh` — version 1.4.0

- **Use:** subsystem diagnostics and sanitized collection.
- **Flags:** `--auth`, `--nginx`, `--rstudio`, `--rprofile`, `--ttyd`, `--ollama`, `--storage`, `--telemetry`, `--native-opt`, `--all`, `--test-user USER`, `--collect`, `--help`.
- **Mutation:** checks are read-only; `--storage --test-user` creates/removes a 1 MiB+fsync file in the user's home; `--collect` writes `/tmp/rstudio_debug_bundle_<epoch>.tar.gz`.
- **Quota behavior:** detects `EDQUOT` and prints numeric UID/GID for server-side TrueNAS lookup.
- **Caution:** `--native-opt` probes dormant `/opt/rstudio-tools/biome_core.so`; absence is expected while `src/biome_core_rust` remains dormant.

### `99_verify_domain_join.sh`

- **Use:** verify the configured SSSD or Samba/Winbind join, home and automount state.
- **Flags:** none.
- **Mutation:** read-only.
- **Run:** `sudo bash scripts/99_verify_domain_join.sh`.

### `99_botanical_plot_stress_test.R`

- **Use:** interactive RStudio graphics stress test.
- **Flags:** none; source it from an RStudio session.
- **Run:** `source("scripts/99_botanical_plot_stress_test.R")`.
- **Mutation:** creates temporary/test plot output under the user's `/Rtmp` area.

### `99_diagnose_rstudio_plot_pane.R`

- **Use:** blank RStudio Plots pane.
- **Flags:** none; source it in the affected interactive RStudio console.
- **Run:** `source("scripts/99_diagnose_rstudio_plot_pane.R")`.
- **Mutation:** diagnostic may repair the current session's device with `options(device="RStudioGD")`; no system file changes.

## `scripts/fix_*`

### `fix_pam_segfault_inplace.sh`

- **Use:** retrofit the local-`passwd` PAM segfault repair.
- **Flags:** `--check`, `--rollback`, `--help`.
- **Mutation:** no-argument mode applies the fix; `--check` is diagnostic; `--rollback` restores `/root/pam-backup-latest`.
- **Backup:** `/root/pam-backup-<timestamp>/`.

### `fix_login_script_rlibs_inplace.sh`

- **Use:** stop deployed `/etc/profile.d/00_rstudio_user_logins.sh` from re-adding personal `R_LIBS_USER`.
- **Flags:** `--commit`, `--rollback DIR`, `--target PATH`, `--force`, `--rerun-logins`, `--help`.
- **Mutation:** dry-run by default. Commit/rollback only; backup `/root/login-script-hotfix-<timestamp>/`; no restart.
- **Safety:** refuses an unexpected rendered file/path relationship unless `--force`.

## `scripts/tools/*`

### `build_wiki_docx.sh`

- **Use:** workstation-only renderer for the two English wiki DOCX guides defined by `docs/wiki/manifest.tsv`.
- **Flags:** `--out DIR`, `--only ID`, `-h|--help`.
- **Behavior:** requires Pandoc >=2.17, Python 3 and git; stages Markdown without front matter/path comments, creates a reference DOCX, applies the Lua filter and writes DOCX files (default `docs/wiki/`). It marks output `+uncommitted` when `docs/` is dirty.

### `bigger_usage_reports.sh`

- **Flags:** none.
- **Behavior:** read-only disk report; local filesystems to depth 4 and network mounts to depth 2, threshold 500 MiB, idle I/O priority. It is not a per-user `/Rtmp` report and performs no cleanup.

### `check_installed_R_Package.sh`

- **Flags:** passes all arguments to the R script, but the R script defines no argument parser.
- **Behavior:** prints an ecosystem summary and writes `installed_packages.csv` in the current working directory. It does not accept a package name or report one package's loaded path.
- **Wrapper:** executes `check_installed_R_Package.R` from its own directory.

### `check_installed_R_Package.R`

- **Flags:** none.
- **Behavior:** R/environment/ecosystem report; writes `installed_packages.csv` in the current working directory.

### `check_pkg_config.sh`

- **Flags:** none.
- **Behavior:** runs `pkg-config --cflags/--libs` for only `openblas` and `openmp`; exits under strict mode if either `.pc` file is missing. It does not audit the full geospatial development-library set.

### `check_processor_threads.sh`

- **Flags:** none.
- **Behavior:** reports `lscpu` sockets/cores/threads and `nproc`; it does not inspect cgroup `cpu.max` or run R.

### `deployment_summary.sh`

- **Flag recognized:** `--mail` is detected by searching the argument string; other arguments are ignored.
- **Behavior:** writes `/tmp/node_deployment_report_<hostname>_<YYYYMMDD>.log`, invokes deployed tools under `/etc/biome-calc/script/tools`, and optionally emails through deployed orphan-cleanup mail helpers.
- **Mutation:** writes/overwrites the daily report; `--mail` sends it.

### `hotfix_smtp_site_overrides.sh`

- **Flags:** `--dry-run`, `--yes|-y`.
- **Behavior:** root-only targeted patch of six site mail/contact keys in `/etc/biome-calc/conf/setup_nodes.vars.conf`; interactive exact `yes` unless `--yes`; no service restart.

### `hw_report.sh`

- **Flags:** none.
- **Behavior:** creates a `mktemp -d` report directory containing text and HTML, optionally PDF when `wkhtmltopdf` exists; prints the path and transfers ownership to the invoking sudo user. Root gives the most complete report.

### `manage_r_sessions.sh`

- **Flags:** none.
- **Mutation:** immediately sends TERM, then KILL, to processes matching `R|rsession` for `$USER`; if root, prompts to restart `rstudio-server`. It has no `--user` or `--kill-orphans` mode.
- **Use:** hazardous interactive tool; do not use as an orphan-only cleanup. Prefer `/etc/biome-calc/script/cleanup_r_orphans.sh --dry-run`.

### `r_pkg_drift_detector.R`

- **Flags:** `--baseline=PATH`, `--json=PATH`, `--quiet`, `--update-baseline`, `--help`.
- **Behavior:** detector version 1.0.0; compares package state and optionally updates the RDS baseline. Normally invoked through `99_check_pkg_drift.sh`.

## Deployed tools not matched by the requested file patterns

`50_setup_nodes.sh` option H deploys `/usr/local/bin/r_minimal`, `r_minimal_rscript`, `99_diagnose_user_script.sh`, and `99_diagnose_lussu_hang.sh`. Orphan cleanup/report/notification tools are rendered from templates into `/etc/biome-calc/script/` by option 9.

## Decision map

| Symptom | First tool |
|---|---|
| Unknown subsystem | `99_troubleshoot_env.sh --all --test-user <user>` |
| R profile/startup | `99_check_rprofile_health.sh --user <user>` |
| Reproducible `.R` failure | `99_diagnose_user_script.sh` as user |
| terra/mclapply/NFS pattern | `99_diagnose_lussu_hang.sh` as user |
| Unwitnessed crash | `99_postmortem_forensics.sh --user <user>` |
| Home write `EDQUOT` | `99_troubleshoot_env.sh --storage --test-user <user>` |
| Blank Plots pane | source `99_diagnose_rstudio_plot_pane.R` in RStudio |
| Package divergence | `99_check_pkg_drift.sh` |
| `passwd` segfault | `fix_pam_segfault_inplace.sh --check` |
| Local R library overridden | `99_check_user_renviron_overrides.sh` plus profile health |

**Unverified:** whether each tool is deployed on a specific live node. Repository existence and interfaces are verified; use `command -v`/`ls` on the affected host before relying on deployed copies.
