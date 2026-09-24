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

- **`99_check_rprofile_health.sh` R-library and slow-load hints.**
  - Section 6: a login script that writes `R_LIBS_USER` now points at
    `fix_login_script_rlibs_inplace.sh --commit` (WARN with local libs on;
    PASS with an enable-order note when `ENABLE_R_LIBS_LOCAL=false`), warns
    that `20_configure_rstudio.sh` menu 1/3 chown the home root, and
    recognises an applied hotfix.
  - Section 7: with local libs disabled, an `R_LIBS_USER` line equal to R's
    own default (`~/R/x86_64-pc-linux-gnu-library/<Rver>`) is a PASS with no
    manual action; other values still WARN. The fragment-04 remark appears
    only when local libs are on; the manual action starts with the hotfix
    when the login script is the writer.
  - Section 9: a slow load no longer blames the bundle when it is fresh, and
    when the later interactive baseline started much faster it says "cold
    first start, run again" and gives the `BIOME_DEBUG=1` timing command.

- **HC-13 triage harness v1.4** (`scripts/99_diagnose_user_script.sh`).
  - New layer **L3s** (full system profile, no user startup files). L1, L2 and
    L3s run with `R_ENVIRON_USER=` (set but empty: neither `./.Renviron` nor
    `~/.Renviron` is read) and `--no-init-file`, so **L3s PASS + L3 FAIL** names
    the user's `~/.Renviron` / `~/.Rprofile` as the cause, repaired with
    `scripts/99_check_rprofile_health.sh --user <u> --fix`. Until v1.3 L1-L3 all
    read `~/.Renviron` (L2/L3 also `~/.Rprofile`), so a broken user profile was
    reported as "dispatcher core" or "not a profile issue".
  - L2 builds its `BIOME_DISABLE_FRAGMENTS` list from the fragments actually
    deployed (`BIOME_DIAG_FRAG_DIR`, default `/etc/R/Rprofile_site.d`). The
    hardcoded v1.3 list left `04`, `05`, `42` and `52` active, so a bug in one
    of them was blamed on the dispatcher core.
  - Exit code keyed on the production layer L3: `0` L3 passed (reduced-layer
    failures become NOTE lines; the v1.3 mapping gave `1` for e.g. L1 FAIL +
    L3 PASS), `1` L0 or L3 failed, `3` L3 PROGRESSING, `4` L3 passed with HIGH
    lint findings. An L3 failure that a SKIPPED/PROGRESSING layer leaves
    unattributable is labelled as such; SKIPPED is a documented status.
  - New overrides `BIOME_DIAG_R_MIN` and `BIOME_DIAG_FRAG_DIR`.
- **Docs follow the v1.4 ladder**: `DIAGNOSTICS_INDEX.md` (§1 + §4 + log table +
  decision tree), `USER_SCRIPT_TROUBLESHOOTING.md` (L3s row, surface 7 "user
  startup files", verdict table, user-message template), `OPERATOR_QUICKSTART.md`,
  `SCRIPT_CATALOG.md`, `LUSSU_HANG_BISECTION.md`, `README.md`,
  `templates/Rprofile_site.d/README.md`, `.ai/agents.md` §6.6 and the HC-13
  rationale in `.ai/project.yml`.
- `.gitignore`: local AI-agent tool state (`.omo`, `.serena/`).

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

- `r-runtime-static` also runs `tests/rprofile_health_test.sh` (regression gate
  for `99_check_rprofile_health.sh`; mktemp fixture trees, real R).

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

- **The RStudio login script re-added `R_LIBS_USER` to every `~/.Renviron`.**
  `templates/rstudio_user_login_script.sh.template` (T1, and the T2 copy in
  `docker-deploy/templates/`) appended `R_LIBS_USER=<projects root>/<user>/R/x86_64-pc-linux-gnu-library/<Rver>`
  whenever the line was missing, so it came back after every
  `50_setup_nodes.sh` Step 9 / `99_check_user_renviron_overrides.sh` cleanup, and
  once `ENABLE_R_LIBS_LOCAL=true` it overrides the local-disk path of
  `Renviron.site` (read before `~/.Renviron`). `Renviron.site` now owns the
  variable alone; the library directory is still created. Behaviour change only
  where `R_PROJECTS_ROOT/<user>` is not the user's `$HOME`: users without a line
  then get R's default `~/R/...` library.
  Deployed nodes: `scripts/fix_login_script_rlibs_inplace.sh` (below).

- **The HC-13 triage harnesses never returned their exit code.** `cleanup_pgid`
  in `99_diagnose_user_script.sh` and `99_diagnose_lussu_hang.sh` sent TERM, then
  KILL, to its own process group, which contains the harness itself: every run
  ended with `143`, whatever the verdict. Both now ignore their own TERM and
  leave themselves out of the KILL.
- **The Lussu overlay never ran its probes** (`99_diagnose_lussu_hang.sh` v1.6).
  The exported `__HARNESS_SETSID` guard leaked into the generic harness, which
  then stayed in the overlay's process group and killed it right after step 1:
  probes E/F/G never ran. Both harnesses now re-exec under `setsid` unless they
  already lead their session. `run_probe` also re-armed `set -e`, so the first
  failing probe aborted the overlay before its verdict; and the E/F hypotheses
  fired on generic exit `4`, where L3 had passed.
- `99_diagnose_user_script.sh`: the `setsid` re-exec recomputed the timestamp and
  left an empty `/tmp/user_diag_*` dir behind; `BIOME_DIAG_OUT_DIR` is now
  exported before the re-exec.
- Docs: `OPERATOR_QUICKSTART.md` ran both harnesses with `sudo`, which their
  root guard refuses (now `sudo su - <user> -c …`); `DIAGNOSTICS_INDEX.md` listed
  wrong output dirs (`/tmp/user_script_diag_*`, `/tmp/lussu_diag_<TS>`) and
  called `99_check_user_renviron_overrides.sh` read-only (it has `--fix --commit`).

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

- **Problem Reporter SMTP delivery silently used sanitized placeholders**
  (`scripts/50_setup_nodes.sh`, `lib/common_utils.sh`; user report — 🐞 Report
  Problem in `templates/{terminal,rstudio,nextcloud}_wrapper.html.template`
  failing with `Failed to send email: [Errno -5] No address associated with
  hostname`).
  - `setup_nodes_orphan_cleanup()` deployed the committed, sanitized
    `config/setup_nodes.vars.conf` (`SMTP_HOST="smtp.example.org"`,
    `SMTP_DNS_SERVERS="192.0.2.10 192.0.2.11"` — RFC 5737 TEST-NET,
    unreachable) straight to `/etc/biome-calc/conf/setup_nodes.vars.conf` via
    a plain `cp`, never folding in the `config/site/setup_nodes.site.vars.conf`
    overlay that this same script already sources into its own shell env.
    `telemetry_api.py::_load_setup_config()` parses that deployed file
    directly (not the shell env), so the Problem Reporter — and every other
    T1 consumer reading that path directly (`unibo_archive_manager.sh`,
    `scopri_progetti.sh`) — always resolved the placeholder SMTP host, which
    has no A/AAAA record (`EAI_NODATA`, errno -5).
  - Added `patch_deployed_mail_overrides()` to `lib/common_utils.sh`:
    idempotently rewrites the 6 sensitive keys (`SMTP_HOST`, `SENDER_EMAIL`,
    `MAIL_DOMAIN`, `MAIL_DOMAINS_USER`, `SMTP_DNS_SERVERS`, `BIOME_CONTACT`)
    in an already-deployed `setup_nodes.vars.conf` from the caller's sourced
    env, with a timestamped backup and atomic replace.
    `setup_nodes_orphan_cleanup()` now calls it (`DRY_RUN`-aware) right after
    the `cp`, so fresh/re-deploys self-heal automatically.
  - New `scripts/tools/hotfix_smtp_site_overrides.sh`: standalone tool that
    applies the same patch to an already-deployed production host without
    re-running the full node setup (kernel tuning, R packages, Ollama, cron).
    No service restart needed — `telemetry_api.py` re-reads its config file
    on every `/api/v1/report-problem` request.

### Added

- `scripts/fix_login_script_rlibs_inplace.sh` — one-shot hotfix of the deployed
  `/etc/profile.d/00_rstudio_user_logins.sh` (same one-line change as the
  template) without re-running `20_configure_rstudio.sh`. Dry-run by default,
  `--commit`, `--rollback DIR`; backup in `/root/login-script-hotfix-<ts>/`,
  atomic swap, owner/mode/mtime kept (per-user `/tmp` stamps stay valid, so no
  mass re-run; `--rerun-logins` otherwise), no service restart. Refuses a file
  not rendered from the template and a `USER_PROJECTS_BASE_DIR` ≠ `NFS_HOME`
  unless `--force`. Exit `0` applied / already applied / dry-run, `1` refused or
  failed, `2` usage.
- `tests/login_rlibs_hotfix_test.sh` — renders the real template, executes the
  login script before/after for a non-existent user (writes stay under mktemp),
  and covers the hotfix refusals, dry-run, commit, idempotence, rollback and
  mtime handling. Wired into CI job `r-runtime-static`.

- `scripts/99_check_rprofile_health.sh` (v2.0) — health check of the startup
  chain every RStudio session runs (dispatcher, fragments, bundle, guards, BLAS,
  `Renviron.site`, runtime load, PSOCK worker survival) and, with `--user NAME`,
  of that user's startup files and session state, incl. an A/B run against the
  system baseline. Runtime probes run as the probed user, never as root.
  Per-user repair only on request: `--fix [--commit]`, `--reset-profile
  [--commit]`, `--undo-reset` (backups / reversible quarantine; system files
  are never modified). Exit `0` clear, `1` CRIT/FAIL, `2` warnings, `3`
  invocation error, `4` requested change not applied.
- `tests/rprofile_health_test.sh` — its regression gate: synthetic and
  real-render deployed trees under mktemp (`BIOME_HEALTH_ROOT`), real R.

- `CHANGELOG.md` (this file) — repo-wide change history.
- `config/SITE_OVERRIDE.md` — site-local overlay reference + first-time/migration steps.

### Follow-up (recommended)

- **`20_configure_rstudio.sh` refactor (found while tracing the `R_LIBS_USER`
  writer; not fixed — until then do not run options 1, 3, 4, 5 or 9 on a
  populated node, use `fix_login_script_rlibs_inplace.sh` instead):**
  - options 1 and 3 (choice A, and option 1 always) run `chown -R root:<group>`
    and `chmod -R g+rwx` on `R_PROJECTS_ROOT=/nfs/home`, i.e. every user's home:
    root-owned files, and group members can write other users' `.Renviron` /
    `.Rprofile`;
  - option 4 appends `TMPDIR/TMP/TEMP="/nfs/home/Rtmp"` (NFS) to
    `Renviron.site`; run after `50_setup_nodes.sh` it becomes the last
    definition and moves R temp off `/Rtmp`; option 5 appends a welcome block
    to the dispatcher `Rprofile.site`; both restart rstudio-server. Both files
    belong to `50_setup_nodes.sh`, which rewrites them;
  - option 9 restores `Renviron.site` / `Rprofile.site` from 20's last backup,
    which can undo a later `50_setup_nodes.sh` deploy;
  - the login script writes the deployed file with a plain `printf >` (a login
    during the write can source a half-written file);
  - `python_path` conflict: the login script forces
    `DEFAULT_PYTHON_PATH_LOGIN_SCRIPT=/usr/bin/python3.8` into
    `rstudio-prefs.json` at every stamp expiry, while Step 9 and
    `Renviron.site` use `/opt/r-geospatial/bin/python`.
- **Silent owner loss in the `~/.Renviron` cleanups.**
  `99_check_user_renviron_overrides.sh --fix --commit` ignores a failed
  `chown/chmod --reference` on its temp file (`|| true`) and then `mv`s it into
  place: on NFS the user's file can end up owned by root (a production user's
  `~/.Renviron` was found owned by uid 0; cause not confirmed). `50_setup_nodes.sh` Step 9 edits the same files in place as root
  (`sed -i`) without checking the owner afterwards. Both should verify the
  owner and fail (HC-14).
- **Order for enabling local R libraries** (`ENABLE_R_LIBS_LOCAL=true`):
  hotfix/redeploy the login script first, then remove the existing
  `R_LIBS_USER` lines (`50_setup_nodes.sh` option 4), then deploy
  `Renviron.site` (option L / 3). Reversed, the login script re-adds the lines.

- **Regression test for the HC-13 harnesses.** The `143` exit bug survived
  because nothing runs `99_diagnose_user_script.sh` / `99_diagnose_lussu_hang.sh`
  in CI. v1.4/v1.6 were verified with a fake `Rscript` / `r_minimal` on `PATH`
  (13 verdict/exit cases + overlay end-to-end); committed as a test, that needs
  no R and fits `t1-static`.
- **Harness process cleanup is weaker than its comments claim.** `timeout`
  moves each layer into its own process group, so the harness's group kill
  never reaches R workers left behind by a layer; and after `setsid` a terminal
  Ctrl-C stops `setsid -w`, not the harness. Found by reading, not tested.

- **Deterministic package-drift detection.** Package sets live as bash arrays in
  `config/r_env_manager.conf` with no pin, so CI can only lint their *shape*. The
  real fix is a pinned **Posit Package Manager dated CRAN snapshot** (or `renv.lock`)
  as SSOT, plus a nightly job diffing the resolved set against it.
