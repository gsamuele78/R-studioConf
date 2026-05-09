<!-- docs/reference/SCRIPT_CATALOG.md -->
# Script Catalog (T1 Host — Authoritative)

> **Tier:** T1 (host) — `AUTHORITATIVE_CONTINUOUSLY_FIXED`. Bugs are fixed
> here first, then ported forward to T2 (`docker-deploy/`) and T3
> (`kubernetes-deploy/`). Never patch T2/T3 in a way that masks a T1 defect.
>
> **Last updated:** 2026-05-09 (sync with `c3f05af`).

This catalog is the definitive inventory of every executable artefact under
`/scripts/`, `/lib/`, the root orchestrators, and the embedded helper
templates that get deployed as scripts. It supersedes earlier versions of
this file which were missing all `99_*` diagnostics, the PAM hardening
chain, the telemetry stack, the node setup chain, and the helper
launchers.

---

## 0. Entry points (root)

| File | Role | Notes |
|---|---|---|
| `init.sh` | Bootstrap launcher | Marks every `scripts/*.sh` executable, then `sudo` exec's `r_env_manager.sh`. |
| `r_env_manager.sh` | Idempotent orchestrator (v2.0.0) | Acquires lock, validates resources, drives the menu, sources `lib/common_utils.sh`. State at `/var/lib/r_env_manager/`, logs at `/var/log/biome-log/core/`, backups at `/var/backups/r_env_manager/`. |
| `Makefile` | Audit gate | `make audit` = `validate` + `generate-check`. Validates `.ai/` constraints and confirms IDE rule files (`.clinerules`, `.cursorrules`, `.windsurfrules`, `CLAUDE.md`, `.aider.conf.yml`) are in sync with `.ai/project.yml`. |

---

## 1. Library (`lib/`)

| File | Purpose |
|---|---|
| `lib/common_utils.sh` | Shared bash utilities — logging (`log INFO/WARN/ERROR/FATAL`), `process_template`, `run_command`, `ensure_dir_exists`, `handle_error`, lock/PID helpers, backup/restore primitives. **Sourced** by every numbered phase script. |
| `lib/biome-portal.js` | Portal frontend helpers (loaded by `templates/portal_index.html.template`). Out of scope for shell deployment but tracked here so it isn't lost. |

---

## 2. Numbered phase scripts (`scripts/NN_*.sh`)

All phase scripts use `#!/bin/bash` + `set -euo pipefail` (real or
deferred), source `lib/common_utils.sh`, read their own
`config/<name>.vars.conf`, and render their own template(s) via
`process_template`.

### Phase 0 — System & time

| Script | Config | Purpose |
|---|---|---|
| `01_optimize_system.sh` | `config/optimize_system_proxmox.vm.vars.conf` | Proxmox-side VM optimizer. Auto-detects host hardware, prompts for sysadmin confirmation, applies Ceph/Proxmox-safe tunings to a KVM guest. |
| `02_configure_time_sync.sh` | `config/configure_time_sync.vars.conf` | Unified NTP/chrony setup. Picks chrony / ntpd / systemd-timesyncd, renders `chrony.conf.template`, restarts the daemon. **FIX**: handles newline edge-case in pool directive generation (regression historically hit on Debian 12). |
| `03_install_secure_access.sh` | `config/install_secure_access.vars.conf` | v16.1. Installs the secure-access front (ttyd + login wrapper). Source for `ttyd_login_wrapper.sh` deployment. |

### Phase 1 — Identity (AD / Kerberos / PAM)

| Script | Config | Purpose |
|---|---|---|
| `10_join_domain_sssd.sh` | `config/join_domain_sssd.vars.conf` + `lib_kerberos_setup.vars.conf` | SSSD + Kerberos AD join. Installs `sssd-ad`, joins the realm, renders `sssd.conf.template`, runs sanity tests. |
| `11_join_domain_samba.sh` | `config/join_domain_samba.vars.conf` + `lib_kerberos_setup.vars.conf` | Alternative Samba/Winbind AD join with idmap ranges. Renders `smb.conf.template`. |
| `12_lib_kerberos_setup.sh` | `config/lib_kerberos_setup.vars.conf` | Centralized Kerberos client install + multi-realm `/etc/krb5.conf` generation (DIR/PERSONALE/STUDENTI). Sourced by both join scripts. |
| `13_harden_pam_password.sh` | — | **Critical fix.** AD-joined Ubuntu 24.04 hosts: removes `libpam-krb5` and any obsolete `biome-localguard` pam-config profile so that `passwd` for local users (uid<10000) no longer SIGSEGVs. See `docs/deployment/PAM_HARDENING.md`. |
| `fix_pam_segfault_inplace.sh` | — | One-shot retrofit for already-deployed older releases that shipped `libpam-krb5` / `biome-localguard`. Use `--check` for diagnosis-only dry-run; otherwise applies the minimal corrective changes. |

### Phase 2 — RStudio Server & R runtime

| Script | Config | Purpose |
|---|---|---|
| `20_configure_rstudio.sh` | `config/configure_rstudio.vars.conf` | Installs RStudio Server, lays out `rserver.conf` / `rsession.conf` / `logging.conf`, sets up `R_PROJECTS_ROOT`, `USER_LOGIN_LOG_ROOT`, `GLOBAL_RSTUDIO_TMP_DIR`, port (`RSERVER_WWW_PORT`), session timeout, OpenBLAS thread pin (`OPENBLAS_NUM_THREADS_RSTUDIO`). |
| `21_helper_rstudio_version.sh` | — | Detects OS codename + arch, scrapes `posit.co/download` for the latest `.deb` URL. Sourced by `20_configure_rstudio.sh` and by `r_env_manager.sh` upgrade flow. |

### Phase 3 — Web tier (Nginx / portal / SSL)

| Script | Config | Purpose |
|---|---|---|
| `15_setup_nginx_cleanup.sh` | — | Daily cron job to clean Nginx `client_body_temp` / `proxy_temp` files. Includes free-disk safety check before unlinking. |
| `30_install_nginx.sh` | `config/install_nginx.vars.conf` | v2.5 final. Auto-detects active auth backend (SSSD or Samba) by parsing the join scripts and configs. Renders `nginx_site.conf.template`, `nginx_proxy_location.conf.template`, `nginx_ssl_*.conf.template`, `nginx_performance.conf.template`. Backup/restore/uninstall menu. |
| `31_optimize_system.sh` | `config/optimize_system.vars.conf` | High-performance Nginx kernel/sysctl tuning (worker_processes, worker_connections, timeouts). Renders `sysctl_optimization.conf.template`. **NB:** filename collides with `01_optimize_system.sh`; this one is web-tier only. |
| `31_setup_web_portal.sh` | — | Deploys the static portal SPA to `/var/www/html/`, renders `portal_index.html.template`, `portal_style.css.template`, `terminal_wrapper.html.template`, `nextcloud_wrapper.html.template`, `rstudio_wrapper.html.template`, `server_status_wrapper.html.template`. Feature flag `INCLUDE_TELEMETRY_STRIP` toggles the live CPU/RAM strip (requires Phase 4). |
| `32_setup_letsencrypt.sh` | `config/install_nginx.vars.conf` (LE_* vars) | Production + staging Let's Encrypt issuance, auto-renew cron, status command. |

### Phase 4 — Telemetry & multi-node setup

| Script | Config | Purpose |
|---|---|---|
| `40_install_telemetry.sh` | — | Installs Node Exporter + custom FastAPI telemetry to `/etc/biome-calc/telemetry/` (NOT under `/home/`, to satisfy `ProtectHome` hardening). Python venv at `/opt/botanical-telemetry`. Systemd unit `botanical-telemetry.service`. |
| `50_setup_nodes.sh` | `config/setup_nodes.vars.conf` | **Authoritative node provisioner.** Idempotent steps with interactive menu and `--dry-run` / `--verify` modes: deploys OpenBLAS CORETYPE auto-detection, `/etc/R/Rprofile.site` + modular `Rprofile_site.d/` fragments (incl. v12.4 `52_mclapply_guard.R`), `/etc/R/Renviron.site` with double-path `R_LIBS_USER=/var/lib/biome-Rlibs/%u/%v:${HOME}/R/x86_64-pc-linux-gnu-library/%v`, kernel tuning, R packages, Python geospatial venv, optional Ollama AI, `r_minimal` launcher. v12.3 added **Step 8** `setup_nodes_compile_bundle` (deploy-time byte-compile of all `Rprofile_site.d/*.R` fragments via `compiler::cmpfile(optimize=3L)` into `/etc/R/Rprofile_site.d/.compiled/{bundle.Rc,manifest.txt}` with atomic stage→`mv -T` and md5 manifest; dispatcher fast-path validates manifest before load and silently demotes to legacy `sys.source()` loop on mismatch — PSE invariant: stale bundle never masks fragment changes). v12.4 added: **Step 7c** `setup_nodes_local_rlibs` (creates `/var/lib/biome-Rlibs/` Mode A rootfs / Mode B `mkfs+UUID-fstab` on `R_LIBS_LOCAL_DEVICE`; HC-14 fail-fast on chmod) and **Step 7d** `setup_nodes_audit_nfs` (read-only audit of `vers/nconnect/lookupcache`; never remounts). Wired into menu option `1` (full deploy) and new menu option **`L`** (Step 7c + 7d only). Templates rendered: `Rprofile_site.R.template`, `Rprofile_site.d/*.R.template`, `Renviron.template`, `00_audit_v28.R.template`, `Rprofile_site.minimal.R.template`. Flags: `--skip-ollama`, `--dry-run`, `--verify`, `--step <name>` (e.g. `compile_bundle`). |

---

## 3. Diagnostic & forensic toolbox (`scripts/99_*.sh`)

These do **not** mutate system state by default and are safe to run on
a production host. They are documented in detail in
`docs/operations/DIAGNOSTICS_INDEX.md`.

| Script | Purpose | Output |
|---|---|---|
| `99_audit_r_environment.sh` | Deploys `templates/00_audit_v28.R.template` and runs it via `Rscript`, or prints the deploy path for in-RStudio sourcing. | Markdown audit report under `${BIOME_CONF}/audit/`. |
| `99_check_pkg_drift.sh` | Wraps `scripts/tools/r_pkg_drift_detector.R`. Detects silent drift between baseline and live `installed.packages()`. PSE-mode: exit-code-meaningful, baseline on local disk. | Diff report + non-zero exit on drift. |
| `99_diagnose_lussu_hang.sh` | Lussu-specific overlay over the generic HC-13 harness. Adds (E) PSOCK swap probe and (F) `terra::terraOptions(todisk=TRUE,memfrac=0.2)` probe. **Does NOT modify the user's `.R` file.** | Per-probe stdout + crash dumps under `/tmp/lussu_diag_<TS>/`. |
| `99_diagnose_user_script.sh` | Generic HC-13 L0..L4 escalation harness. Runs the user script unmodified through 4 system layers (R minimal / Rprofile-only / fragments-off / full). | Verdict L0..L5; only L5 implies the user's script is at fault. |
| `99_health_check.sh` | v1.1.0. End-to-end service + config + AD reachability check, extended with BIOME-CALC v11+ Rprofile and audit v28 infrastructure assertions. | Pass/fail per check, exit-code-meaningful. |
| `99_postmortem_forensics.sh` | Crash-after-the-fact collector. `--user <name> [--hours N] [--output FILE]`. Classifies crash type, checks guard coverage, identifies unguarded edge cases, recommends fixes. | Structured diagnosis text report. |
| `99_troubleshoot_env.sh` | v1.3.0. Aggregates logs, system state, integration tests. `--rprofile` subsystem deep-check for Rprofile v11+ + audit v28. | Consolidated diagnostic dump. |
| `99_verify_domain_join.sh` | Domain join + home-dir mounting checks. Auto-detects SSSD vs Samba/Winbind. (Originally `01_check_autofs_sssd_pam.sh`.) | Pass/fail per probe. |
| `99_diagnose_lussu_hang.sh` (alt path) | (See above — first-class entry.) | — |

---

## 4. Helpers & launchers (`scripts/*.sh` not in the numbered chain)

| Script | Deployed to | Purpose |
|---|---|---|
| `r_minimal.sh` | `/usr/local/bin/r_minimal`, `/usr/local/bin/r_minimal_rscript` | HC-13 L0/L1 forensic launcher. Starts R/Rscript with `R_PROFILE_USER=/etc/R/Rprofile_minimal.R` so a sysadmin can prove a hang reproduces under pure R, **without** touching `/etc/R/Rprofile.site` on disk. Deployed by `50_setup_nodes.sh`. |
| `ttyd_login_wrapper.sh` | `/usr/local/bin/ttyd_login_wrapper.sh` | Login wrapper that ttyd execs. Logs to the `secure_access` directory and resolves the AD username. Deployed by `03_install_secure_access.sh`. |
| `test_rstudio_login.sh` | — | Manual smoke test: curl-driven RStudio plaintext login with multiple variations. Reads password interactively. Used post-deployment to confirm PAM stack works. |
| `update_nginx_templates.sh` | — | Re-renders all Nginx templates from current vars without re-running the full `30_install_nginx.sh`. Useful after editing a template. |

---

## 5. R helpers (`scripts/*.R`)

| Script | Purpose |
|---|---|
| `r_env_audit.R` | Library/version snapshot used by `r_env_manager.sh` to verify the R environment before/after operations. |
| `legacy_sysadmin_stress_test.R` | Reproducer harness for OpenBLAS-pthread SIGSEGV and CORETYPE regressions. Kept on disk for postmortem use only. |

---

## 6. Sub-trees

### `scripts/telemetry/`

Payload for `40_install_telemetry.sh` — the FastAPI app, systemd unit
template, and prometheus exporter glue. Inspect this directory before
modifying the telemetry container behavior.

### `scripts/tools/`

Standalone analytical tools (e.g. `r_pkg_drift_detector.R`) that are
invoked by the `99_*` runners. Not directly run by operators in the
normal flow.

---

## 7. Cross-references

* **PAM segfault story** → [`docs/deployment/PAM_HARDENING.md`](../deployment/PAM_HARDENING.md)
* **Lussu hang investigation** → [`docs/operations/LUSSU_HANG_BISECTION.md`](../operations/LUSSU_HANG_BISECTION.md)
* **HC-13 (Adapt System, Not User Script)** → `.ai/agents.md` §6.6 + [`docs/operations/USER_SCRIPT_TROUBLESHOOTING.md`](../operations/USER_SCRIPT_TROUBLESHOOTING.md)
* **Diagnostic ladder** → [`docs/operations/DIAGNOSTICS_INDEX.md`](../operations/DIAGNOSTICS_INDEX.md)
* **Per-config variable list** → [`CONFIGURATION_MAP.md`](CONFIGURATION_MAP.md)
* **Per-template usage** → [`TEMPLATE_GALLERY.md`](TEMPLATE_GALLERY.md)
