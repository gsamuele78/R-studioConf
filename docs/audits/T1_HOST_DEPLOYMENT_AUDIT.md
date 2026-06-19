<!-- docs/audits/T1_HOST_DEPLOYMENT_AUDIT.md -->
# T1 Host Deployment — Deep Audit Report

> **Tier:** T1 (host) — authoritative.
> **Audit date:** 2026-06.
> **Status of this document:** living reference. Literal PII (IPs, mail domain)
> has been sanitized to match the repo scrub; findings keep their file:line
> references. Each finding is tagged **[FIXED]**, **[PARTIAL]**, or **[OPEN]**
> per the *Status (2026-06-19)* note below — do not assume an OPEN item is done.

> **Status (2026-06-19):** the security/PII findings in §2 and the missing
> repo-level CHANGELOG in §5 have been addressed by the *site-local config
> overlay* work — see [`../../CHANGELOG.md`](../../CHANGELOG.md),
> [`../../config/SITE_OVERRIDE.md`](../../config/SITE_OVERRIDE.md),
> [`../reference/CONFIGURATION_MAP.md`](../reference/CONFIGURATION_MAP.md) §0, and
> `plan/secret_scrub_site_overlay_plan.md`. The root **README.md** rewrite
> (§5 / Phase 0.1), the **false-green CI** rewrite (§5 / Phase 0.2 — now
> [`ci.yml`](../../.github/workflows/ci.yml)) and the **script exec-bit** hygiene
> (§3) are now **[FIXED]**. The CRITICAL correctness defects in §1 and most of
> §3/§4 and the rest of §5 remain **OPEN**.

---

## TL;DR

The core engineering is better than the paperwork around it. `50_setup_nodes.sh`,
the `Rprofile_site.d/` fragment system, and the Rprofile CHANGELOG discipline are
genuinely strong. But the project's front door (README) describes a repo that no
longer exists, CI tests a deleted layout with `|| true` masking everything, the
shared library has a rollback function that is a silent no-op, 8 privileged
scripts run with strict mode commented out, a public GitHub repo leaked a complete
reconnaissance kit (researcher/PI map + AD topology), and ~26 orphaned template
files (~1.6 MB) bury the 30 that actually matter.

Original totals: **4 CRITICAL, ~19 HIGH, ~21 MEDIUM** findings.

---

## 1. Critical defects (silent-failure class — worst under the pessimistic ethos)

- **[OPEN] `lib/common_utils.sh:591-624` — `restore_config()` is a no-op that reports success.**
  It prompts, logs "Restoring…", logs "restored", restarts sssd/rstudio/nginx — and
  never copies a single file back (`_restore_item` at `:562` is dead code). An
  operator rolling back a botched deploy gets services restarted over broken
  configs and a green message.
- **[OPEN] `r_env_manager.sh:1042-1078` — menu option 10 (Uninstall) crashes on arrival.**
  `INSTALLED_CRAN_PACKAGES`, `INSTALLED_GITHUB_PACKAGES`, `R_ENV_STATE_FILE` are
  never defined anywhere; under `set -u` the function aborts at the first expansion.
- **[OPEN] AD backend XOR not enforced.** The skill mandates SSSD XOR Samba per host,
  but neither `10_join_domain_sssd.sh` nor `11_join_domain_samba.sh` checks for the
  other backend before converting the NSS/PAM stack. Running both leaves a
  half-converted auth stack.
- **[OPEN] `lib/common_utils.sh:270-272` — apt failures converted to success.**
  `if ! run_command …; then return $?; fi` returns the status of the negated
  condition (0). A failed `apt-get install` propagates as success to `set -e`
  callers. Related: every `run_command` exit path does a bare `set +o pipefail`,
  permanently stripping pipefail from the calling script — the library defeats
  HC-03 for everyone who uses it.

---

## 2. Security & privacy (public repo)

> **[FIXED] as of 2026-06-19** via the `config/site/` overlay (PII no longer
> committed; sanitized `*.example` shipped; real values gitignored). The items
> below are retained for history. **Note:** the data remained in **git history**
> until `git filter-repo` is run — treat as already-disclosed.

No credentials were committed anywhere — good. But the combination of committed
data formed a complete reconnaissance kit:

- **[FIXED] `config/scopri_progetti_known.conf`** — 7+ real researcher usernames
  mapped to supervisors and funded projects (third-party PII). *Now: de-tracked;
  ships as `.example`; theme map externalized to `config/site/scopri_theme_map.conf`.*
- **[FIXED] `config/admin_recipients.txt`** — 10 real PI emails (commented but
  readable), the production IP, internal Teams group. *Now: de-tracked + `.example`.*
- **[FIXED] `config/lib_kerberos_setup.vars.conf`** — real AD realm, admin UPN, OU
  paths, the exact security groups whose members get shell access, and all
  DC/KDC hostnames. *Now: de-tracked + `.example`, sourced from `config/site/` with
  a fail-fast `__FILL_ME__` gate.*
- **[FIXED] Hardcoded in executables:** the operator's own AD username in
  `test_rstudio_login.sh`, the institutional mail domain in
  `ttyd_login_wrapper.sh` and `telemetry_api.py`. *Now: parameterized via env
  (`RSTUDIO_TEST_USER`, `NGINX_EXTERNAL_BASE`, `BIOME_MAIL_DOMAIN`,
  `TTYD_DOMAIN_SUFFIX`).* The original also placed the password in `curl`'s argv
  (visible in `ps`) — **[OPEN]**, deferred as a Phase-2 item.
- **[OPEN] HC-15 violation:** Google Fonts CDN calls in
  `portal_index.html.template`, `portal_index_simple.html.template`,
  `server_status_wrapper.html.template` (mirrored in T2 — fix T1 first per rule 3).
- **[OPEN] World-writable artifacts on a multi-user host:** `chmod 666` log file
  (`50_setup_nodes.sh:1627`), `chmod 777` notifications dir (`:2116`) —
  symlink/log-forgery vectors; use group+setgid instead.

History purge: `git filter-repo`/BFG remains **[OPEN]** — operator's call (the
realm/KDC names were partially DNS-discoverable; the PI email list and
user→project map are the spear-phishing assets).

---

## 3. Scripts (`scripts/`, `init.sh`, `r_env_manager.sh`)

- **[OPEN]** 8 scripts have `set -euo pipefail` commented out (`12_`, `15_`,
  `20_configure_rstudio.sh` — 665 privileged lines, `31_setup_web_portal.sh`,
  `99_verify_domain_join.sh`, `test_rstudio_login.sh`, `ttyd_login_wrapper.sh`).
  HC-03 violation on exactly the scripts doing `sed -i`/`chown` on `/etc`.
- **[FIXED]** 6 required scripts were not executable (`git ls-files -s = 100644`):
  `15_setup_nginx_cleanup.sh`, `40_install_telemetry.sh`, three `99_*`,
  `pin_r_version.sh` — so `15_`/`40_` were invisible in the launcher menu.
  *Now: all committed `100755`, and `tests/check_exec_bits.sh` (wired into the
  `t1-static` CI job) pins the git mode so the regression cannot return.*
- **[OPEN]** Duplicate `31_` prefix (`31_optimize_system.sh` and
  `31_setup_web_portal.sh`; the latter's header self-identifies as
  `09_web_portal_setup.sh`). Filesystem-arbitrary ordering in the launcher.
- **[OPEN] HC-12 violation:** `50_setup_nodes.sh:1571-1572` edits
  `rstudio-prefs.json` with `sed` instead of `jq` (rule #16). `jq` is already a
  dependency.
- **[OPEN] SSOT version drift:** `r_env_manager.sh:196,620` hardcode
  `RSTUDIO_VERSION_FALLBACK="2023.06.0"` vs canonical `2026.01.1+403`;
  `pin_r_version.sh:42` re-hardcodes `4.6.0`. Rule 19.
- **[OPEN]** `init.sh` itself violates HC-03 (no strict mode, no chmod guard).
  `r_env_manager.sh`: non-atomic `acquire_lock` (TOCTOU, no stale-PID recovery),
  dead commented block at `:1113-1151`, off-by-one menu range text.
- **[OPEN]** `13_harden_pam_password.sh` and `fix_pam_segfault_inplace.sh` are
  ~90% duplicate one-incident scripts that bypass `common_utils.sh` with their
  own logging.

---

## 4. Lib & templates

- **[OPEN]** The `process_template`/`process_systemd_template` pair: two divergent
  sed-based engines, one of which (systemd) does unescaped `${!var}` interpolation
  (injection/corruption risk). Both should collapse into one bash-native
  `${content//…/…}` replacement — newline-safe and injection-safe.
- **[OPEN]** 26 orphaned template files (~1.6 MB): 8 versioned Rprofile copies, two
  different files both claiming v11.3 (inconsistent naming, divergent content), all
  of `templates/old/` (16 files), a `cleanup_r_orphans.sh copy.template` that is one
  revision stale and would kill legitimate PSOCK workers if ever deployed.
- **[OPEN]** Dead `Renviron.template` holds the newest engineering decision
  (`KERAS_HOME` on NFS, not local) that the live heredoc generator at
  `50_setup_nodes.sh:1170` contradicts. Port the decision into the live path
  before archiving.
- **Good news:** `/Rtmp` and BLAS-serial invariants pass cleanly everywhere;
  `lib/biome-portal.js` is correctly wired (not orphaned); the 14
  `Rprofile_site.d/` fragments follow the documented ordering and are
  deploy-validated.

---

## 5. Documentation drift

- **[FIXED]** Root `README.md` is now an accurate thin landing page (real
  `init.sh`→`r_env_manager.sh` entry point, real `scripts/`/`config/`/`templates/`
  layout, tier model, engineering-leverage section) pointing to
  [`docs/README.md`](../README.md) + [`INSTALLATION_GUIDE.md`](../deployment/INSTALLATION_GUIDE.md).
  *The prior `setup_r_env.sh` + `install/` + `/var/log/r_setup/` + `:8787` content
  is gone.*
- **[FIXED]** `.github/workflows/test_setup_r_env.yml` tested the ghost layout with
  `|| true` everywhere → permanent false green. *Now: deleted and replaced by
  [`ci.yml`](../../.github/workflows/ci.yml) — a 7-job pipeline (T1 constraint/syntax/
  exec-bit gate, bats unit tests, Rprofile-template parse gate + r_lint oracle,
  `nginx -t` render check, T2 `compose config` + hadolint + light-image build, a
  nightly 01:00 monster-image build canary, and a package-manifest lint), no
  `|| true`. Exposed and fixed a `set -u` crash in `.ai/generate.sh` (bash-5.2 empty
  associative array) that had been silently aborting `make audit`.*
- **[OPEN]** `.ai/agents.md §5` is stale — missing 10+ scripts, 3 wrong
  descriptions — and it feeds those wrong descriptions to every AI agent.
- **[OPEN] `.ai/generate.sh` IDE-rule drift (surfaced by `ci.yml`).** With the
  `set -u` crash fixed, `generate-check` now runs and reveals the 6 generated IDE
  files (`CLAUDE.md`, `.clinerules`, …) are out of sync, and that the generator
  (a) **date-stamps** its output (so it self-drifts daily) and (b) **misclassifies**
  the `${VAR:-img}:${IMAGE_TAG}` local images as upstream (it predates that compose
  syntax). Because the committed files are *semantically better* than a regenerate,
  `generate-check` is wired as **informational (non-blocking)** in CI, not a gate.
  Real fix (deferred): make the stamp deterministic + teach the classifier the
  `${IMAGE_TAG}` convention, then regenerate.
- **[PARTIAL]** Reference docs lag: `SCRIPT_CATALOG`/`CONFIGURATION_MAP`/
  `DIAGNOSTICS_INDEX` miss `pin_r_version.*`, all of `scripts/tools/` (8 files), and
  3 diagnostics; `CONFIGURATION_MAP` still said `RPROFILE_VERSION 12.4` (actual
  12.10). *`CONFIGURATION_MAP.md` has since been updated for the config/site
  overlay (§0); the version-string and script-coverage gaps remain.*
- **[FIXED]** No repo-level CHANGELOG — only the (exemplary, `make doc-coherence`-
  enforced) `Rprofile_site.CHANGELOG.md`. `r_env_manager.sh` claims "v2.0.0" with
  zero history. *Now: repo-root [`CHANGELOG.md`](../../CHANGELOG.md) added
  (Keep a Changelog).*
- **Accurate and worth preserving as the model:** `INSTALLATION_GUIDE.md`, the
  Makefile audit gate, and rule-18 version↔changelog coupling.

---

## Proposed roadmap

Sequenced documentation/changelog/README first, then correctness, then hygiene,
then features. Each phase is independently shippable.

**Phase 0 — Stop the bleeding (docs front door + false-green CI)**
1. Rewrite root `README.md` as a thin accurate landing page → point to
   `docs/README.md` + `INSTALLATION_GUIDE.md`. **[FIXED]**
2. Fix or delete `.github/workflows/test_setup_r_env.yml` (remove `|| true`
   masking; test real entrypoints). **[FIXED]** — deleted; replaced by `ci.yml`
   (7 jobs, T1 + T2, zero `|| true`). Also fixed the `.ai/generate.sh` `set -u`
   crash it surfaced. Exec-bit hygiene (§3) fixed as part of this.
3. Introduce a repo-root `CHANGELOG.md` (Keep-a-Changelog); add `[Unreleased]`. **[FIXED]**
4. Re-sync `.ai/agents.md §5` and the corrupted
   `.agents/skills/host-install-audit/SKILL.md`. **[OPEN]**

**Phase 1 — CRITICAL correctness** *(all [OPEN])*
- Implement (or hard-fail) `restore_config()`.
- Fix the `return $?` apt-masking bug and the pipefail-stripping in `run_command`.
- Define/guard the uninstall state vars so menu option 10 works.
- Add the AD-backend XOR precondition to both join scripts.

**Phase 2 — HIGH hygiene** *(all [OPEN])*
- Uncomment `set -euo pipefail` in the 8 scripts; audit `20_configure_rstudio.sh`'s
  `sed -i` calls. `chmod +x` + commit the 6 scripts; resolve the duplicate `31_`.
  Remove hardcoded `2023.06.0`/`4.6.0`; source from SSOT. `init.sh` strict mode +
  chmod guard. Replace `sed` JSON edits with `jq`. De-argv the test login password.

**Phase 3 — Security/privacy** *(security overlay [FIXED]; fonts/perms [OPEN])*
- Convert PII configs to placeholder + gitignored site overrides; purge history. **[FIXED]** (history purge [OPEN]).
- Self-host portal fonts (HC-15), T1 then T2. **[OPEN]**
- Tighten 666/777 to group+setgid; de-hardcode operator username/domain.
  *(username/domain [FIXED]; perms [OPEN])*

**Phase 4 — Template & doc consolidation** *(all [OPEN])*
- Port the KERAS/NFS decision into the live generator, then move 26 orphaned
  templates to `archive/` with a lineage README. Collapse the two templating
  engines into one. Refresh `SCRIPT_CATALOG`/`CONFIGURATION_MAP`/
  `DIAGNOSTICS_INDEX`; extend `make doc-coherence` to pin the
  `CONFIGURATION_MAP` version string.

**Phase 5 — Operability features** *(all [OPEN])*
- Uniform `--help`/`-y`/`--dry-run` across numbered scripts (model on
  `50_setup_nodes.sh` and `31_optimize_system.sh`). flock-based locking with
  stale-PID recovery in `r_env_manager.sh`. De-duplicate the PAM scripts and the
  resolve_* email helpers.
