<!-- docs/operations/USER_SCRIPT_TROUBLESHOOTING.md -->
---
title: "User-Script Troubleshooting"
audience: operator
status: current
tier: T1
source_path: docs/operations/USER_SCRIPT_TROUBLESHOOTING.md
last_verified: 2026-10-06
---

# User-Script Troubleshooting

## Rule

Run the user's unchanged `.R` through the diagnostic ladder. System/config defects are repaired in T1. User startup-file repairs are backed up and explicit. A code change may be proposed only after a clean L4 reproduction and with user consent.

## Run the supported harness

Harness 1.4 must run as the affected user:

```bash
sudo su - <user> -c '/usr/local/bin/99_diagnose_user_script.sh --timeout 600 --progress-window 60 /path/to/user.R [args...]'
```

Options: `--timeout SECONDS`, `--progress-window SECONDS`, `--no-lint`, `--smoke`, `--help`, and `--` to terminate option parsing. `--smoke` enables the opt-in L0b reduced run. Root is refused unless `BIOME_DIAG_ALLOW_ROOT=1`, which is for harness forensics and does not reproduce the user's environment.

Output: `/tmp/user_diag_<user>_<timestamp>/` (or `BIOME_DIAG_OUT_DIR`) containing `report.md`, `summary.tsv`, and per-layer stdout/stderr.

## Layers

| Layer | Environment | Purpose |
|---|---|---|
| L0 | `r_minimal`; no user script | OS, mounts, fork and cgroup evidence. |
| L0a | static linter | Describe-only findings; never edits the file. |
| L0b | opt-in smoke | Reduced in-process run using `BIOME_SMOKE_*` knobs. |
| L1 | `r_minimal_rscript`; no user startup | Minimal-profile reproduction. |
| L2 | dispatcher, every deployed fragment disabled; no user startup | Distinguishes fragments from dispatcher/non-profile behavior. |
| L3s | full system profile; no user startup | System profile reference. |
| L3 | production profile plus user startup | Actual user behavior. |
| L4 | clean VM, manual | Removes NFS/domain/BIOME profile. |
| L5 | user/upstream | Minimal reproducer and consented recommendation. |

L1/L2/L3s set `R_ENVIRON_USER=` and use `--no-init-file`; this excludes both project/home Renviron and Rprofile files. L2 builds its disabled-prefix list from the deployed fragment directory.

## Verdict and action

| Evidence | Action |
|---|---|
| L0 fails | Repair the infrastructure signal first. |
| L3 passes | Production reproduction passed. Collect exact inputs/args/time; read notes and lint findings. |
| L3 `PROGRESSING` (exit 3) | Output changed near timeout. Increase timeout; do not classify as hang. |
| L3 passes with HIGH lint (exit 4) | Infrastructure passed; share report and user-guide anchors. Do not auto-patch. |
| L3 fails, L3s passes | Personal `~/.Renviron`/`~/.Rprofile`/state. Preview `99_check_rprofile_health.sh --user <user> --fix`; apply with `--commit`, or reversible `--reset-profile --commit`. |
| L3s fails, L2 passes | Fragment regression. Bisect `BIOME_DISABLE_FRAGMENTS` without user startup files. |
| L3s/L2 fail, L1 passes | Dispatcher core or fragment-load contract. |
| L1/L2/L3s/L3 fail | Not a profile issue. Use L4; the Lussu overlay may identify terra/fork/allocator behavior. |
| Required layer is SKIPPED | Deploy missing HC-13 tooling with `50_setup_nodes.sh` option H and rerun. |

Exit codes: `0` L3 passed; `1` L0 or L3 failed; `2` invocation error; `3` L3 progressing; `4` L3 passed with HIGH lint.

## Manual fragment bisection

```bash
FRAGS=$(find /etc/R/Rprofile_site.d -maxdepth 1 -type f -name '[0-9][0-9]_*.R' -printf '%f\n' | cut -c1-2 | sort -u | paste -sd,)
R_ENVIRON_USER= BIOME_DISABLE_FRAGMENTS="$FRAGS" Rscript --no-init-file /path/to/user.R
```

Halve the list until one fragment remains. Preserve `R_ENVIRON_USER=` and `--no-init-file` throughout so personal startup files do not contaminate L3s/L2 attribution.

## Personal startup files

```bash
sudo bash scripts/99_check_rprofile_health.sh --user <user>
sudo bash scripts/99_check_rprofile_health.sh --user <user> --fix
sudo bash scripts/99_check_rprofile_health.sh --user <user> --fix --commit
sudo bash scripts/99_check_rprofile_health.sh --user <user> --reset-profile --commit
sudo bash scripts/99_check_rprofile_health.sh --user <user> --undo-reset list
```

`--fix`, reset and undo are dry-run unless `--commit`. System files are never changed by this tool. `R_LIBS_*` cleanup is owned by `99_check_user_renviron_overrides.sh`; verify file ownership after applying its current cleanup path because the changelog records a still-open NFS owner-loss risk.

## Lussu-class overlay

```bash
sudo su - <user> -c '/usr/local/bin/99_diagnose_lussu_hang.sh --timeout 1800 --progress-window 120 /path/to/user.R'
```

Overlay 1.6 forwards the generic flags and runs E (PSOCK swap), F (terra spill), and G (allocator propagation). See `LUSSU_HANG_BISECTION.md`.

## Postmortem when no live reproduction exists

```bash
sudo bash scripts/99_postmortem_forensics.sh --user <user> --hours 4 --output /tmp/postmortem.txt
sudo bash scripts/99_postmortem_forensics.sh --user <user> --incident
```

`--incident` appends `/var/log/biome-log/incident_log.txt`.

## User response

For a system fix: state the failing surface, the T1 change, and that the unchanged script should be rerun. For a startup-file issue: name the file/setting, backup and rollback. For L5: attach the clean-VM evidence, minimal reproducer and package/session versions; the proposal remains for user review.

**Unverified:** workload data, private user startup files and exact reproduction arguments are not in git. Record their checksums and invocation in the incident report.
