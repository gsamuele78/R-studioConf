<!-- docs/DOCUMENTATION_AUDIT.md -->
# Documentation Audit Register — R-studioConf / BIOME-CALC

> **Purpose:** Central registry of every Markdown document under `docs/`, tracking
> its current status, intended audience, and remediation actions.
> **Last full audit:** 2026-06-08
> **Authoritative sources used for verification:**
>
> - `.ai/agents.md` v3.0.0 (architecture, invariants, anti-patterns)
> - `.ai/project.yml` (tier model, constraints, R runtime)
> - `config/setup_nodes.vars.conf` (RPROFILE_VERSION=12.10, runtime params)
> - `config/r_env_manager.conf` (package governance)
> - `templates/Rprofile_site.R.template` v12.3+ (dispatcher, fragment loader)
> - `templates/Rprofile_site.d/*.R.template` (fragment inventory)
> - `docker-deploy/docker-compose.yml` (T2 service inventory)

## Status Legend

| Status | Meaning |
|--------|---------|
| `current` | Up to date with authoritative sources; minor typo/formatting fixes only |
| `needs-minor` | Mostly correct; needs small updates (version numbers, link fixes) |
| `needs-rewrite` | Materially stale or wrong; needs substantive rewrite |
| `legacy-context` | Describes a former state; keep as historical reference with a banner |
| `archive` | No longer relevant; move to `docs/archive/` or delete |
| `interim` | Created during this audit; must be updated as fixes land |

## Audience Legend

| Audience | Description |
|----------|-------------|
| `researcher` | Botanists, ecologists, data scientists running R on BIOME-CALC |
| `sysadmin` | IT officer deploying and maintaining the platform |
| `operator` | Day-2 operations, monitoring, troubleshooting |
| `developer` | Contributors modifying scripts, templates, or compose files |
| `architect` | Evaluating system design and future evolution |
| `internal` | Operator-only; must not appear in researcher-facing wiki |

---

## 1. Top-Level Docs

| File | Status | Audience | Issues | Action |
|------|--------|----------|--------|--------|
| `docs/README.md` | `needs-minor` | all | HC list says HC-1..HC-17 (should be HC-01..HC-15); mentions TTYD/Nextcloud in component list; `user_guides/` section missing `PARALLEL_R_DOS_AND_DONTS.md` and `risposta_ricercatore_sessioni_rstudio.md` and `rstudio_session_isolation.md` | Update HC list; remove TTYD/Nextcloud from current scope; add missing user guide links; update last-audit date |
| `docs/FUTURE_MIGRATION.md` | `needs-minor` | architect, sysadmin | Generally accurate T1/T2/T3 model; references `rocker/geospatial:4.4.1` but actual Dockerfile may differ; references `ollama/ollama:0.5.4` — verify against current compose | Verify pinned image versions; update OIDC section to reflect oauth2-proxy v7.6.0 |
| `docs/DOCUMENTATION_AUDIT.md` | `interim` | internal | This file; created during 2026-06-08 audit | Keep updated as fixes land |

---

## 2. Architecture (`docs/architecture/`)

| File | Status | Audience | Issues | Action |
|------|--------|----------|--------|--------|
| `SYSTEM_OVERVIEW.md` | `needs-rewrite` | architect, sysadmin | Describes TTYD, Nextcloud, Basic Auth credential modal, header spoofing, "serverless frontend", "Control Plane", `/tmp` RAMDisk at 100G, "High Availability" — all legacy or inaccurate for current T1 | Rewrite to reflect current T1 production: RStudio Server + Nginx portal + OAuth2 proxy + SSSD/Samba + telemetry + Ollama; remove TTYD/Nextcloud/Basic Auth; explain actual `/Rtmp` 400GB ext4; remove marketing language |
| `SECURITY_MODEL.md` | `needs-rewrite` | architect, sysadmin | Describes Basic Auth with PAM, header spoofing, "untrusted browser / trusted gateway" — legacy model; references `ttyd`; race-condition section about `/tmp/setup.R` is historical but useful context | Rewrite for OAuth2 proxy + PAM/SSSD model; remove TTYD references; keep historical hardening context with clear "legacy" banner |
| `architecture_analysis.md` | `needs-minor` | architect, sysadmin | Good comparison of old vs BIOME-CALC; references Nextcloud, Ollama, `ask_ai()` which may or may not be current; "NIMBLE compile to NFS `$HOME/.nimble_compile`" is stale — current routing is `/Rtmp` per-process tempdir | Verify Ollama/`ask_ai()` status; update NIMBLE compile routing to current `/Rtmp` behavior; verify Nextcloud reference is accurate or mark as legacy |
| `USER_CONTRACT.md` | `needs-minor` | researcher, sysadmin | HC-13 formal definition; table of system wrappers is largely accurate for v12.3 but may need v12.4/v12.10 updates (mclapply guard, terra todisk, install blockers) | Add v12.4 fork guard; add v12.10 install block opt-in; verify fragment references |
| `rstudio_cluster_evolution_pki_iam_ood.md` | `needs-minor` | architect | Future-oriented analysis; correctly marks Positron as EVALUATION_PENDING, Kubernetes as SKELETON_NOT_READY; cross-references Infra-Iam-PKI sibling project — out of scope per HC-04 but architectural context is valid | Add banner: "This is a future-architecture analysis, not current production"; verify tier claims against `.ai/project.yml` |
| `rstudio_positron_june_2026_capability_audit.md` | `needs-minor` | architect | Thorough capability audit with official Posit sources; correctly notes Positron is desktop-only, Positron Pro requires Workbench; good production recommendations | Minor: verify RStudio OSS version claims against installed version; ensure "not in scope" markers are clear |

---

## 3. Components (`docs/components/`)

| File | Status | Audience | Issues | Action |
|------|--------|----------|--------|--------|
| `NGINX_GATEWAY.md` | `needs-rewrite` | sysadmin, developer | Describes `ngx_http_auth_pam_module`, Basic Auth, TTYD WebSocket, Nextcloud mapping — all legacy; "Control Plane" language; `ttyd` header trust model | Rewrite for current Nginx role: reverse proxy for RStudio + OAuth2 proxy sidecar; remove TTYD/Nextcloud; document proxy buffer/timeout tuning for RStudio sessions |
| `PORTAL_FRONTEND.md` | `needs-rewrite` | developer, sysadmin | Describes Basic Auth credential modal, auto-login to Nextcloud, `ttyd` URL injection; references `BiomeTelemetry` JS class which may or may not be current | Rewrite for glassmorphism portal with OAuth2 proxy; remove credential-handling JS; verify `lib/biome-portal.js` is current |
| `SERVICES_INTEGRATION.md` | `needs-rewrite` | sysadmin | Entirely about TTYD and Nextcloud service wiring — both may be out of current scope | Either archive (if TTYD/Nextcloud are removed) or rewrite for current service integrations: RStudio + SSSD/Samba + OAuth2 proxy + telemetry + Ollama |

---

## 4. Deployment (`docs/deployment/`)

| File | Status | Audience | Issues | Action |
|------|--------|----------|--------|--------|
| `INSTALLATION_GUIDE.md` | `needs-rewrite` | sysadmin | Must be verified against current `scripts/` chain (01..50), `init.sh`, `r_env_manager.sh`; likely stale on Rprofile version, script names, config paths | Verify each phase against current scripts; update to v12.10; add T2 docker-deploy path as alternative; remove sandbox references |
| `CONFIGURATION_REFERENCE.md` | `needs-rewrite` | sysadmin | Claims to be "thin wrapper around reference/CONFIGURATION_MAP.md" — verify; likely stale on RPROFILE_VERSION, cgroup vars, NFS audit vars | Sync with `reference/CONFIGURATION_MAP.md` after that file is updated |
| `PAM_HARDENING.md` | `needs-minor` | sysadmin | PAM segfault root cause + fix scripts; verify scripts still exist and match | Check `13_harden_pam_password.sh` and `fix_pam_segfault_inplace.sh` still exist; update references |
| `COMPOSE_OPERATOR_RUNBOOK.md` | `needs-rewrite` | operator | T2 docker compose runbook; must be verified against current `docker-deploy/docker-compose.yml` (profiles, services, healthchecks); likely stale on service names and env vars | Full verification against current compose file; update for Compose v2 format; add profile usage |
| `TIER_PROMOTION.md` | `needs-minor` | developer, sysadmin | Tier promotion rules; verify against `.ai/project.yml` tier_promotion_rule | Minor updates; ensure T1→T2→T3 flow is correct |

---

## 5. Operations (`docs/operations/`)

| File | Status | Audience | Issues | Action |
|------|--------|----------|--------|--------|
| `OPERATOR_QUICKSTART.md` | `needs-rewrite` | operator | One-page cheat-sheet; must verify all script references, paths, and commands against current T1 | Full verification; remove sandbox references; add `99_diagnose_user_script.sh` usage |
| `TROUBLESHOOTING.md` | `needs-rewrite` | operator | Symptom-indexed runbook; mentions RStudio, PAM, identity, storage, nginx, telemetry, ttyd — TTYD may be out of scope | Remove TTYD section if not current; verify all diagnostic paths; add Rprofile fragment failure patterns |
| `DIAGNOSTICS_INDEX.md` | `needs-rewrite` | operator | Every `99_*.sh` / `fix_*.sh` catalog; must verify each script still exists and its purpose matches | Verify against current `scripts/99_*` inventory; add `99_diagnose_user_script.sh`, `99_diagnose_lussu_hang.sh`, `99_diagnose_rstudio_plot_pane.R`, `99_botanical_plot_stress_test.R` |
| `MAINTENANCE.md` | `needs-rewrite` | operator | Daily/weekly/monthly/quarterly tasks; likely stale on R-version bump procedure, AD rotation | Verify all procedures against current scripts and configs |
| `UPGRADE_TO_v12.4.md` | `needs-minor` | operator | v12.4 upgrade runbook; historically accurate but version is old (current is 12.10); T2/T3 status may be stale | Add banner noting v12.4→v12.10 changes; recommend creating `UPGRADE_TO_v12.10.md` |
| `USER_QUOTAS_AND_RESOURCES.md` | `needs-rewrite` | operator, sysadmin | RAM/CPU/scratch quotas; must verify against current `config/setup_nodes.vars.conf` cgroup settings (v12.0 user slice limits) | Update for v12.0 cgroup user slice model; document MemoryHigh/MemoryMax/MemoryMin; remove old quota mechanisms |
| `USER_SCRIPT_TROUBLESHOOTING.md` | `needs-minor` | operator | HC-13 decision tree; largely accurate per `.ai/agents.md` §6.6 | Verify L0-L5 ladder matches `.ai/agents.md`; update script references |
| `LUSSU_HANG_BISECTION.md` | `needs-minor` | operator | Worked example; likely still accurate for historical context | Minor: verify script paths; add banner noting this is a worked example, not general procedure |
| `CLEAN_VM_BASELINE.md` | `needs-minor` | operator | L4 reference VM SOP; verify procedure | Minor updates |
| `add_storage_no_reboot.md` | `needs-minor` | operator | Hot-add NFS/disk; verify procedure | Minor updates |
| `diagnostic_logs.md` | `needs-minor` | operator | Log location reference; verify paths | Update log paths if any have changed |
| `sysadmin_troubleshooting_guide.md` | `needs-rewrite` | sysadmin | Long-form handbook; likely overlaps with TROUBLESHOOTING.md and DIAGNOSTICS_INDEX.md | Consolidate or differentiate; update for current T1 |

---

## 6. Reference (`docs/reference/`)

| File | Status | Audience | Issues | Action |
|------|--------|----------|--------|--------|
| `SCRIPT_CATALOG.md` | `needs-rewrite` | developer, sysadmin | Complete inventory of `scripts/`, `lib/`, `init.sh`, `r_env_manager.sh`, `Makefile`; likely stale | Verify against current script inventory from `.ai/agents.md` §5; add `99_diagnose_user_script.sh` and newer scripts |
| `CONFIGURATION_MAP.md` | `needs-rewrite` | sysadmin, developer | Every `*.vars.conf` + `r_env_manager.conf`; materially stale for RPROFILE_VERSION (now 12.10), Rprofile dispatcher version, NFS audit variable names, hard-constraint IDs (HC-18 is legacy) | Full rewrite against current config files; update constraint IDs to HC-01..HC-15; add R_LIBS_LOCAL vars (v12.4+); add NFS audit vars (v12.4) |
| `TEMPLATE_GALLERY.md` | `needs-rewrite` | developer | Current vs legacy templates, modular Rprofile_site.d/ chain; fragment inventory likely stale (v12.3 adds 04_, 42_, 52_, 55_; v12.4 adds mclapply guard) | Update fragment inventory to match `templates/Rprofile_site.d/`; remove legacy templates that are archived |
| `NGINX_AUTH_BACKENDS.md` | `needs-minor` | sysadmin | SSSD vs Samba PAM integration; verify technical accuracy | Minor: verify PAM stack details; add OAuth2 proxy as auth frontend |
| `Rprofile_site.CHANGELOG.md` | `needs-rewrite` | developer, sysadmin | Version history; must cover v12.3 (byte-compiled bundle), v12.4 (fork guard, NFS lookup-storm), v12.5 (per-user thread guard log), v12.6 (R_LIBS_LOCAL warmup), v12.8 (UID gate fix), v12.9 (NFS-side enumeration), v12.10 (install block opt-in) | Add all missing versions; verify each entry has CONTEXT, ARCHITECTURE, WHAT CHANGED, VERIFICATION, ROLLBACK, TIER DELTAS per HC-14 |

---

## 7. Developer (`docs/developer/`)

| File | Status | Audience | Issues | Action |
|------|--------|----------|--------|--------|
| `README.md` | `needs-minor` | developer | Developer onboarding; verify against current toolchain | Minor updates |
| `SCRIPTS_REFERENCE.md` | `needs-rewrite` | developer | Code-level script reference; likely stale | Verify against current scripts |
| `LIBRARY_REFERENCE.md` | `needs-minor` | developer | `lib/common_utils.sh`, `lib/biome-portal.js`; verify functions are current | Verify function inventory |
| `TEMPLATES_REFERENCE.md` | `needs-rewrite` | developer | Template authoring rules; must reflect v12.3+ fragment model and HC-14 constraints | Update for fragment authoring, placeholder substitution, version bump rules |
| `CONFIGURATION_REFERENCE.md` | `needs-minor` | developer | Adding new `.vars.conf` keys; verify procedure | Minor updates |
| `git_submodule_workflow.md` | `needs-minor` | developer | Infra-Iam-PKI submodule rules; verify | Minor updates |

---

## 8. User Guides (`docs/user_guides/`)

| File | Status | Audience | Issues | Action |
|------|--------|----------|--------|--------|
| `BOTANIST_CHEATSHEET.md` | `needs-rewrite` | researcher | One-page quick reference; must be verified for accuracy and simplicity | Ensure only normal R + approved public helpers; remove internal `.biome_*` refs; ensure `/Rtmp` usage is clear |
| `User_guide.md` | `needs-rewrite` | researcher | Full Italian-language HPC guide; likely contains stale paths, old VM references, sysadmin commands | Full review; remove sysadmin commands; update for current platform behavior |
| `understanding_the_new_server.md` | `needs-rewrite` | researcher | Why the server behaves as it does; must match current cgroup, `/Rtmp`, NFS, and threading model | Rewrite for accuracy; remove outdated explanations |
| `PARALLEL_R_DOS_AND_DONTS.md` | `needs-rewrite` | researcher, operator | Valuable lint rule reference but too operator/linter-oriented; exposes `.biome_make_cluster` (should be `biome_make_cluster`); references `99_diagnose_user_script.sh` which researchers should not run | Reposition as researcher-facing "safe parallel R" guide; remove operator script invocations; use only approved public helpers; keep lint rule structure but simplify language |
| `NIMBLE_User_Guide.md` | `needs-rewrite` | researcher | Parallel MCMC guide; verify NIMBLE compile routing, thread caps, PSOCK patterns against current runtime | Update for current NIMBLE behavior; ensure `compileNimble` wrapper and `/Rtmp` routing are correctly described |
| `large_spatial_matrices.md` | `needs-rewrite` | researcher | `terra`/`sf` workflows for large rasters; verify memory guards, tempdir routing | Update for current `terra` hooks, `/Rtmp` routing, and `todisk` default |
| `SERVER_NATIVE_API.md` | `needs-rewrite` | researcher, operator | `biome_*()` helpers; currently mixes researcher-visible and internal helpers | Split: researcher-visible helpers stay; internal `.biome_*` and operator toggles move to `docs/reference/`; add clear "Do not call directly" section for wrappers |
| `rstudio_session_isolation.md` | `needs-minor` | researcher | Session isolation explanation; verify against current behavior | Minor updates |
| `risposta_ricercatore_sessioni_rstudio.md` | `needs-minor` | researcher | Italian-language session explanation; verify accuracy | Minor updates |

---

## 9. Specialized Guides

| File | Status | Audience | Issues | Action |
|------|--------|----------|--------|--------|
| `archiver/BIOME_Admin_Guide.md` | `needs-minor` | operator | Archive admin guide; verify against current archiver config in `config/setup_nodes.vars.conf` §6 | Minor updates |
| `orphan_cleanup/BIOME_Orphan_Cleanup_Guide.md` | `needs-minor` | operator | Orphan cleanup playbook; verify against current orphan config in `config/setup_nodes.vars.conf` §5 | Minor updates |

---

## 10. Non-Markdown Files

| File | Status | Action |
|------|--------|--------|
| `docs/2023.conference.escience.r-containerization.camera.pdf` | `legacy-context` | Historical conference paper; keep as reference, not linked from main index |

---

## Summary Counts

| Status | Count |
|--------|-------|
| `current` | 0 |
| `needs-minor` | 19 |
| `needs-rewrite` | 28 |
| `legacy-context` | 1 |
| `archive` | 0 |
| `interim` | 1 |
| **Total Markdown files** | **49** |

---

## Cross-Cutting Issues

These issues affect multiple files and should be addressed systematically:

### CI-1: Stale `/tmp` references

Many files reference `/tmp` as the R scratch location. Authoritative source is `/Rtmp` (400GB ext4 local disk). **Search pattern:** `\b/tmp\b` in contexts implying large R temp storage.

### CI-2: OpenBLAS pthread references

Some files may reference or suggest `libopenblas0-pthread`. Authoritative requirement is `libopenblas0-serial`. **Search pattern:** `pthread` in BLAS context.

### CI-3: Sandbox validation claims

The Vagrant/libvirt sandbox is KNOWN BROKEN. Any doc referencing sandbox as a validation path must be corrected. **Search pattern:** `sandbox`, `vagrant`.

### CI-4: TTYD / Nextcloud scope

These services may no longer be in current platform scope. Docs describing them as current must be rewritten or marked legacy. **Search pattern:** `ttyd`, `TTYD`, `nextcloud`, `Nextcloud`.

### CI-5: Tier maturity language

T1 = AUTHORITATIVE_CONTINUOUSLY_FIXED, T2 = MIGRATION_IN_PROGRESS, T3 = SKELETON_NOT_READY. Docs using "production", "enterprise-grade", or implying T2/T3 are production-ready must be corrected.

### CI-6: Marketing/overconfident language

Terms like "zero attack surface", "serverless", "High Availability", "zero data loss", "enterprise-grade" must be replaced with honest, specific technical descriptions.

### CI-7: RPROFILE_VERSION consistency

Current version is 12.10. All docs referencing a different version must be updated.

### CI-8: Hard Constraint numbering

Authoritative constraints are HC-01 through HC-15 (per `.ai/project.yml`). Docs referencing HC-16, HC-17, HC-18, or unnumbered constraints must be updated.

### CI-9: Docker Compose format

Must use "docker compose" (space), Compose v2 (no `version:` key). Docs using "docker-compose" (hyphen) or `version:` must be corrected.

### CI-10: Fragment inventory

Current fragments (from `templates/Rprofile_site.d/`): `04_user_lib_bootstrap`, `05_thread_guard`, `20_cgroup_reader`, `30_psock_factory`, `35_compile_routing`, `40_wrapper_installer`, `42_install_block`, `45_memory_guards`, `50_pkg_hooks`, `52_mclapply_guard`, `55_options_guard`, `60_safe_setwd`, `70_persistent_tools`, `80_tools_ext`.

---

*This register is hand-maintained. Update statuses as remediation actions are completed.*
