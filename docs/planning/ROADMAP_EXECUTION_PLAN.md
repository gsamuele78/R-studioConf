<!-- docs/planning/ROADMAP_EXECUTION_PLAN.md -->
# Roadmap Execution Plan

> **Status:** ACTIVE: the working plan, updated as work streams close.
> **As of:** 2026-10-12 (`main` @ `977bef2` + the PR that adds this file).
> **Audience:** operator (single LPIC-3 sysadmin), any agent working on the repo.
> **Roadmap sources (not duplicated here):** [`../FUTURE_MIGRATION.md`](../FUTURE_MIGRATION.md)
> (tier status + promotion gates), [`../deployment/TIER_PROMOTION.md`](../deployment/TIER_PROMOTION.md)
> (T1 → T2 → T3 contract), `.ai/project.yml` (`deployment_tiers`, `tier_deltas`),
> [`PROJECT_MAP_CONSOLIDATION_PLAN.md`](PROJECT_MAP_CONSOLIDATION_PLAN.md) (WS-3 brief).

This file says **what is done next, in which order, and how each step is proven**.
It does not redefine the roadmap. If this file and the sources above disagree, the
sources win; fix this file.

---

## 0. Pre-conditions

### Missing information (blocks parts of the plan, not all of it)

| # | Missing | Blocks |
|---|---|---|
| M1 | Which production hosts run Rprofile fragments (biome-calc01 confirmed; others?) | WS-1.1 redeploy scope |
| M2 | Whether the T2 stack has *any* production user yet, or is still a build/CI target only | WS-2 priority vs WS-3 |
| M3 | Whether Dependabot may push to its own branches with a repo token (PAT / GitHub App) | WS-0.2 automation option |
| M4 | Owner decision on the large-scratch parity for T2: bind-mount host `/Rtmp`, or record a permanent tier delta | WS-2.2 |

### Assumptions made to proceed

- A1. T1 stays Bash (verdict in `PROJECT_MAP_CONSOLIDATION_PLAN.md`); no Python/IaC tier.
- A2. Sandbox stays BROKEN; validation = CI + operator checks on a real host.
- A3. T3 stays `SKELETON_NOT_READY`; no T3 work until the T2 parity gate passes.
- A4. One operator. Work streams run **sequentially**, one PR per step, each revertible.

---

## 1. Open-PR triage (2026-10-12)

All four open PRs were 6–49 commits behind `main`. Merging the stale branches as-is
would have dragged in a submodule-pointer change to `Infra-Iam-PKI` (do-not-touch)
and re-introduced conflicts in `CHANGELOG.md` / `Rprofile_site.CHANGELOG.md`. The
useful content was **ported onto current `main`** in one PR. The originals were closed
as superseded.

| PR | Content | Outcome |
|---|---|---|
| #12 `setwd_safe_regression` → `fix/critical-silent-failures` | Same head as #14; base branch already fully merged into `main` | Closed: duplicate of #14 |
| #14 `setwd_safe_regression` → `main` | **Live defect:** `setwd()` fails after `rm(list = ls(all.names = TRUE))`; `compileNimble` wrapper hardening; regression suites | Ported (commits `fix setwd.R error write`, `adding fixes and changelogs`); CHANGELOG entry renamed **v12.11-fix** because `main` is already at 12.11; suite wired into CI. Dropped the last commit (`Infra-Iam-PKI` pointer + `.bak` deletions): the pointer change is out of scope, and the `.bak` files never existed on `main`. |
| #13 `Project-Map-Consolidation` | Planning doc (approved, not executed) | Ported as-is plus a status refresh; becomes WS-3 below |
| #23 Dependabot `ollama/ollama` 0.35.0 → 0.35.1 | One-line Dockerfile bump | Applied with the regenerated agent files. The bot PR was red only on `generate.sh --check` (see WS-0.2) |

---

## 2. Decisions (ADR-style)

### D-R01: Supersede stale PRs by porting, never by merging old branches

- **Context:** long-lived branches drift from `main` (49 commits for #14). Their
  merge commits also carry unrelated changes (the submodule pointer).
- **Decision:** cherry-pick the needed commits onto a fresh branch off `main`,
  re-run the full local CI set, then close the originals with a link to the new PR.
- **Consequences:** the authors' commits and authorship are kept. Review covers only
  the needed delta. Cost: CHANGELOG conflicts are resolved by hand once.

### D-R02: Work-stream order is T1 defects → hygiene → T2 parity → consolidation → T3

- **Context:** T1 is authoritative and in production; a live R defect affects
  researchers today. T2 and T3 only mirror T1.
- **Decision:** WS-1 (live T1 defects) always pre-empts other streams. WS-0 hygiene
  goes next because it unblocks CI for everything else. WS-2 and WS-3 come after;
  their order depends on M2. WS-4 (T3) stays gated.
- **Consequences:** T2 parity moves more slowly. That is acceptable: T2 must never
  diverge to mask a T1 defect (HC-03).

### D-R03: No "fix" counts until it is deployed

- **Context:** the setwd fix was written in June and never reached the hosts; the
  defect stayed live for four months.
- **Decision:** each T1 R-runtime fix carries an explicit **operator action**
  (redeploy step + verification command) in CHANGELOG. The work stream closes only
  when that action has been confirmed on every host in M1.

---

## 3. Work streams

Each stream has three phases: **Audit** (current state, pre-requisites),
**Implement** (ordered steps, one PR each), **Validate** (exit criteria).

### WS-0: Repository and CI hygiene

**Audit**
- `ai-context.yml` → `generate.sh --check` fails on every Dependabot image bump,
  because the bot cannot regenerate `CLAUDE.md`, `.cursorrules` and the other rule
  files. Every such PR is red by construction (#20, #23).
- `.ai/project.yml → deployment_tiers.T2_docker.open_gaps` still lists "oauth2-proxy
  and docker-socket-proxy lack healthcheck"; both have healthchecks today
  (`FUTURE_MIGRATION.md` §T2 facts). T3 blocker "no NetworkPolicy" is stale too
  (`kubernetes-deploy/network-policies.yaml` exists, not yet audited).
- CI runs the R runtime jobs on **R 4.4.1**, while T1 pins **R 4.6.0**
  (`scripts/pin_r_version.sh`, `kubernetes-deploy/configmaps.yaml`). The R runtime
  tests do not run on the production R version. This contradicts HARD RULE 19.
  **Resolved in PR #26:** `r-runtime-static` now reads `DEFAULT_R_VERSION` from
  `config/pin_r_version.vars.conf` and fails if the installed R differs from it.

**Implement**
1. WS-0.1: Update the stale `open_gaps` / blockers in `.ai/project.yml` and regenerate.
2. WS-0.2: Dependabot freshness. Option A: a `pull_request_target` job that runs
   `.ai/generate.sh` and pushes the result to `dependabot/**` branches (needs M3;
   the token scope is a security review item). Option B: keep it manual, with the
   operator applying the bump plus regeneration as done for #23. **Default: B** until M3
   is answered.
3. WS-0.3: CI `setup-r` reads its R version from the single source of truth
   (`scripts/pin_r_version.sh DEFAULT_R_VERSION`) instead of a literal. Expect fallout:
   some fixtures may behave differently on 4.6. Fix them in T1 tests, never by pinning CI back.

**Validate**
- `make generate-check` and `.ai/validate.sh --ci` are green on `main`.
- A Dependabot PR reaches green without manual edits (option A), or the manual
  procedure is documented in `docs/developer/` (option B).
- `r-runtime-static` logs `R version 4.6.x`.

### WS-1: Live T1 defects (pre-empts everything)

**Audit**
- WS-1.1 **v12.11-fix (setwd / compileNimble rm-survival).** The fix is merged with
  this plan. On `biome-calc01` the deployed `/etc/R/Rprofile_site.d/60_safe_setwd.R`
  still calls `.biome_original_setwd(dir)`.
- Sweep result (in `Rprofile_site.CHANGELOG.md` v12.11-fix): fragments 05/50/55
  were already closure-safe; 35 hardened; 60 fixed.

**Implement**
1. On every host in M1: `sudo ./scripts/50_setup_nodes.sh` (re-render + deploy fragments).
2. No RPROFILE_VERSION bump (behaviour-restoring fix; HC-14 applies only to bumps).

**Validate**
- `grep -c 'original_fn(dir)' /etc/R/Rprofile_site.d/60_safe_setwd.R` → `1` on every host.
- `grep -c '\.biome_original_setwd(dir)' /etc/R/Rprofile_site.d/60_safe_setwd.R` → `0`.
- A researcher session: `rm(list = ls(all.names = TRUE)); setwd(tempdir())` → no error.
- CI: `tests/test_safe_setwd_rm_regression.sh` green. It was proven to fail with the
  fix reverted (T4/T9 FAIL), so it is a real regression guard.

### WS-2: T2 parity with T1 (`MIGRATION_IN_PROGRESS`)

**Audit**: the open items, in `FUTURE_MIGRATION.md` §T2 gaps:
- TD-T2-01: the container R env is the single-file `b150f7c` snapshot + audit v27;
  T1 is the `Rprofile_site.d/` fragments (12.11 + v12.11-fix) + audit v28.
  **The v12.11-fix does not reach T2 until TD-T2-01 is closed.**
- Large scratch: the RStudio services get `/tmp` as 16 GB tmpfs, and no `/Rtmp`
  400 GB ext4 equivalent is mounted. This deviation is not yet in `tier_deltas` (needs M4).

**Implement**
1. WS-2.1: `entrypoint_rstudio.sh` renders `Rprofile_site.d/` from a
   `docker-deploy/`-local copy of the T1 fragments (HARD RULE 4: no `../` reads).
   Add a CI guard that diffs `templates/Rprofile_site.d/` against the vendored copy, so
   T2 cannot silently lag T1 again.
2. WS-2.2: after M4, either bind-mount host `/Rtmp` into the RStudio services, or add
   `TD-T2-07` with its rationale.
3. WS-2.3: close TD-T2-01 in `.ai/project.yml`, regenerate the agent files.

**Validate**
- `compose-constraint-audit` skill passes; T2 light build + nightly monster build green.
- In the container: `Rscript -e 'getOption("biome.profile_version")'` (or the
  equivalent banner) matches `RPROFILE_VERSION` in `config/setup_nodes.vars.conf`.
- In the container: the rm-survival check from WS-1 passes.

### WS-3: Project-map consolidation (`PROJECT_MAP_CONSOLIDATION_PLAN.md`)

**Audit** (re-verified 2026-10-12; all June findings still hold)
- `next_gen/` is still present; `docs/adr/` does not exist.
- Dead templates are still present (`templates/old/`, `Rprofile_site.R.template_v11.*`,
  `"Rprofile_site.R copy 2.template"`, `"cleanup_r_orphans.sh copy.template"`).
- The `31_` prefix collision is still present (`31_optimize_system.sh`, `31_setup_web_portal.sh`).
- Commented-out `launch_external_script` block is still in `r_env_manager.sh`.
- The brief's Step 5 premise ("CI permission-denied") is likely already resolved by
  `tests/check_exec_bits.sh`; re-verify before acting on it.

**Implement**: Steps 0–5 of the brief, one commit per step, in its order. Step 3
(MADR ADRs) first records D-R01..D-R03 above as `docs/adr/0001..0003`.

**Validate**: the brief's per-step **Verify** lines, plus the full local `tests/` run
and green CI.

### WS-4: T3 Kubernetes (`SKELETON_NOT_READY`): DEFERRED

Gate: WS-2 complete **and** the `FUTURE_MIGRATION.md` T3 blockers closed. Known
contradiction to fix when the stream opens: `kubernetes-deploy/configmaps.yaml` sets
`TELEMETRY_TMP_DIR: "/tmp"` (the invariant is `/Rtmp`). No other T3 work is planned.

---

## 4. Definition of done (any step)

- [ ] T1 first; any T2/T3 deviation recorded in `tier_deltas` (HC-03).
- [ ] Local: `check_exec_bits`, `test_pr1_critical_fixes`, `templates_parse`,
      `docker_deploy_self_contained`, `.ai/validate.sh --ci`, `.ai/generate.sh --check`.
- [ ] CHANGELOG entry; Rprofile changes also in `Rprofile_site.CHANGELOG.md`.
- [ ] Operator action written down if a host must be redeployed (D-R03).
- [ ] CI green on the PR head before merge.

## 5. Status board

| Item | State |
|---|---|
| Open-PR triage (#12, #13, #14, #23) | Done in this PR |
| WS-1.1 v12.11-fix code + CI guard | Done in this PR |
| WS-1.1 host redeploy | **Open: operator** (needs M1) |
| WS-0.1 stale open_gaps | Open |
| WS-0.2 Dependabot freshness | Open (default B until M3) |
| WS-0.3 CI R version = T1 pin | Done in this PR (CI reads `DEFAULT_R_VERSION`, asserts R 4.6.0; all 6 R runtime suites pass on 4.6.0, no fixture changes needed) |
| WS-2.1..2.3 T2 parity | Open |
| WS-3 consolidation Steps 0–5 | Open |
| WS-4 T3 | Deferred (gated) |
