# Changelog

All notable repo-wide changes are recorded here. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
R-runtime profile changes have their own log: [`docs/reference/Rprofile_site.CHANGELOG.md`](docs/reference/Rprofile_site.CHANGELOG.md).

## [Unreleased]

New entries go here; they move into a release section when the release is
tagged (process: [ADR-0006](docs/adr/0006-versioned-releases-and-hotfix-register.md)).

### Changed (T2 telemetry-api on Python 3.14)

- `docker-deploy/Dockerfile.telemetry`: base image `python:3.11-slim` →
  `python:3.14-slim`. The 2024 pins (FastAPI 0.111, pydantic 2.7.4) cannot build
  on 3.14 (`pydantic-core` 2.7.4 has no cp314 wheel and fails to compile), which
  kept Dependabot PRs #33/#40 red. Dependencies now come from a pinned, hashed
  lock `docker-deploy/scripts/telemetry/requirements.txt` (FastAPI 0.142.2,
  pydantic 2.13.5, Starlette 1.7.0, uvicorn 0.54.0; no release younger than two
  weeks), installed with `--require-hashes --only-binary=:all:`. gcc and
  python3-dev are gone from the image: there is no apt step left.
- `telemetry_api.py` (T1 and T2 copies, identical change): `Field(example=...)`
  → `Field(examples=[...])`. The old form is deprecated in pydantic 2 and is removed
  in v3. T1 hosts install unpinned latest packages, so they already emitted these
  warnings. The new form works on every pydantic 2.x.
- Measured in a local container, main (3.11, old pins) → this change (3.14, lock):
  the `/api/v1/status` key set and `/metrics` series are identical; `/api/v1/health`
  p50 0.90 → 1.02 ms (200 calls); startup to first healthy 1.55 → 1.40 s; RSS
  46.1 → 46.3 MiB; the invalid `report-problem` payload is still rejected with 422;
  startup warnings 12 → 0 lines. Image 289 → 225 MB (the baseline was built without
  its gcc layer, so main's real image is bigger than 289 MB).

### Fixed (T2 telemetry-api healthcheck)

- The compose healthcheck called `curl`, which `python:*-slim` does not ship
  (`sh: curl: not found`, exit 127), so `telemetry_api` could never be healthy.
  It now probes `/api/v1/health` with the image's own Python. T1 (systemd) and
  T3 (`httpGet` probe) are not affected.

## [2026.10.1] - 2026-10-20 — Rprofile v12.11-fix3

- **R profile shipped:** v12.11-fix3, unchanged from `v2026.10.0`. No R file changes.
- **Deploy on a host:** `git pull` on `main`, then `sudo ./scripts/50_setup_nodes.sh`,
  option 3. The first deploy writes `/etc/biome-calc/deployed_release`.
- **In-place hotfixes this release absorbs:** none new.
- **Tested on:** CI (`tests/test_deploy_release_guard.sh`, D1-D24); biome-calc04
  before calc01-03 (see the host ledger).

### Added (Step 8 deployed-release stamp and downgrade guard)

- Step 8 of `scripts/50_setup_nodes.sh` (options 1, 3, O) writes
  `/etc/biome-calc/deployed_release` after a full deploy: release
  (`git describe --tags --always --dirty`), commit, branch, Rprofile version,
  date, user, whether the deploy was an override, and the commit it replaced.
  Each deploy also appends one line to `deployed_release.history`. Option V and
  `--verify` print the stamp and say whether the checkout matches it.
- Before writing anything, Step 8 compares the checkout with the stamp and
  **refuses** to deploy when the checkout is older than the deployed commit,
  has diverged from it (the 2026-10-20 calc04 stale-branch incident), does not
  contain it (`git fetch` needed), has local changes or untracked files under
  `templates/`, or is not a git checkout. Local values in `config/*.vars.conf`
  and mode-only changes are allowed. With no stamp yet, it warns and deploys.
- `--allow-downgrade` overrides the refusal on purpose. Rollback procedure:
  `git checkout v<old>`, then `sudo ./scripts/50_setup_nodes.sh --allow-downgrade`,
  option 3; the stamp records `override=true`. Returning to `main` afterwards
  is a normal upgrade. Documented in
  [`docs/operations/HOTFIX_REGISTER.md`](docs/operations/HOTFIX_REGISTER.md#rolling-back-a-release).
- New `lib/deploy_release.sh`; test `tests/test_deploy_release_guard.sh` runs in `t1-static`.

### Added (release automation, already in the `v2026.10.0` commit)

- `.github/workflows/release.yml`: when `main` gets a new release section in
  this file, it tags the commit `vYYYY.MM.N` and publishes a GitHub Release
  whose notes are that section. An existing release is never touched.
  `scripts/tools/release_notes.sh` extracts the section; regression test
  `tests/test_release_notes.sh` (R1-R7) runs in `t1-static` and before every
  release. These entries were merged with `v2026.10.0` but written after its
  notes, so they appear here.

## [2026.10.0] - 2026-10-20 — Rprofile v12.11-fix3

First tagged release. It holds every change recorded in this file since it was
started, so it is long; later releases cover one batch of merges each.

- **R profile shipped:** v12.11-fix3 (`RPROFILE_VERSION="12.11"`: the `-fix`,
  `-fix2` and `-fix3` steps do not change the banner, so the banner alone cannot tell
  them apart; the release tag can).
- **Deploy on a host:** checkout on `main` at tag `v2026.10.0`, then
  `sudo ./scripts/50_setup_nodes.sh`, option 3 (Step 8, R config files only).
- **In-place hotfixes this release absorbs:** `fix_bspm_dbus_inplace.sh`
  (applied on biome-calc01-04 on 2026-10-19). Per-host state lives in
  [`docs/operations/HOTFIX_REGISTER.md`](docs/operations/HOTFIX_REGISTER.md).
- **Tested on:** biome-calc04 (test host), 2026-10-20: v12.11-fix2 researcher
  checks, then the v12.11-fix3 redeploy (option 3, syntax validated, 14
  fragments).

### Fixed (Rprofile v12.11-fix3 — review fixes on v12.11-fix2)

- Parquet sidecar: equal mtimes count as stale (coarse-timestamp filesystems
  could tie a rewritten CSV with its old sidecar). Message now reads
  `ignoring stale parquet sidecar (not newer than <file>)`. Test P9.
- ranger guard recognises its own trace; it no longer mistakes another trace
  for itself, and leaves a user's trace in place instead of dropping it.
  Tests G10-G12.

### Fixed (Rprofile v12.11-fix2 — `read.csv()` returned a stale `.parquet` sidecar)

- Fragment 50 Smart I/O: `read.csv(f)` / `fread(f)` used `f.parquet` whenever it
  existed, even when the CSV had been rewritten since, so a researcher on
  biome-calc01 kept getting the old table after `write.csv()` (2026-10). The
  sidecar is now used only when it is at least as new as the text file, the call
  has no extra reader arguments (`sep=`, `header=`, `colClasses=` are not applied
  to parquet), and the session is interactive. A stale sidecar is skipped with a
  `BIOME-IO: ignoring stale parquet sidecar` message. `read.csv` via the sidecar
  now returns a plain `data.frame` with `check.names` applied; `fread` returns a
  `data.table`. Opt-out: `options(biome.parquet_sidecar = FALSE)`.
- Dispatcher: ranger `mtry` guard. `ranger` stops on `mtry` > number of
  predictors with only `User interrupt or internal error.` (the real reason is
  printed inside the worker and lost under future/mlr3). A hook on ranger's
  namespace load, installed before the worker/full-profile branch so PSOCK
  workers get it too, traces `ranger::ranger` and raises
  `BIOME-CALC: ranger mtry = 11 but the data has only 9 predictor(s)` with the
  fix. It never changes `mtry` (HC-17); formula calls are not checked. Opt-out:
  `options(biome.ranger_mtry_guard = FALSE)`. Suite
  `tests/test_ranger_mtry_guard.sh` (S1–S2, G0–G9 with the real ranger, PSOCK
  worker included); CI installs ranger from public RSPM.
- New regression suite `tests/test_parquet_sidecar_gate.sh` (S1–S2 static,
  P1–P8 behaviour), wired into `r-runtime-static`. It fails on the previous
  fragment. Not ported to T2 (TD-T2-01: T2 still runs the pre-fragment snapshot).

### Security (bspm installs without sudo, ADR-0005)

- New `scripts/fix_bspm_dbus_inplace.sh`: registers bspm's own D-Bus system
  service (`org.r_project.linux1`) so researchers' `install.packages()` reaches apt
  through a root service instead of `sudo`. The bus policy lets `domain_users`
  call only `install`, `available`, `discover` and `Introspect`; `remove` is
  denied. Flips `bspm.sudo` to `FALSE` in the deployed `/etc/R/Rprofile.site`
  (exactly the two dispatcher lines, refuses otherwise). Dry-run by default,
  `--commit`, `--rollback DIR`, `--skip-profile`, `--group NAME`; backup in
  `/root/bspm-dbus-hotfix-<ts>/`; reloads dbus and rolls back automatically if
  the service does not answer. Sudoers is not touched.
- `templates/Rprofile_site.R.template` section 0: `bspm.sudo = FALSE`; bspm is
  enabled only when the D-Bus service file exists, otherwise `install.packages()`
  is plain R into the personal library.
- `50_setup_nodes.sh` Step 7 registers the service and no longer writes
  `/etc/sudoers.d/99-bspm-domain-users` (`NOPASSWD` on `apt-get`/`dpkg`/`bspm.py`
  was root for every domain user). An existing file is kept, with a warning.
- Audit check 14.6 (`00_audit_v28.R.template`) now checks the D-Bus service and
  policy and warns while the legacy sudoers rule exists.
- `tests/test_fix_bspm_dbus.sh` (23 cases, mutation-checked) runs in CI.
- `tests/test_bspm_dbus_policy_live.sh` loads the rendered policy into a real
  private dbus-daemon and checks the allow/deny matrix (12 cases). Added after
  the first test-host run, where dbus-daemon rejected the policy file (a member
  rule without an interface) and the hotfix rolled back.
- The hotfix replaces a hand-made registration found on the hosts (service run
  from `/root/R/.../4.5/bspm`, policy open to every local user, `remove`
  included). Verification checks which process owns the bus name: if a
  service from another path still owns it, the hotfix waits up to
  `FIX_BSPM_OWNER_WAIT` seconds (default 30) for it to exit, then rolls back
  naming its PID instead of reporting success.
- Review fixes before merge: each `--commit` gets its own backup directory
  (a second run in the same second fails instead of sharing a manifest); the
  module check uses `/usr/bin/python3`, the interpreter bus activation runs;
  Step 1 installs `python3-dbus`, `python3-gi`, `python3-apt`; Step 7 installs
  bspm into `/usr/lib/R/site-library`, where the service is registered from.
- Applied on biome-calc01-04 on 2026-10-19, both `domain_users` sudo lines
  removed on all four (ADR-0005 rollout log).

### Changed (CI)

- `r-runtime-static` runs on the production R version: `setup-r` reads
  `DEFAULT_R_VERSION` from `config/pin_r_version.vars.conf` (currently **4.6.0**,
  was a hard-coded 4.4.1) and a new step fails the job if `getRversion()` differs
  from the pin (HARD RULE 19, roadmap WS-0.3). All six R runtime suites pass on
  R 4.6.0 unchanged (verified locally on `rocker/r-ver:4.6.0` as a non-root user).

### Added (planning)

- `docs/planning/ROADMAP_EXECUTION_PLAN.md`: ordered work streams (WS-0 hygiene,
  WS-1 live T1 defects, WS-2 T2 parity, WS-3 consolidation, WS-4 T3 deferred), each
  with audit / implement / validate phases. Also ADR-style decisions, the open-PR
  triage record, and the contradictions found (CI tests R 4.4.1 while T1 pins 4.6.0;
  stale `open_gaps`; T2 has no `/Rtmp` equivalent and no recorded delta for it).
- `docs/planning/PROJECT_MAP_CONSOLIDATION_PLAN.md` ported from PR #13 (closed as
  superseded), status re-verified against `main`; it is WS-3 of the plan.

### Fixed (Rprofile v12.11-fix — wrappers survive `rm(list = ls(all.names = TRUE))`)

Ported from the unmerged `setwd_safe_regression` branch (PR #14 / #12) onto the
current `main`; those PRs are closed as superseded.

- **R runtime: `setwd()` / wrapper delegation broke after a researcher's
  `rm(list = ls(all.names = TRUE))`.** Symptom reported from `biome-calc01`:
  `Error in .biome_original_setwd(dir) : could not find function ".biome_original_setwd"`
  on an ordinary `write.csv(...)` line (the implicit `setwd()` RStudio issues
  around project/source operations hit the stale guard). Root cause + the
  `60_safe_setwd.R` `original_fn(dir)` fix and the `35_compile_routing.R`
  closure-capture hardening are detailed in
  [`Rprofile_site.CHANGELOG.md` v12.11-fix](docs/reference/Rprofile_site.CHANGELOG.md).
  **Operator action:** the running host still executes the pre-fix deployed
  fragment — re-render and re-deploy via `scripts/50_setup_nodes.sh` to clear
  the error in live sessions.

- **`safe_setwd` rm-survival regression suite.** Added
  `tests/test_safe_setwd_rm_regression.sh` (A–D groups: parse gate, static
  `original_fn` check, R runtime T1–T9, full template parse gate) and
  `tests/fixtures/test_safe_setwd_rm_regression.R`. Guards the
  `60_safe_setwd.R` fix (runtime detail in
  [`Rprofile_site.CHANGELOG.md` v12.11-fix](docs/reference/Rprofile_site.CHANGELOG.md)):
  `setwd()` must survive `rm(list=ls(all.names=TRUE))` while preserving the
  Martina-gate hard-fail and the `.biome_original_setwd` globalenv export.
  Test infrastructure is stored via `options()` (base namespace) so it
  survives the simulated globalenv purges. Review fixes applied before merge:
  - R error reporting: replaced the dead `conditionMessage(attr(ok, "condition"))`
    pattern (T1/T3/T4/T7) — `tryCatch` returns a bare scalar, so the condition
    is never attached as an attribute and the old form threw
    `conditionMessage(NULL)` on a *real* failure, masking the diagnostic. Now
    captures the message inside the handler via `err_msg <<- conditionMessage(e)`.
  - Bash harness: unified all three R invocations on a single
    `R_BIN="${RSCRIPT:-Rscript}"` (was a mix of bare `Rscript` and inline
    `${RSCRIPT:-Rscript}`) so the interpreter override applies consistently.
- **Cross-fragment wrapper rm-survival suite.** Added
  `tests/fixtures/test_wrapper_rm_survival.R` (W1–W4, wired into the harness as
  group E): asserts every base/package wrapper the `Rprofile_site.d/` kernel
  installs (`setwd`, `detectCores`, `options`, `compileNimble`) survives
  `rm(list = ls(all.names = TRUE))`. Confirmed `05`/`50`/`55` were already
  closure-safe and guards the hardened `35` (above).

### Added (home quota view: multi-node runbook)

- `docs/operations/HOME_QUOTA_VIEW_SETUP.md`: step-by-step setup for TrueNAS SCALE
  25.04 and several Ubuntu 24.04 nodes — one TrueNAS service user, one SSH key per
  node bound with `from=<node IP>` and forced to the read-only `zfs userspace`,
  staggered cron per node, UID-consistency check across nodes, a CHECK after
  every step, sshd `Match` fallback if the UI drops key options, add/remove/
  replace a node, troubleshooting, rollback. States plainly what was checked
  against the 25.04 documentation and what is only proven on site by the CHECKs.
  Replaces the single-node steps in the plan §5; in the ops wiki guide.
- Collector: the SSH exchange is bounded (`timeout 60`, `ServerAliveInterval`),
  so a TrueNAS that accepts the connection and stalls cannot hang the cron run;
  `IdentitiesOnly=yes` so only the quota key is offered.

### Added (Rprofile v12.11 — TrueNAS home quota visible to users)

- Optional T1 collector (`50_setup_nodes.sh` step 11g, disabled by default)
  reads the exact `zfs userspace` output over a restricted, forced-command SSH
  key and atomically caches one private local file per uid under
  `/var/lib/biome-quota`. Failed/partial/malformed fetches keep the old cache.
- R: `biome_quota()`, `status()` `Home (~)` line and a personal-quota warning in
  `biome_save_session()`. TTYD: `biome-quota` command and an interactive-login
  warning above `QUOTA_WARN_PCT` (90% default). Missing or stale data degrades
  to a plain message and never blocks R/login.
- T2 RStudio services mount the host cache read-only; no collector/secrets in
  containers. T3 deferred (`SKELETON_NOT_READY`).
- Tests cover collector valid/malformed/partial/fetch-failure paths and R helper
  missing/quota/no-limit/stale/malformed paths. `99_troubleshoot_env.sh` v1.5.0
  reports the cached TrueNAS quota before its real 1 MiB+fsync write test.
- Security: TrueNAS service account receives one exact NOPASSWD read command and
  a forced SSH key; no `zfs allow userquota`, no password, no modifiable quota
  permission. Key/known_hosts remain root-only files, never CLI arguments.
- `.ai/hooks/pre-commit`: the HC-14 check piped a 100 KB changelog into
  `grep -q` under `pipefail`; grep exits on the first match, `echo` gets SIGPIPE
  (141) and a present `## vX` section was reported missing. Now uses here-strings.


### Changed (T2 R version = T1)

- RStudio images (`docker-deploy/Dockerfile`, `Dockerfile.sssd`, `Dockerfile.samba`)
  moved from `rocker/geospatial:4.4.3` to `4.6.0`, the R version pinned on the host
  (`scripts/pin_r_version.sh` `DEFAULT_R_VERSION`, T3 `configmaps.yaml` `R_VERSION`).
  Closes TD-T2-06. `.github/dependabot.yml` now ignores every `rocker/geospatial`
  update (patch included): the R version moves by hand together with the T1 pin.
- RStudio images now configure Java at build time like T1
  (`r_env_manager.sh configure_java_for_r`): `default-jdk` + `netcdf-bin`, libjvm on
  the linker path, `R CMD javareconf`, rJava from source, JVM smoke test. Found in
  the 4.6.0 monster build: rJava could not load `libjvm.so`, so `loadeR.java`,
  `climate4R.UDG` and `loadeR` were silently missing from the image (the build still
  passed). `install_botanical_packages.R` now stops the build if any requested
  package cannot be loaded, printing the load error. That check then found
  `igraph` (and with it `nimble`/`nimbleHMC`) unloadable: the P3M binary needs
  `libglpk40`, now installed in the RStudio images.

### Changed (dependencies, T2 base images)

- Dependabot #23 (superseded, applied here): `ollama/ollama` 0.35.0 → 0.35.1
  (patch). The bot PR was red only on `generate --check` (it cannot regenerate the
  IDE rule files); files regenerated, runbook + `FUTURE_MIGRATION.md` pin rows
  updated. Ollama image proven only by the T2 light build / nightly monster canary.
- Dependabot #20: `rocker/geospatial` 4.4.2 → 4.4.3 (R patch release), `nginx`
  1.27.3-alpine → 1.31.0-alpine, `ollama/ollama` 0.5.4 → 0.35.0. Merged after the
  monster build (rstudio-sssd, rstudio-samba, ollama-ai) passed on the branch.
  IDE rule files regenerated; pin tables in `COMPOSE_OPERATOR_RUNBOOK.md` (was
  stale: 4.4.1 / 1.27 / 0.3.0) and `FUTURE_MIGRATION.md` updated.
- New tier delta TD-T2-06 (`.ai/project.yml`): T2 runs R 4.4 while T1 pins R 4.6.0.
  Pre-existing; recorded, not changed here.

### Changed (dependencies, T2)

- `curlimages/curl` 8.11.1 → 8.22.0 for the `rstudio-init` one-shot (dependabot #19).
  The init only runs `/bin/sh` checks, no curl options, so nothing else changes.
  IDE rule files regenerated (`make generate`); no T1/T3 counterpart (T3 has no
  init container on this image).

### Changed (CI)

- `actions/checkout` v4 → v7 in all workflows (dependabot #18). Breaking changes
  since v4 do not apply here: GitHub-hosted runners only (node24 is fine), no
  `pull_request_target` / `workflow_run` triggers, no workflow pushes with the
  checkout token.

### Added (wiki docx guides)

- `scripts/tools/build_wiki_docx.sh` v1.0.0 (+ `scripts/tools/wiki/`): builds four
  English Word guides for the SharePoint wiki from the Markdown in `docs/`, per
  `docs/wiki/manifest.tsv`: User Guide, Common Problems (researchers), Operations
  Troubleshooting Runbook, Operations Guide. Links between chapters stay
  internal, links to repo files become plain text, contents page is static
  (SharePoint's viewer leaves Word TOC fields empty), output stamped with date
  and git commit. Workstation tool (pandoc ≥ 2.17, python3).
- `docs/user_guides/COMMON_PROBLEMS.md`: researcher self-help, one section per
  problem (what you see, why, what to do, when to contact the admins).

### Changed (documentation audit 2026-10)

- `docs/` re-audited against the code (`docs/DOCUMENTATION_AUDIT.md`).
  SYSTEM_OVERVIEW and SECURITY_MODEL rewritten; TROUBLESHOOTING reorganised as
  symptom → diagnosis → fix → verification; SCRIPT_CATALOG lists every script;
  nonexistent variables and the dead NFS-fallback section removed from the user
  guides. Historical records (v12.4 rollout, Lussu hang, auth_pam regression) and
  unvalidated SOPs kept in full with a status banner.
- Researcher guides rewritten for non-IT users (cheat sheet, "How BIOME-CALC works
  for you", Common Problems, Italian guide): no user names or incident reports, no
  admin scripts or server internals, only R/portal steps; all R blocks parse.
  `rstudio_session_isolation.md` and the Italian reply to a researcher moved to
  `docs/operations/`; `SERVER_NATIVE_API.md` and `USER_CONTRACT.md` moved to the
  Operations wiki guide. `build_wiki_docx.sh` 1.1.0: researcher guides (`user-*`)
  carry no repo paths or git stamp.

### Fixed (lint advice)

- `scripts/lib/r_lint_rules.tsv`: R017 claimed `makeCluster()` defaults to FORK on
  Linux (it defaults to PSOCK everywhere); R010 claimed bare `detectCores()` returns
  the host total (on BIOME-CALC it is wrapped to the user's share). Texts corrected;
  ids, patterns and severities unchanged (`tests/r_lint_test.sh` passes).

### Fixed (home write failures with "Disk quota exceeded")

- `scripts/99_troubleshoot_env.sh` v1.4.0: the `--storage --test-user` write test
  wrote an empty file with `touch`, which passed while the user's ZFS quota on
  TrueNAS was full. It now writes 1 MiB with fsync, recognises `EDQUOT` and
  prints the uid/gid to look up on the storage server.
- `docs/operations/TROUBLESHOOTING.md §4.4`: runbook for `saveRDS`/`write.csv`
  failing with "Disk quota exceeded" while `df` shows free space (client and
  TrueNAS SCALE steps, quota audit, fix). Cross-referenced from
  `DIAGNOSTICS_INDEX.md` and `USER_QUOTAS_AND_RESOURCES.md`. Incident: a user
  quota typed as 150 MiB instead of 150 GiB.

### Changed (dependencies)

- step CLI `0.29.0` → `0.31.0` in the nginx/sssd/samba images and the K8s init
  containers, matching the CA side in Infra-Iam-PKI (step-ca `0.30.2`). The CLI changes
  since 0.29 that touch this repo: `needs-renewal` prints less (use `--verbose`);
  flags and exit codes are unchanged.
- docker-socket-proxy `0.3.0` → `v0.5.0` (HAProxy update; `BIND_CONFIG` can now be
  overridden, not used here: the proxy stays on its loopback-published bridge, TD-T2-02).
- `.github/dependabot.yml`: compose and Dockerfile images in `docker-deploy/`, action
  SHAs. rocker/geospatial minor/major bumps are ignored (they change the R version).

### Fixed (RStudio images build again)

- `docker-deploy/Dockerfile.{sssd,samba}` (and the generic `docker-deploy/Dockerfile`, which
  compose does not build but CI lints) could not build: they installed
  `r-cran-bspm`/`python3-bspm` before adding the c2d4u PPA (which has no noble build)
  and asked for `sssd-client`, which Ubuntu doesn't ship. bspm is dropped from the
  docker tier (TD-T2-05): rocker's R lives in `/usr/local` and gets binary packages
  from Posit's repository, so apt-built bspm binaries never applied. The
  `%domain_users` apt/dpkg sudoers rule goes with it.

### Changed

- **T2/T3 are self-contained and vendored by Infra-Iam-PKI.** `docker-deploy/` and
  `kubernetes-deploy/` no longer depend on root `config/`/`templates/`: the consumer
  copies them byte-for-byte (its `infra-rstudio/UPSTREAM.lock`). Contract gate:
  `tests/docker_deploy_self_contained.sh` (wired into `ci.yml`). The reverse
  `Infra-Iam-PKI` submodule is removed; `.ai/project.yml` lists it under `consumers`.
- **Back-port from the Infra-Iam-PKI docker tier** (3-way merge against the port base):
  exact base-image pins (`rocker/geospatial:4.4.2`, `nginx:1.27.3-alpine`), the
  `rstudio-init` one-shot and its `curlimages/curl:8.11.1` pin, fingerprint-verified
  `manage_pki_trust.sh`, and the templates/lib the docker tier runs in production
  (recorded as `TD-T2-01`, still behind T1's `Rprofile_site.d/` + audit v28).
- **K8s:** custom images pinned to `v1.0.0` (were `latest`), `step-cli` init containers
  aligned to `0.29.0` (were `0.25.2`, CA is 0.29.0); NetworkPolicies added
  (default-deny ingress, then ingress → portal → oauth2-proxy/rstudio/telemetry/ollama).

### Fixed

- `docker-deploy/Dockerfile.telemetry` COPYed a non-existent `admin_recipients.txt`
  (build failure, and would have baked real addresses into the image): now
  bind-mounted from `config/site/` (`TD-T2-04`); `validate_deployment.sh` fails early
  if it is missing.
- `docker-deploy/.env.sandbox.example` did not resolve: missing `IMAGE_TAG`,
  `HOST_HOME_DIR`, `HOST_PROJECT_ROOT`, `SSL_*`, …; image names carried a tag twice
  (`rstudio-botanical-sssd:sandbox:sandbox`); `STEP_CA_ROOT_PATH` pointed outside the tree.
- CI was red on `main` before this change; now fixed: bats unit tests sourced
  `lib/common_utils.sh` unprivileged (it defaults `LOG_FILE` to `/var/log`), the nginx
  render test missed the `auth_pam` dynamic module (stock `modules-enabled` include +
  `libnginx-mod-http-auth-pam`, as in production), hadolint 2.12 could not parse
  heredocs (now 2.14.0), and `docker-deploy/scripts/docker-entrypoint.sh` was a
  one-line stray (`# %b`, no shebang, referenced nowhere): removed.
- `docker-deploy/Dockerfile.nginx` could not build: Alpine ships `certbot-nginx`,
  not `py3-certbot-nginx`. Two bats tests never ran (setup failed first) and were
  wrong: one assigned the readonly `BASH_VERSINFO`, one checked `$status` without `run`.
  The nginx render test never passed: 1024-bit dhparam (OpenSSL 3 rejects it), and
  unprivileged `nginx -t` hit root-owned temp/log paths and binds ports 80/443. It now
  uses a 2048-bit dhparam, temp/log paths under its work dir, ports 18080/18443, and
  drops `[::]` listens only on hosts without IPv6.
- `.ai/validate.sh`: HC-01 treated top-level `x-logging`/`networks` children as
  services; HC-09 flagged a comment that mentions `docker.sock`.

### Security

- docker-socket-proxy moved off `network_mode: host` to a bridge published on
  `127.0.0.1:2375` only: the image binds `[::]:2375` unconditionally, which exposed
  the Docker API to the LAN (`TD-T2-02`). Healthchecks added for it and for
  oauth2-proxy (`v7.6.0-alpine`, `TD-T2-03`).

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
