<!-- docs/DOCUMENTATION_AUDIT.md -->
# Documentation Audit Register — R-studioConf / BIOME-CALC

> **Purpose:** status of every Markdown document under `docs/`: is it
> current against the code, who reads it, what is still open.
> **Last full audit:** 2026-10-07 (previous: 2026-06-08).
> **Ground truth used:** `scripts/`, `lib/common_utils.sh`, `templates/`
> (incl. `Rprofile_site.d/*.R.template`), `config/*.conf` (+ `*.example`),
> `r_env_manager.sh`, `.ai/project.yml`, `CHANGELOG.md`,
> `reference/Rprofile_site.CHANGELOG.md`, `git log`.
> Facts at audit time: `RPROFILE_VERSION=12.10`; `99_troubleshoot_env.sh`
> 1.4.0; homes on TrueNAS SCALE (`zpool/home`, NFSv4.2) with per-user ZFS
> quotas; T1 authoritative, T2 migration in progress, T3 skeleton.

## Status legend

| Status | Meaning |
|---|---|
| `current` | Claims checked against the code in this audit |
| `checked` | Mechanical checks passed (every script/template/config path, R function, `biome.*`/`BIOME_*` name exists; versions match); prose not re-read line by line |
| `historical` | Record of a past rollout or incident, kept unchanged with a status banner |
| `needs-review` | Procedure kept as written but not re-validated in this audit |

## How the 2026-10 audit was run

1. Five parallel audits, one per area; each edited only its own folder.
2. Two of them (operations, developer/misc) timed out mid-run and two
   (deployment/components/reference, user guides) stopped on quota errors.
   Their partial edits were reviewed by hand. Six documents that had been
   condensed from historical records or step-by-step procedures into
   summaries were **restored from git** and given a status banner instead,
   because the summaries dropped real procedures (e.g. the Clean-VM
   provisioning script, the archiver deploy steps, the v12.4 rollout).
3. Mechanical checks run on every edited file (see `checked` above). No
   file outside `docs/` was changed by the audit; the wiki build tool is new.

## 1. Top level

| File | Status | Notes |
|---|---|---|
| `README.md` | `current` | Role-indexed map; HC list now HC-01..HC-15 per `.ai/project.yml`; includes `COMMON_PROBLEMS.md` and `wiki/` |
| `FUTURE_MIGRATION.md` | `checked` | Roadmap; image pins aligned with Dockerfiles |
| `SHAREPOINT_PUBLICATION.md` | `current` | §3.2 documents the implemented docx build |
| `DOCUMENTATION_AUDIT.md` | `current` | This file |

## 2. Architecture

| File | Status | Notes |
|---|---|---|
| `SYSTEM_OVERVIEW.md` | `current` | Rewritten against templates/scripts (was `needs-rewrite`) |
| `SECURITY_MODEL.md` | `current` | Rewritten (was `needs-rewrite`: legacy Basic-Auth/header-spoofing model) |
| `USER_CONTRACT.md` | `current` | Updated for v12.4–v12.10 wrappers |
| `architecture_analysis.md` | `checked` | |
| `rstudio_cluster_evolution_pki_iam_ood.md` | `checked` | Future analysis; condensed by the audit, statuses (Positron EVALUATION_PENDING, K8s SKELETON_NOT_READY) kept |
| `rstudio_positron_june_2026_capability_audit.md` | `checked` | Dated capability audit |

## 3. Components / 4. Deployment / 6. Reference

| File | Status | Notes |
|---|---|---|
| `components/NGINX_GATEWAY.md`, `PORTAL_FRONTEND.md`, `SERVICES_INTEGRATION.md` | `needs-review` | Path checks pass; prose not re-audited (audit stopped) |
| `deployment/INSTALLATION_GUIDE.md` | `checked` | |
| `deployment/CONFIGURATION_REFERENCE.md` | `checked` | Fixed: notification files live in `config/site/` (site overlay, `resolve_site_config`) |
| `deployment/COMPOSE_OPERATOR_RUNBOOK.md`, `TIER_PROMOTION.md`, `PAM_HARDENING.md` | `needs-review` | Paths are relative to `docker-deploy/` and exist |
| `reference/SCRIPT_CATALOG.md` | `current` | Now lists every script in `scripts/`, `scripts/tools/`, `scripts/lib/`; `99_health_check.sh` version fixed to 1.2.0 |
| `reference/TEMPLATE_GALLERY.md` | `checked` | Every template in `templates/` listed; no nonexistent entries |
| `reference/CONFIGURATION_MAP.md`, `NGINX_AUTH_BACKENDS.md` | `checked` | |
| `reference/Rprofile_site.CHANGELOG.md` | `current` | Historical log, not edited |

## 5. Operations

| File | Status | Notes |
|---|---|---|
| `TROUBLESHOOTING.md` | `current` | Symptom → diagnosis → fix → verification for every incident in the history; §4.3 CIFS project share, §4.4 ZFS quota (EDQUOT) |
| `DIAGNOSTICS_INDEX.md` | `current` | Every `99_*`, `fix_*`, `tools/*` script listed |
| `OPERATOR_QUICKSTART.md`, `MAINTENANCE.md`, `USER_QUOTAS_AND_RESOURCES.md`, `USER_SCRIPT_TROUBLESHOOTING.md`, `add_storage_no_reboot.md`, `diagnostic_logs.md` | `current` | |
| `UPGRADE_TO_v12.4.md` | `historical` | Restored in full; banner points to v12.10 |
| `LUSSU_HANG_BISECTION.md`, `NGINX_AUTH_PAM_REGRESSION_2026-06.md` | `historical` | Incident records, restored in full |
| `sysadmin_troubleshooting_guide.md` | `needs-review` | v10.0-era handbook, restored; `TROUBLESHOOTING.md` wins on conflict |
| `CLEAN_VM_BASELINE.md` | `needs-review` | SOP restored; provisioning not re-run |
| `rstudio_session_isolation.md` | `checked` | Moved from `user_guides/` (sysadmin investigation record) |
| `risposta_ricercatore_sessioni_rstudio.md` (IT) | `historical` | Moved from `user_guides/`: a reply to one researcher, internal record |

## 7. Developer

| File | Status | Notes |
|---|---|---|
| `developer/*.md` | `checked` | Function list matches `lib/common_utils.sh`; `git_submodule_workflow.md` refers to the consumer repo `Infra-Iam-PKI` |

## 8. User guides

| File | Status | Notes |
|---|---|---|
Researcher pages follow one rule set: no names of users, no incident
reports, no admin scripts or configuration files, no server internals
(cgroups, storage backend, profile fragments); only steps a researcher can
run in R or in the portal; every R code block parses (checked with
`parse()`).

| File | Status | Notes |
|---|---|---|
| `COMMON_PROBLEMS.md` | `current` | **New**, plain language. Quoted messages match the templates; login described as AD username/password (T1 has no OIDC) |
| `understanding_the_new_server.md` | `current` | Rewritten as "How BIOME-CALC works for you"; removed unverifiable storage claims (RAID-Z2, snapshots) |
| `BOTANIST_CHEATSHEET.md` | `current` | Rewritten without jargon; `nimble.dirName` advice removed (NIMBLE never reads that option) |
| `PARALLEL_R_DOS_AND_DONTS.md` | `current` | `BIOME_USER_TMP`/`BIOME_SMOKE_*`/`BIOME_DATA_DIR` replaced by portable `tempdir()`; wrong claim "makeCluster defaults to FORK" fixed (default is PSOCK); project share path fixed to `/mnt/ProjectStorage`; `buildMCMC()` example fixed |
| `large_spatial_matrices.md` | `current` | NFS-fallback section removed; terra temp is `/Rtmp/biome_<user>/terra` |
| `NIMBLE_User_Guide.md` | `current` | Server-specific `biome_make_cluster()` dropped from the user command list |
| `User_guide.md` (IT) | `current` | Rewritten in Italian, same content as the English guides; removed a developer-workstation path, nonexistent variables, OIDC claim, unverifiable hardware figures |
| `SERVER_NATIVE_API.md` | `checked` | Power-user/admin helpers; moved to the Operations hub |

## 9. Specialized guides

| File | Status | Notes |
|---|---|---|
| `archiver/BIOME_Admin_Guide.md` (IT) | `needs-review` | Restored in full; not re-validated against the archive templates |
| `archiver/BIOME_Guida_Archiviazione.docx` | hand-maintained | Not generated |
| `orphan_cleanup/BIOME_Orphan_Cleanup_Guide.md` | `checked` | Site overlay paths `config/site/*` |
| `audits/T1_HOST_DEPLOYMENT_AUDIT.md` | `checked` | Open/fixed defects re-checked against `git log`; link to the unmerged triage doc replaced by its branch name |

## 10. Generated

| Path | Notes |
|---|---|
| `wiki/manifest.tsv` | Chapter list for the four wiki docx |
| `wiki/*.docx` | Built by `scripts/tools/build_wiki_docx.sh`; never edit by hand |

## Open items

- Re-audit the prose of `components/*` and the `needs-review` deployment runbooks.
- Re-validate `CLEAN_VM_BASELINE.md` and `archiver/BIOME_Admin_Guide.md` on a real VM / node.
- Retire or rewrite `operations/sysadmin_troubleshooting_guide.md` (v10.0).
