<!-- docs/developer/SCRIPTS_REFERENCE.md -->
# Scripts Reference

This page describes the active script surface as of 2026-10-06. T1 host scripts are authoritative and continuously fixed. For the generated catalog, see [`../reference/SCRIPT_CATALOG.md`](../reference/SCRIPT_CATALOG.md).

## Entry points

| File | Current role |
|---|---|
| `init.sh` | Makes `r_env_manager.sh` and `scripts/*.sh` executable, then launches `r_env_manager.sh` with `sudo`. It currently lacks strict mode and checked `chmod`; this is an open audit defect. |
| `r_env_manager.sh` | Version 2.0.0 interactive orchestrator. Loads `config/r_env_manager.conf`, holds `/var/run/r_env_manager.sh.lock`, logs under `/var/log/biome-log/core/`, records state under `/var/lib/r_env_manager/`, and can launch executable root-level shell scripts from `scripts/`. |

The launcher sorts executable `scripts/*.sh` by filename. It does not recurse into `scripts/tools/`. `03_install_secure_access.sh` and `30_install_nginx.sh` receive special dispatch; other entries are run without arguments.

## Numbered deployment scripts

The intended T1 ordering is `01..03 -> 10 or 11 -> 12 -> 13 -> 15 -> 20/21 -> 30..32 -> 40 -> 50`. Identity backends are mutually exclusive: use SSSD or Samba/Winbind, never both.

| Script | Role |
|---|---|
| `01_optimize_system.sh` | Base VM/system tuning using `config/optimize_system.vars.conf` and optional Proxmox values. |
| `02_configure_time_sync.sh` | Configures chrony/NTP. Time synchronization precedes Kerberos operations. |
| `03_install_secure_access.sh` | Installs, uninstalls, or checks the host secure-access/web-terminal services. Source header version: 16.1. |
| `10_join_domain_sssd.sh` | SSSD/realmd AD join and SSSD, Kerberos, NSS, PAM configuration. Uses site-local SSSD/Kerberos configuration. |
| `11_join_domain_samba.sh` | Alternative Samba/Winbind AD join. Its prerequisite path purges detected SSSD packages, but a symmetric fail-fast backend-XOR gate is still absent. |
| `12_lib_kerberos_setup.sh` | Kerberos package and `krb5.conf` setup from site-local configuration. |
| `13_harden_pam_password.sh` | Applies the PAM password/segfault hardening. Overlaps substantially with `fix_pam_segfault_inplace.sh`. |
| `15_setup_nginx_cleanup.sh` | Removes conflicting pre-install Nginx state. |
| `20_configure_rstudio.sh` | Configures RStudio Server, PAM, user directories/login bootstrap, global temp/session environment, and related paths. |
| `21_helper_rstudio_version.sh` | Fetches and prints current RStudio Server version/download information for the orchestrator. |
| `30_install_nginx.sh` | Installs and configures Nginx with detected SSSD or Samba auth context. Source header date/version: 2025-11-10. |
| `31_optimize_system.sh` | Post-install sysctl and Nginx performance tuning. |
| `31_setup_web_portal.sh` | Deploys the portal HTML/CSS/assets and `lib/biome-portal.js`. The duplicate `31_` prefix remains an open ordering defect. |
| `32_setup_letsencrypt.sh` | Certbot installation, certificate acquisition, renewal, status, and revocation operations. |
| `40_install_telemetry.sh` | Deploys the telemetry payload and service and verifies the API. |
| `50_setup_nodes.sh` | Deploys the R runtime, serial OpenBLAS, local `/Rtmp`, swap, Python/R packages, local R libraries, Rprofile v12.11 fragments, cgroups, audit/logging, orphan cleanup, archive manager, admin tools, HC-13 tools, and optional Ollama. |

## Diagnostics and repair scripts

| Script | Role/version when declared |
|---|---|
| `99_health_check.sh` | Host services, TLS, AD, Nginx, storage, `/Rtmp`, Rprofile, serial BLAS/OpenMP, user layout, and cgroups. Version 1.2.0. |
| `99_audit_r_environment.sh` | Deploys/runs the R environment audit and summarizes results. |
| `99_check_pkg_drift.sh` | Checks installed R package drift. |
| `99_check_rprofile_health.sh` | Deep Rprofile/user-startup health and controlled repair tool. Script-level health version 2.0. |
| `99_check_user_renviron_overrides.sh` | Reports user `.Renviron` values that override managed runtime settings. |
| `99_diagnose_user_script.sh` | HC-13 layer bisection without rewriting the supplied R script. Harness version 1.4. |
| `99_diagnose_lussu_hang.sh` | Focused Lussu hang bisection harness. Version 1.6. |
| `99_postmortem_forensics.sh` | Incident evidence collector and diagnosis report. Version 2.1.0. |
| `99_troubleshoot_env.sh` | Symptom-oriented environment troubleshooting and bundle collection. Version 1.4.0. |
| `99_verify_domain_join.sh` | Domain-join verification. |
| `99_botanical_plot_stress_test.R` | Botanical plot rendering stress test. |
| `99_diagnose_rstudio_plot_pane.R` | RStudio plot-pane diagnostic. |
| `r_minimal.sh` | Runs R with the minimal forensic environment used by HC-13 diagnostics. |
| `test_rstudio_login.sh` | Direct and Nginx RStudio login probes. It still places the entered password in curl arguments and is not strict-mode compliant; use only with that risk understood. |
| `fix_login_script_rlibs_inplace.sh` | Controlled in-place repair of login-script R library handling. |
| `fix_pam_segfault_inplace.sh` | Standalone PAM segfault repair; overlaps `13_harden_pam_password.sh`. |
| `pin_r_version.sh` | Manages apt pinning for R packages using `config/pin_r_version.vars.conf`. The current hardcoded default `4.6.0` is an open SSOT finding. |
| `ttyd_login_wrapper.sh` | Login wrapper used by the secure-access/ttyd path. |
| `update_nginx_templates.sh` | Nginx template maintenance helper. |

Supporting R files in `scripts/` are `r_env_audit.R` and `legacy_sysadmin_stress_test.R`. The latter is explicitly legacy by name and is not a numbered deployment phase.

## `scripts/tools/`

These tools are not shown by the root script launcher:

| File | Role |
|---|---|
| `bigger_usage_reports.sh` | Larger usage report generation. |
| `check_installed_R_Package.sh` and `.R` | Installed R package checks. |
| `check_pkg_config.sh` | Package configuration checks. |
| `check_processor_threads.sh` | Processor/thread reporting. |
| `deployment_summary.sh` | Deployment summary. |
| `hotfix_smtp_site_overrides.sh` | Applies the shared mail-overlay patch to an already deployed host. |
| `hw_report.sh` | Hardware report. |
| `manage_r_sessions.sh` | R session administration. |
| `r_pkg_drift_detector.R` | R implementation supporting package-drift checks. |
| `wiki/make_reference_docx.py` | Existing Python DOCX-generation support under `scripts/tools/wiki/`. |

## Supporting libraries

`50_setup_nodes.sh` deploys `scripts/lib/r_lint.R`, `scripts/lib/r_lint_rules.tsv`, and `scripts/lib/r_smoke.R` as part of the HC-13/admin tooling surface.

## Current compliance notes

- `RPROFILE_VERSION` is `12.11`.
- `99_troubleshoot_env.sh` is version `1.4.0`.
- Several scripts still have strict mode commented out: `12_lib_kerberos_setup.sh`, `15_setup_nginx_cleanup.sh`, `20_configure_rstudio.sh`, `31_setup_web_portal.sh`, `99_verify_domain_join.sh`, `test_rstudio_login.sh`, and `ttyd_login_wrapper.sh`. `50_setup_nodes.sh` and several diagnostics use `set -euo` without `pipefail`. These remain open HC-03 defects.
- All tracked root-level shell scripts currently have executable mode except `scripts/test_rstudio_login.sh`, which is tracked as `100644`.
- The sandbox is broken and must not be cited as the validation path.
- `src/biome_core_rust` is dormant and must not be activated.

Unverified: this audit established script presence, source roles, declared versions, and Git modes; it did not execute privileged scripts or confirm live service behavior.
