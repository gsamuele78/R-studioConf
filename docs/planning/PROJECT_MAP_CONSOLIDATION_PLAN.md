<!-- docs/planning/PROJECT_MAP_CONSOLIDATION_PLAN.md -->
# Project-Map Consolidation Plan (Steps 0–5)

> **Status:** APPROVED — not yet executed. Self-contained execution brief.
> **Audience:** developer, architect, operator.
> **Tier:** T1 (host) authoritative. No T2/T3 files are touched by this plan.
> **Created:** 2026-06-23.
> **Decision basis:** the [Verdict](#verdict) below — *do NOT rewrite T1 to Python;
> DO consolidate the project map (document → spec → prune → test → ADR).*

---

## Why this document exists

This was produced in response to two questions:

1. *Is it worth refactoring the T1 host deployment from Bash to Python?*
2. *Should we rebuild the project map first (document modules, add specs, remove
   abandoned paths, add tests, record decisions as ADRs) before writing more code?*

It is written so the work can be executed at a later time by any agent or operator
without re-deriving the context. Read it top to bottom before starting.

---

## Verdict

**Question 1 — rewrite T1 to Python: NO.**

- A Python rewrite **already exists and already stalled**: `next_gen/` is a 1.3 MB
  Python+Ansible prototype with a 2-flag `main.py` (`--detect-backend`, `--backup`)
  and an **empty `tests/`** directory. The experiment ran and produced nothing
  deployable.
- T1 is `AUTHORITATIVE_CONTINUOUSLY_FIXED` and in production. A language rewrite of
  the authoritative tier is the highest-blast-radius change possible — it violates
  the project's "smallest blast radius" ethos.
- The load-bearing logic (`50_setup_nodes.sh`, `Rprofile_site.d/`, PAM/Kerberos/SSSD)
  is system-level (apt, systemd, `nginx -t`, krb5, sssd). Wrapping it in
  `subprocess.run()` adds an interpreter dependency and a serialization boundary
  while removing nothing.
- `docs/FUTURE_MIGRATION.md §5` already rules IaC (Ansible/Terraform) "speculative,
  not committed," gated behind T3 stability AND a team-size change from the current
  single-LPIC-3-sysadmin profile.
- The chosen forward path is already T1 → T2 (docker) → T3 (k8s). A 4th ungoverned
  Python tier fragments the thing we are trying to consolidate.

**Question 2 — consolidate the map first: YES.** The correct sequence is
map → document → spec → prune → test → ADR. Three of those already exist at decent
quality, so this is **consolidation and gap-closing**, not greenfield. The single
biggest *absent* piece is a formal **ADR system**.

---

## Operating principles for execution

1. **Archive, never delete.** Every removal is `git mv <path> archive/<path>` — never
   `rm`. `archive/**` is already in `.ai/project.yml → ignore_globs`, so archived
   files stay on disk and in git history but leave the active agent/audit surface.
   Rollback for any step = `git mv` back, or `git revert` the commit.
2. **One branch, one commit per step.** Branch `chore/project-map-consolidation` off
   `main`. Each numbered step = one revertible commit.
3. **Respect tier rules.** T1 only. Do NOT touch `docker-deploy/` (T2),
   `kubernetes-deploy/` (T3), `Infra-Iam-PKI/` (submodule, HC-04),
   `src/biome_core_rust/` (dormant), or `sandbox/` (broken).
4. **Run the relevant skill before editing.** `host-install-audit` for any T1 file;
   `script-safety-review` for any created/modified `.sh`/`.bats`. `compose-constraint-audit`
   and `k8s-manifest-audit` do NOT apply (no T2/T3 files). `sandbox-test` is SKIP (broken).
5. **No `|| true` masking in CI.** Consistent with the existing `ci.yml` principle.

---

## Ground-truth findings (verified read-only, 2026-06-23)

These were confirmed before the plan was approved. Do not re-assume; re-verify only
if the tree has changed since the created date.

| Finding | Evidence |
|---|---|
| `next_gen/` is 1.3 MB, has empty `tests/`, and exactly **one** inbound reference | `docs/operations/sysadmin_troubleshooting_guide.md` |
| **OIDC/oauth2-proxy is NOT in T1 active code** | zero refs in `scripts/ templates/ config/`; live nginx auth is `auth_pam` (AD creds) in `templates/nginx_proxy_location.conf.template:166,191,200` |
| `docs/audits/T1_REMEDIATION_TRIAGE.md` is **referenced but does not exist on disk** | only present as git branch `claude/t1-remediation-triage`; linked from `T1_HOST_DEPLOYMENT_AUDIT.md` |
| Two audit docs exist | `docs/DOCUMENTATION_AUDIT.md` (doc-freshness register) + `docs/audits/T1_HOST_DEPLOYMENT_AUDIT.md` (defect audit) |
| `31_` prefix collision | `scripts/31_optimize_system.sh` + `scripts/31_setup_web_portal.sh`; referenced across **8 docs + 3 active scripts** (`30_install_nginx.sh`, `40_install_telemetry.sh`, `99_postmortem_forensics.sh`) + `.ai/project.yml` + `.ai/agents.md` + `host-install-audit` skill — rename is NOT mechanical |
| Dead code block | `r_env_manager.sh:1123-1161` — commented-out old `launch_external_script`, superseded by the live version below it |
| Dead templates have **zero** active refs | `templates/old/**` + top-level versioned `Rprofile_site*` cruft (`_original`, `_v11.2`, `_v11.3`, `_v11.4`, `_v11.4_final`, `_v12_nimble_router`, `cleanup_r_orphans.sh copy.template`) |
| `archive/` already exists with substructure | `archive/plan/`, `archive/scripts/`, `archive/templates/` |
| Test suite is real but shallow | 1 bats + 5 bash + 8 R fixtures; only `common_utils.sh` has unit coverage; 2789-line `50_setup_nodes.sh` untested |

---

## Decisions locked (from approval interview)

| # | Decision |
|---|---|
| D1 | `next_gen/` → `git mv` to `archive/next_gen` (on-disk safety net, not `git rm`). |
| D2 | ADR format = **MADR** (Markdown Any Decision Records). |
| D3 | Execute on one branch, 6 commits, review whole branch before merge. |
| D4 | `T1_REMEDIATION_TRIAGE.md` dangling reference → **fix the dead links** (do not recover the doc). |
| D5 | `31_` collision → **document now, DEFER the rename** to a dedicated follow-up PR. |
| D6 | CI permission-denied failures → fix using the **CI run logs the operator will provide** (Step 5 blocker). |
| D7 | T1 auth reality = **PAM/AD (SSSD and/or Samba) today**; OIDC is a *future* Infra-Iam-PKI integration under test, NOT current T1. Do not rewrite docs to claim OIDC is live. |

---

## Step 0 — Reconcile the documentation-audit layer

**Goal:** make the two audit docs coherent and fix the dangling reference.

**Actions**
1. Add cross-link headers so `DOCUMENTATION_AUDIT.md` ↔ `audits/T1_HOST_DEPLOYMENT_AUDIT.md`
   ↔ `docs/adr/` (created in Step 3) all reference each other.
2. **Fix the two dead `T1_REMEDIATION_TRIAGE.md` links** in
   `docs/audits/T1_HOST_DEPLOYMENT_AUDIT.md` → point at the real tracking location and
   note the content lives only on git branch `claude/t1-remediation-triage` (D4).
3. Add `DOCUMENTATION_AUDIT.md` rows for everything this PR creates/moves: `docs/adr/**`,
   `archive/next_gen/README.md`, `docs/planning/PROJECT_MAP_CONSOLIDATION_PLAN.md`, the
   `31_` collision note. Bump "Last full audit" date; clear this register's own
   `interim` status.
4. **Correct the OIDC assumption (D7).** `DOCUMENTATION_AUDIT.md` currently prescribes
   rewriting several docs "for OAuth2 proxy." Change those action items to: *"document
   current PAM/AD model; note OIDC as future Infra-Iam-PKI integration (not T1)."*

**Verify:** all internal links resolve (`grep`-check the two former dead links are gone);
no doc claims OIDC is a live T1 component.

**Commit:** `docs: reconcile documentation-audit layer + fix dangling triage ref`

---

## Step 1 — Archive `next_gen/` with motivation + revival hooks

**Goal:** remove the ungoverned Python tier from the active surface while preserving
its salvage value.

**Actions**
1. `git mv next_gen archive/next_gen`.
2. Fix the single dangling reference in `docs/operations/sysadmin_troubleshooting_guide.md`.
3. Author `archive/next_gen/README.md` containing:
   - **What it was:** Python+Ansible rewrite POC — `main.py` (`--detect-backend`,
     `--backup`); Ansible role tree for nginx/rstudio/samba/sssd/kerberos/telemetry/letsencrypt.
   - **Why parked:** stalled at 2-flag prototype; empty `tests/`; conflicts with the
     single-LPIC-3-operator profile and the smallest-blast-radius ethos;
     `FUTURE_MIGRATION.md §5` marks IaC speculative.
   - **Salvage value (explicit):** the Ansible **kerberos / sssd / samba roles** may
     inform **T3 (k8s) AD-integration design** (an open T3 blocker), and the role
     structure may inform **T2 Docker-image entrypoint** parity. Candidate source
     material — NOT active code.
   - **Revival trigger:** team-size change (per `FUTURE_MIGRATION.md §5`) OR a concrete
     T3 AD-integration spike.
4. This README seeds **ADR-0001** (Step 3).

**Verify:** `grep -rn "next_gen" --include=*.sh --include=*.yml --include=*.md . | grep -v archive/ | grep -v .git/`
returns only intended hits (zero dangling).

**Commit:** `chore: archive next_gen prototype + disposition note (T3/Docker salvage)`

---

## Step 2 — Reconcile the map to the actual (PAM/AD) topology

**Goal:** feed the existing generated map the truth (D7); do not rebuild it.

**Actions**
1. Read-only drift capture: `.ai/generate.sh --check` and `.ai/validate.sh --ci`
   (both already inside `make audit`).
2. **`docs/architecture/SYSTEM_OVERVIEW.md`** (flagged `needs-rewrite`): verify-then-
   rewrite-if-needed to current T1 = RStudio Server + nginx portal (PAM/AD auth) +
   SSSD/Samba + Kerberos + Let's Encrypt + telemetry. Remove stale TTYD/Nextcloud/
   RAMDisk-`/tmp` claims; use `/Rtmp` 400 GB ext4. **Mark OIDC/oauth2-proxy as a future
   Infra-Iam-PKI integration under test, NOT current T1.** Update its status in
   `DOCUMENTATION_AUDIT.md` accordingly.
3. **`docs/reference/SCRIPT_CATALOG.md`:** document the `launch_external_script` dynamic
   dispatch (the `find scripts/ -maxdepth 1 -executable` runtime menu + special-cased
   `install_secure_access.sh` / `install_nginx.sh` handlers) — this is why many scripts
   look "unreferenced." Also document the SSSD-vs-Samba backend choice.
4. **`31_` collision (D5): document, DEFER rename.** Add a note in `SCRIPT_CATALOG.md`
   that `31_optimize_system.sh` and `31_setup_web_portal.sh` share a prefix by accident
   (distinct purposes). Produce a **rename-impact audit artifact** in this PR listing all
   ~11 call sites (8 docs + `30_install_nginx.sh` + `40_install_telemetry.sh` +
   `99_postmortem_forensics.sh` + `.ai/project.yml` + `.ai/agents.md` + `host-install-audit`
   skill) and recommend `31_setup_web_portal.sh` → `33_setup_web_portal.sh` for a
   dedicated follow-up PR. **Do NOT rename in this PR.**
5. Regenerate agent files (`.ai/generate.sh`); commit the regenerated `CLAUDE.md`/
   `.cursorrules`/etc. alongside the source edits (CI `ai-context.yml` enforces freshness).

**Verify:** `.ai/generate.sh --check` clean; `.ai/validate.sh --ci` clean; no doc claims
OIDC is live T1.

**Commit:** `docs: reconcile map to PAM/AD topology + dynamic dispatch + 31_ collision audit`

---

## Step 3 — Stand up the MADR ADR system (highest ROI)

**Goal:** create the missing formal decision-record system and backfill load-bearing
decisions so they stop living as folklore.

**Actions**
1. Create `docs/adr/` with:
   - `README.md` — index + MADR convention statement.
   - `0000-template.md` — MADR template (Context and Problem Statement / Considered
     Options / Decision Outcome / Consequences / status).
2. Backfill ADRs (mine rationale from `.ai/project.yml`, `agents.md`,
   `docs/architecture/`, and the audit docs):
   - **ADR-0001** — Do NOT rewrite T1 in Python; `next_gen/` archived (cite the
     `archive/next_gen/README.md` salvage note for T3 Kerberos/Docker).
   - **ADR-0002** — Serial BLAS (`libopenblas0-serial`) not pthread (SIGSEGV).
   - **ADR-0003** — R temp on `/Rtmp` (400 GB ext4) not `/tmp`.
   - **ADR-0004** — Dual AD backend SSSD vs Samba (+ record the **OPEN** XOR-enforcement
     finding from `T1_HOST_DEPLOYMENT_AUDIT.md §1`).
   - **ADR-0005** — Bind mounts only, zero named Docker volumes.
   - **ADR-0006** — PAM `libpam-krb5` removal for uid<10000 `passwd` SIGSEGV.
   - **ADR-0007** — Tier model T1→T2→T3; reject RStudio Connect / JupyterHub (HC-13).
   - **ADR-0008** — Auth model: PAM/AD now; OIDC deferred to Infra-Iam-PKI (records the
     topology truth from D7).
3. Link `docs/adr/` from `docs/README.md`, `DOCUMENTATION_AUDIT.md`, both audit docs,
   and `.ai/agents.md` (so agents consult ADRs before re-litigating settled decisions).

**Note:** pure markdown — `script-safety-review` does not apply.

**Verify:** every ADR has a status; index links resolve; `make audit` doc-coherence
passes.

**Commit:** `docs: add MADR ADR system + backfill 8 decisions`

---

## Step 4 — Triage-gated prune → archive

**Goal:** shrink the active template/code surface, but prove each target dead first.

**Actions**
1. **Triage artifact first** (commit it under `docs/planning/` or the PR description):
   for every candidate, run and record `grep -rn` across active
   `scripts/ templates/ config/ lib/ tests/ .github/ .ai/` + `docker-deploy/`
   (excluding `archive/`, `.git/`, `Infra-Iam-PKI/`); confirm it is not one of the 5
   live R templates wired by `50_setup_nodes.sh` and not in the render sets of
   `templates_parse.sh` / `nginx_render_check.sh`.
   - Pre-verified dead: `templates/old/**`; top-level versioned `Rprofile_site*` cruft
     (`_original`, `_v11.2`, `Rprofile_site_R.template_v11.3`, `_v11.4`, `_v11.4_final`,
     `_v12_nimble_router`, `cleanup_r_orphans.sh copy.template`); `r_env_manager.sh:1123-1161`.
2. For items passing triage: `git mv templates/old archive/templates/old`; `git mv` the
   versioned top-level cruft into `archive/templates/`.
3. `r_env_manager.sh:1123-1161` — delete the dead commented `launch_external_script`
   block (T1 file → run `host-install-audit` + `script-safety-review`; comment-only,
   the live function and all logic untouched).

**Verify (safety gates, ALL must pass before commit):**
- `bash -n r_env_manager.sh`
- `bash tests/check_exec_bits.sh`
- `bash tests/templates_parse.sh`
- `bash tests/nginx_render_check.sh`
- re-grep confirms nothing active references anything moved into `archive/`.

**Commit:** `chore: triage + archive dead templates + remove dead launcher block`

---

## Step 5 — Fix CI permission-denied failures + deepen tests

**Goal:** unblock CI and add a test net to the load-bearing, currently-untested code.

> **BLOCKER (D6):** this step requires the failing GitHub Actions run logs. They cannot
> be obtained read-only. Steps 0–4 can complete without them; do Step 5 only once logs
> are supplied.

**Actions**
1. **Diagnose CI permission-denied (await logs).** Static-analysis suspects to confirm
   against the real logs:
   - `t1-static` job's **Root-guard contract** step runs `./r_env_manager.sh` expecting
     non-root refusal — semantics break if the runner UID is 0.
   - `r-runtime-static` / `nginx-config` jobs `sudo apt-get install` — fails on
     self-hosted runners without passwordless sudo.
   - Any test writing outside `mktemp` (none found so far; `test_pr1_critical_fixes.sh`
     correctly uses `mktemp` with simulated `/etc` paths like `${bk}/${TMP#/}/etc/...`).
2. **Fix** the identified cause in `.github/workflows/ci.yml` — **no `|| true` masking**.
3. **New tests (test-first, before any future refactor of these files):**
   - Extend `tests/templates_parse.sh` (or a sibling) to assert each `Rprofile_site.d/`
     fragment's `%%KEY%%` contract renders and R-parses.
   - `tests/unit/test_setup_nodes.bats` — exercise the **pure** logic of
     `50_setup_nodes.sh` (CORETYPE detection, `/Rtmp` path selection, key substitution)
     via function sourcing + stubs, `mktemp`-only, no system mutation; mirror the
     existing `test_common_utils.bats` stubbing pattern.
   - Bats cases for untested `lib/common_utils.sh` functions (`resolve_site_config`,
     `process_systemd_template`, backup/restore edge paths).
4. Wire new test files into `ci.yml` (`t1-bash-unit` / `r-runtime-static`).

**Note:** new `.sh`/`.bats` → `script-safety-review` applies (set -euo pipefail,
mktemp-only writes, service stubs).

**Verify:** full local `tests/` run green; CI green on the branch.

**Commit:** `ci+test: fix permission-denied failures + deepen setup_nodes/Rprofile.d/common_utils coverage`

---

## Commit sequence (summary)

| # | Commit message |
|---|---|
| 0 | `docs: reconcile documentation-audit layer + fix dangling triage ref` |
| 1 | `chore: archive next_gen prototype + disposition note (T3/Docker salvage)` |
| 2 | `docs: reconcile map to PAM/AD topology + dynamic dispatch + 31_ collision audit` |
| 3 | `docs: add MADR ADR system + backfill 8 decisions` |
| 4 | `chore: triage + archive dead templates + remove dead launcher block` |
| 5 | `ci+test: fix permission-denied failures + deepen ... coverage` |

---

## Out of scope (do NOT touch while executing this plan)

- `Infra-Iam-PKI/` (submodule — HC-04). OIDC/Keycloak/OOD work lives there, not here.
- `src/biome_core_rust/` (DORMANT — do not activate).
- `sandbox/` (KNOWN BROKEN — not a validation path).
- `kubernetes-deploy/` (T3 SKELETON_NOT_READY) and `docker-deploy/` (T2) — no edits;
  this plan is T1-only.
- The `31_` **rename** itself — deferred to a follow-up PR (D5).

---

## Net effect when complete

- Active surface shrinks (next_gen + ~26 dead templates + dead code block leave view)
  with **zero data loss** — everything in `archive/` and git history.
- The generated map becomes truthful (stale `SYSTEM_OVERVIEW.md` fixed; dynamic dispatch
  and SSSD/Samba documented; OIDC correctly framed as future, not live).
- The biggest gap is closed: a formal **MADR ADR system**, including the permanent
  "no T1→Python rewrite" record so the question is not re-litigated.
- The highest-risk untested code (`50_setup_nodes.sh`, `Rprofile_site.d/`) gains a test
  net before anyone refactors it, and CI is green again.
