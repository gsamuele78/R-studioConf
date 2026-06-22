<!-- docs/README.md -->
# BIOME-CALC / R-studioConf — Documentation Index

Welcome to the technical documentation library for **BIOME-CALC**
(RStudio Server + Nginx Portal + OIDC/SSSD/Samba), the host-tier (T1)
authoritative deployment of the *botanical big-data calculus* platform.

> **Tier model.**
> **T1 = host (this repo)** — `AUTHORITATIVE_CONTINUOUSLY_FIXED`.
> T2 = `docker-deploy/` — mirror of T1, migration in progress.
> T3 = `kubernetes-deploy/` — skeleton, not production-ready.
> Bugs are fixed in **T1 first**, then ported forward.

---

## 🧭 Read me first by role

| If you are…                                | Start here                                                                                                                                            |
|--------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------|
| 👤 **End-user / botanist** (just want to run R) | [`user_guides/BOTANIST_CHEATSHEET.md`](user_guides/BOTANIST_CHEATSHEET.md) → [`user_guides/User_guide.md`](user_guides/User_guide.md)                  |
| 🧑‍💻 **Sysadmin** deploying or upgrading a host | [`deployment/INSTALLATION_GUIDE.md`](deployment/INSTALLATION_GUIDE.md) → [`deployment/CONFIGURATION_REFERENCE.md`](deployment/CONFIGURATION_REFERENCE.md) |
| 🛠️ **Operator** doing day-2 work                 | [`operations/OPERATOR_QUICKSTART.md`](operations/OPERATOR_QUICKSTART.md) → [`operations/TROUBLESHOOTING.md`](operations/TROUBLESHOOTING.md)            |
| 🚨 **On-call / incident**                       | [`operations/DIAGNOSTICS_INDEX.md`](operations/DIAGNOSTICS_INDEX.md) → [`operations/USER_SCRIPT_TROUBLESHOOTING.md`](operations/USER_SCRIPT_TROUBLESHOOTING.md) |
| 🧱 **Developer** changing scripts / templates   | [`developer/README.md`](developer/README.md) → [`reference/SCRIPT_CATALOG.md`](reference/SCRIPT_CATALOG.md)                                            |
| 🏗️ **Architect** evaluating the design         | [`architecture/SYSTEM_OVERVIEW.md`](architecture/SYSTEM_OVERVIEW.md) → [`architecture/architecture_analysis.md`](architecture/architecture_analysis.md) |

---

## 📚 Full Documentation Tree

### 1. Architecture (`architecture/`)

- [`SYSTEM_OVERVIEW.md`](architecture/SYSTEM_OVERVIEW.md) — high-level component diagram, data flow.
- [`SECURITY_MODEL.md`](architecture/SECURITY_MODEL.md) — auth flows, isolation, Nginx hardening.
- [`USER_CONTRACT.md`](architecture/USER_CONTRACT.md) — formal HC-13 ("adapt the system, not the user script").
- [`architecture_analysis.md`](architecture/architecture_analysis.md) — cgroup model, CORETYPE, threading rationale.
- [`rstudio_cluster_evolution_pki_iam_ood.md`](architecture/rstudio_cluster_evolution_pki_iam_ood.md) — future-architecture analysis (PKI, IAM, Open OnDemand, Positron).
- [`rstudio_positron_june_2026_capability_audit.md`](architecture/rstudio_positron_june_2026_capability_audit.md) — RStudio OSS / Positron capability audit (June 2026).

### 2. Component Guides (`components/`)

- [`NGINX_GATEWAY.md`](components/NGINX_GATEWAY.md) — Nginx reverse proxy configuration, proxy buffer tuning for RStudio sessions.
- [`PORTAL_FRONTEND.md`](components/PORTAL_FRONTEND.md) — glassmorphism landing page, OAuth2 proxy integration.
- [`SERVICES_INTEGRATION.md`](components/SERVICES_INTEGRATION.md) — RStudio Server, SSSD/Samba, OAuth2 proxy, telemetry, Ollama wiring.

### 3. Deployment (`deployment/`)

- [`INSTALLATION_GUIDE.md`](deployment/INSTALLATION_GUIDE.md) — Ubuntu 24.04 from scratch, all 5 phases.
- [`CONFIGURATION_REFERENCE.md`](deployment/CONFIGURATION_REFERENCE.md) — thin wrapper around `reference/CONFIGURATION_MAP.md`.
- [`PAM_HARDENING.md`](deployment/PAM_HARDENING.md) — PAM segfault root cause + fix scripts (`13_harden_pam_password.sh`, `fix_pam_segfault_inplace.sh`).
- [`COMPOSE_OPERATOR_RUNBOOK.md`](deployment/COMPOSE_OPERATOR_RUNBOOK.md) — T2 docker compose runbook.
- [`TIER_PROMOTION.md`](deployment/TIER_PROMOTION.md) — promoting fixes T1 → T2 → T3.

### 4. Operations (`operations/`)

- [`OPERATOR_QUICKSTART.md`](operations/OPERATOR_QUICKSTART.md) — one-page cheat-sheet for day-2.
- [`TROUBLESHOOTING.md`](operations/TROUBLESHOOTING.md) — symptom-indexed runbook (RStudio, PAM, identity, storage, nginx, telemetry, escalation).
- [`DIAGNOSTICS_INDEX.md`](operations/DIAGNOSTICS_INDEX.md) — every `99_*.sh` / `fix_*.sh` (When / Mutates / Output / NextStep) + decision tree.
- [`MAINTENANCE.md`](operations/MAINTENANCE.md) — daily / weekly / monthly / quarterly tasks, R-version bump, AD rotation, rollback.
- [`UPGRADE_TO_v12.4.md`](operations/UPGRADE_TO_v12.4.md) — Rprofile v12.4 upgrade runbook (Lussu fork-guard + NFS lookup-storm fix).
- [`USER_QUOTAS_AND_RESOURCES.md`](operations/USER_QUOTAS_AND_RESOURCES.md) — RAM/CPU/scratch quotas, cgroup user slices, systemd resource controls.
- [`USER_SCRIPT_TROUBLESHOOTING.md`](operations/USER_SCRIPT_TROUBLESHOOTING.md) — debugging user R scripts without editing them (HC-13 compliant).
- [`LUSSU_HANG_BISECTION.md`](operations/LUSSU_HANG_BISECTION.md) — `mclapply`-on-`terra::rast` hang bisection (worked example).
- [`CLEAN_VM_BASELINE.md`](operations/CLEAN_VM_BASELINE.md) — clean-baseline VM template procedure (L4 reference).
- [`add_storage_no_reboot.md`](operations/add_storage_no_reboot.md) — hot-add NFS/disk.
- [`diagnostic_logs.md`](operations/diagnostic_logs.md) — log location reference.
- [`sysadmin_troubleshooting_guide.md`](operations/sysadmin_troubleshooting_guide.md) — long-form sysadmin handbook.

### 5. Reference (`reference/`)

- [`SCRIPT_CATALOG.md`](reference/SCRIPT_CATALOG.md) — complete inventory of `scripts/`, `lib/`, `init.sh`, `r_env_manager.sh`, `Makefile`.
- [`CONFIGURATION_MAP.md`](reference/CONFIGURATION_MAP.md) — every `*.vars.conf` + `r_env_manager.conf` + `scopri_progetti_known.conf` + admin/email maps.
- [`TEMPLATE_GALLERY.md`](reference/TEMPLATE_GALLERY.md) — current vs. legacy templates, modular `Rprofile_site.d/` chain, nginx, identity, orphan-cleanup, Proxmox.
- [`NGINX_AUTH_BACKENDS.md`](reference/NGINX_AUTH_BACKENDS.md) — SSSD vs. Samba PAM integration deep-dive.
- [`Rprofile_site.CHANGELOG.md`](reference/Rprofile_site.CHANGELOG.md) — `Rprofile_site` version history (R-runtime profile only).

> **Repo-wide changelog:** the general change history lives at the repository root,
> [`../CHANGELOG.md`](../CHANGELOG.md) (Keep a Changelog). The `Rprofile_site` log
> above is scoped to `RPROFILE_VERSION` bumps only (HC-14 / rule 18).

### 6. Developer (`developer/`)

- [`README.md`](developer/README.md) — developer onboarding.
- [`SCRIPTS_REFERENCE.md`](developer/SCRIPTS_REFERENCE.md) — code-level script reference.
- [`LIBRARY_REFERENCE.md`](developer/LIBRARY_REFERENCE.md) — `lib/common_utils.sh`, `lib/biome-portal.js`.
- [`TEMPLATES_REFERENCE.md`](developer/TEMPLATES_REFERENCE.md) — template authoring rules.
- [`CONFIGURATION_REFERENCE.md`](developer/CONFIGURATION_REFERENCE.md) — adding new `.vars.conf` keys.
- [`git_submodule_workflow.md`](developer/git_submodule_workflow.md) — Infra-Iam-PKI submodule rules.

### 7. User Guides (`user_guides/`)

- [`BOTANIST_CHEATSHEET.md`](user_guides/BOTANIST_CHEATSHEET.md) — **start here** as an end-user (1 page, 10 rules).
- [`User_guide.md`](user_guides/User_guide.md) — full Italian-language HPC guide for researchers.
- [`understanding_the_new_server.md`](user_guides/understanding_the_new_server.md) — why the server behaves as it does.
- [`PARALLEL_R_DOS_AND_DONTS.md`](user_guides/PARALLEL_R_DOS_AND_DONTS.md) — safe parallel R patterns on BIOME-CALC.
- [`large_spatial_matrices.md`](user_guides/large_spatial_matrices.md) — `terra` / `sf` workflows for > 50 GB rasters.
- [`NIMBLE_User_Guide.md`](user_guides/NIMBLE_User_Guide.md) — parallel MCMC on BIOME-CALC.
- [`SERVER_NATIVE_API.md`](user_guides/SERVER_NATIVE_API.md) — `biome_*()` helpers (advanced users).
- [`rstudio_session_isolation.md`](user_guides/rstudio_session_isolation.md) — how RStudio sessions are isolated.
- [`risposta_ricercatore_sessioni_rstudio.md`](user_guides/risposta_ricercatore_sessioni_rstudio.md) — Italian-language session FAQ.

### 8. Specialised guides

- [`archiver/BIOME_Admin_Guide.md`](archiver/BIOME_Admin_Guide.md) — long-term archive admin guide.
- [`orphan_cleanup/BIOME_Orphan_Cleanup_Guide.md`](orphan_cleanup/BIOME_Orphan_Cleanup_Guide.md) — orphan-file cleanup playbook.

### 9. Roadmap

- [`FUTURE_MIGRATION.md`](FUTURE_MIGRATION.md) — OIDC, Kubernetes, Ansible adoption path.

### 10. Meta

- [`DOCUMENTATION_AUDIT.md`](DOCUMENTATION_AUDIT.md) — central audit register tracking documentation status and remediation actions.

---

## 🔒 Hard Rules (HC-01..HC-15 — read before contributing)

The full list lives in `.clinerules` / `.cursorrules` / `.windsurfrules`
at the repo root, and in `.ai/project.yml`. The most consequential for documentation:

- **HC-13** — Adapt the system to portable user R code; **never silently
  patch user scripts**. Fixes go in `Rprofile_site.d/`, `Renviron`,
  cgroups, PAM — never in a `.R` written by the researcher.
- **HC-03** — Fix in T1 first, then port forward T1 → T2 → T3. Do not
  document a workaround in T2/T3 that masks a T1 defect.
- **HC-08** — `.env` files are never committed; templates use
  `%%PLACEHOLDERS%%` only.
- **HC-14** — `RPROFILE_VERSION` bumps must land with matching CHANGELOG
  section + cross-doc references in the same commit.

---

## 🛠️ Maintenance of this index

- This file is hand-edited; there is no generator.
- After adding/removing a document under `docs/`, **update the tree
  above** and the by-role table.
- Keep cross-references **relative** (`operations/X.md`), never absolute.
- The single Italian-language page is `user_guides/User_guide.md` —
  intentional, not a translation gap.

---

*Last full audit: 2026-06-08 — see `DOCUMENTATION_AUDIT.md` for detailed status.*
