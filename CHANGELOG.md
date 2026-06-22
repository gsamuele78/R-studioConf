# Changelog

All notable repo-wide changes are recorded here. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
R-runtime profile changes have their own log: [`docs/reference/Rprofile_site.CHANGELOG.md`](docs/reference/Rprofile_site.CHANGELOG.md).

## [Unreleased]

### Security

- **Site-local config overlay (PII/secret scrub).** AD topology, third-party PII,
  PI/contact emails, internal IPs and the AD group/OU prefixes were removed from
  all tracked files (T1 `scripts/`,`templates/`,`config/`,`lib/`,`tests/` and the
  T2 `docker-deploy/` mirror). Real values now live in the gitignored
  `config/site/` overlay; the repo ships sanitized `*.example` templates.
  - Added `resolve_site_config` / `assert_site_configured` to `lib/common_utils.sh`
    (fail-fast on the `__FILL_ME__` sentinel; warn routed to stderr).
  - De-tracked 6 config files (`admin_recipients.txt`, `user_email_map.txt`,
    `scopri_progetti_known.conf`, `lib_kerberos_setup.vars.conf`,
    `join_domain_{sssd,samba}.vars.conf`); working copies kept on disk.
  - `setup_nodes.vars.conf` keeps its 6 sensitive keys sanitized, overridden at
    deploy by `config/site/setup_nodes.site.vars.conf`.
  - Externalized the scopri theme→supervisor map (was hardcoded PII) to
    `config/site/scopri_theme_map.conf` (`templates/scopri_progetti.sh.template`
    now reads it; no match → `_UNKNOWN_`).
  - Parameterized `test_rstudio_login.sh` (username/IP via env); removed the
    hardcoded institutional mail domain from `telemetry_api.py` (sender domain now
    from `MAIL_DOMAIN` / `BIOME_MAIL_DOMAIN`) and `ttyd_login_wrapper.sh`
    (`TTYD_DOMAIN_SUFFIX`).
  - Scrubbed real names/IPs/UIDs from `docs/` (incl. consistent role placeholders),
    `.ai/agents.md`, `kubernetes-deploy/env/.env.example`; removed the stray
    `archive/docker-deploy/.env copy` and the pre-scrub archive original; untracked
    `plan/Test/` real-user research code (kept on disk).
  - Verified: full-tree `git grep` for every real token returns nothing in tracked
    files; fresh clone aborts on placeholder; live overlay resolves real values.
  - **Pending (operator):** real values still exist in **git history** until
    `git filter-repo` is run after merge — treat as already-disclosed. Migration
    runbook: [`plan/secret_scrub_site_overlay_plan.md`](plan/secret_scrub_site_overlay_plan.md);
    overlay reference: [`config/SITE_OVERRIDE.md`](config/SITE_OVERRIDE.md).

### Changed

- **Root `README.md` rewritten as an accurate thin landing page** (audit Phase 0.1).
  Replaced the stale `setup_r_env.sh` + `install/` + `/var/log/r_setup/` + `:8787`
  description (a layout that no longer exists) with the real `init.sh` →
  `r_env_manager.sh` entry point, the actual `scripts/`/`config/`/`templates/`/`lib/`
  layout and phase order, the T1/T2/T3 tier model, the `config/site/` overlay note,
  and an engineering-leverage section (cgroup slices, `/Rtmp`, local R-libs, BLAS-serial,
  OIDC gateway + the modular `Rprofile_site.d/` fragment kernel) linking to the deep
  docs. Audit markers in `docs/audits/T1_HOST_DEPLOYMENT_AUDIT.md` §5 / Phase 0.1
  flipped to `[FIXED]`.

### CI / Testing

- **Replaced the false-green CI** (audit Phase 0.2). Deleted
  `.github/workflows/test_setup_r_env.yml` — it drove the deleted `setup_r_env.sh`
  layout and wrapped every step in `|| true` (permanent false green). New
  `.github/workflows/ci.yml` runs 7 real jobs, no `|| true`:
  - `t1-static` — `make audit` (HC-01..11 constraints + IDE-rule sync +
    HC-14 doc coherence) + `bash -n` on every script + exec-bit guard + the
    `r_env_manager.sh` root-guard contract.
  - `t1-bash-unit` — `bats tests/unit/test_common_utils.bats`.
  - `r-runtime-static` — Rprofile dispatcher/fragment **parse gate** +
    `tests/r_lint_test.sh` HC-13 linter oracle.
  - `nginx-config` — renders the nginx templates and runs `nginx -t`.
  - `t2-validate` — `docker compose config` + `hadolint` (all 6 Dockerfiles) +
    builds the **light** images (nginx, telemetry) on every PR.
  - `t2-build-monsters` — **nightly 01:00** canary that builds the heavy images
    (rstudio-sssd/samba, ollama) to answer "do they still build?".
  - `pkg-manifest` — lints the `R_USER_PACKAGES_{CRAN,GITHUB}` arrays.
  - Explicitly **not** tested (unrealistic in CI): AD/Kerberos join, live systemd
    services, full CRAN/RStudio install.
- New local-runnable helpers: `tests/check_exec_bits.sh`, `tests/templates_parse.sh`,
  `tests/nginx_render_check.sh`.

### Fixed

- **§1 silent-failure CRITICAL defects** (`lib/common_utils.sh`, `r_env_manager.sh`;
  branch `fix/critical-silent-failures`). Guarded against regression by
  `tests/test_pr1_critical_fixes.sh` (14 assertions, wired into the `t1-static`
  CI job). Audit §1 markers flipped to `[FIXED]` (AD-backend XOR still `[OPEN]`).
  - **apt failures masked as success**: the composite-`apt` recursion used
    `if ! run_command …; then return $?`, which returned the *negated test's*
    status (`0`). Now `|| return $?` propagates the real exit code.
  - **`pipefail` stripped from callers**: `run_command` toggled `pipefail` off
    internally and never restored it, silently disabling it in every script that
    sources the library (HC-03 hazard). `run_command` is now a thin wrapper that
    saves/restores the caller's `pipefail`; the 200-line body is unchanged
    (renamed `__run_command_impl`).
  - **`restore_config()` was a silent no-op**: it logged "restored" and restarted
    services without copying anything back. Now streams the newest backup tree
    (`run_<timestamp>`, mirrors `/`) and restores each file via `_restore_item`
    after an informed, `DRY_RUN`-aware confirm; restarts services only if ≥1 file
    was restored. `_restore_item` now returns non-zero on `cp` failure.
  - **Uninstall (menu 10) crashed on arrival**: referenced undefined
    `INSTALLED_CRAN_PACKAGES`/`INSTALLED_GITHUB_PACKAGES`/`R_ENV_STATE_FILE`
    (abort under `set -u`). Defined `R_ENV_STATE_FILE`, defaulted the arrays empty,
    source-before-use; with no inventory the R-package removal is a safe no-op.
- **`scripts/` exec bits** (audit §3): `15_setup_nginx_cleanup.sh`,
  `40_install_telemetry.sh`, `99_health_check.sh`, `99_postmortem_forensics.sh`,
  `99_troubleshoot_env.sh`, `pin_r_version.sh` were committed `100644`, making
  `15_`/`40_` invisible in the launcher menu. Now `100755`, locked by
  `tests/check_exec_bits.sh` in CI.
- **`.ai/generate.sh` — deep fix (3 defects), `make audit` now green.**
  - **bash-5.2 `set -u` crash**: `${#arr[@]}`/`${!arr[@]}` on empty associative
    arrays raised `unbound variable`, silently aborting `make audit` everywhere.
    Replaced with empty-safe `sorted_keys`/`acount` helpers (no `set +u`).
  - **Image classifier**: the `${VAR:-img}:${IMAGE_TAG}` local images were
    misclassified as upstream (the parser predated that compose syntax). Now
    resolves compose `${VAR:-default}`/`${VAR}` expansions and classifies
    "locally-built" by the service's **`build:` key** (authoritative, via `yq`;
    portable no-yq fallback yields identical output). Regenerated the corrupt
    `extracted_versions.env` (mangled `__OLLAMA_AI_IMAGE__…` keys) clean.
  - **`--check` determinism**: now date-insensitive, so it no longer self-drifts
    daily. `generate-check` is therefore a **blocking** CI gate (`t1-static`),
    and all 6 IDE-rule files were regenerated in sync.

### Added

- `CHANGELOG.md` (this file) — repo-wide change history.
- `config/SITE_OVERRIDE.md` — site-local overlay reference + first-time/migration steps.

### Follow-up (recommended)

- **Deterministic package-drift detection.** Package sets live as bash arrays in
  `config/r_env_manager.conf` with no pin, so CI can only lint their *shape*. The
  real fix is a pinned **Posit Package Manager dated CRAN snapshot** (or `renv.lock`)
  as SSOT, plus a nightly job diffing the resolved set against it.
