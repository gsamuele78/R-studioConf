<!-- docs/operations/DIAGNOSTICS_INDEX.md -->
# Diagnostics Index — `99_*.sh` and `fix_*.sh` Toolbox

> **Audience:** sysadmins / on-call.  
> **Tier:** T1 host.  
> **Last updated:** 2026-09-23.

Every diagnostic and one-shot fix script in `scripts/` mapped to:
**when to run / what it produces / where logs land / what to do next.**
Cross-linked from [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md).

> **Pessimistic-engineering rule.** None of these scripts mutate state
> by default unless explicitly named `fix_*` or invoked with a
> destructive flag. They are safe on production hosts. One nuance:
> the runtime tier of `99_check_rprofile_health.sh` loads the real
> profile as the probed user, so it creates the same per-user dirs a
> login does (see its entry; `--static-only` avoids it).

---

## 1. Health & inventory

### `scripts/99_health_check.sh`

**Run when:** routine ops, after any deploy, after any R-version bump.
**Mutates:** no.
**What it checks:**

* Every BIOME service is `active`.
* `realm list` is non-empty (AD join intact).
* `/etc/R/Rprofile.site` integrity hash matches dispatcher.
* `/etc/R/Rprofile_site.d/` fragments load order is sane.
* `/Rtmp` is mounted with the expected size.
* `libRblas.so.3` resolves to `libopenblas-serial.so.*`.
* Audit-v28 binary present and executable.

**Output:** stdout pass/fail per check; non-zero exit on any FAIL.
**Next step on FAIL:** match the failing line to the matching section
of [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md).

### `scripts/99_audit_r_environment.sh`

**Run when:** before/after R/RStudio version bump; before bug-report
collection; after package install batches.
**Modes:**

```bash
sudo ./99_audit_r_environment.sh                 # deploy + run as root
./99_audit_r_environment.sh --deploy-only        # render audit script, print path
./99_audit_r_environment.sh --run-only           # run already-deployed audit
```

**Mutates:** deploys `/etc/biome-calc/audit/00_audit_v28.R`. Idempotent.
**Output:** Markdown audit report under `${BIOME_CONF}/audit/`.
**Next step:** attach the report to any user-bug ticket.

### `scripts/99_check_pkg_drift.sh`

**Run when:** weekly (cron); after CRAN refresh; after `install.packages`
batches.
**Wraps:** `scripts/tools/r_pkg_drift_detector.R`.
**Mutates:** no (baseline lives on local disk, not NFS — owned by sysadmin).
**Output:** drift diff; non-zero exit on drift detected.
**Next step on drift:** rebuild affected node ([`CLEAN_VM_BASELINE.md`](CLEAN_VM_BASELINE.md))
or pin the drifting package(s) in
`config/r_env_manager.conf :: R_USER_PACKAGES_CRAN`.

### `scripts/99_check_user_renviron_overrides.sh`

**Run when:** user reports environment variable mismatch; after
`50_setup_nodes.sh` deploy; when debugging `~/.Renviron` overrides that
shadow system defaults.
**Mutates:** only with `--fix --commit`: comments out `R_LIBS_USER` /
`R_LIBS_SITE` / `R_LIBS` lines after a timestamped backup (`--fix` alone
is a dry-run).
**What it checks:** scans all user home directories for `~/.Renviron`
files that override system-set variables (`R_LIBS_SITE`, `R_LIBS_USER`,
`TMPDIR`, `RSTUDIO_WHICH_R`, OpenBLAS/OMP thread vars). Flags any
override that diverges from the BIOME-CALC canonical values in
`/etc/R/Renviron.site`.
**Output:** per-user report of overrides; warning banner for security-
sensitive variables (`RSTUDIO_WHICH_R`, `TMPDIR`).
**Next step on conflict:** notify user; if override is malicious or
accidentally breaks the platform, escalate to sysadmin to audit the
user's `.Renviron`.

### `scripts/99_check_rprofile_health.sh`  *(v2.0 — check + per-user repair)*

**Run when:** after any `50_setup_nodes.sh` deploy; the welcome banner is
missing or guards look inactive; one user's sessions fail or crawl while
others are fine; `99_diagnose_user_script.sh` reports **L3s PASS + L3 FAIL**
(the user's own startup files); routine weekly ops (`--static-only`).
**Mutates:** user files only with `--commit`. `--static-only` is read-only.
The default run adds a runtime tier that loads the real dispatcher **as the
probed user** (never as root), so it leaves what a login leaves:
`/Rtmp/biome_<user>/…`, `/var/lib/biome-Rlibs/<user>/<Rver>`. As root without
`--user` that tier is skipped rather than creating root-owned dirs
(`--allow-root-probes` overrides). `--fix --commit`, `--reset-profile --commit`
and `--undo-reset --commit` touch only that user's files: each change is
backed up (`<file>.bak.<UTC stamp>`) or moved to
`~/.biome-profile-quarantine/<STAMP>/`, never deleted. System files are never
modified; findings print the redeploy command instead.
**What it checks (10 sections; runtime ones marked):**

1. **Dispatcher deployment** — presence, unsubstituted `%%PLACEHOLDERS%%`,
   R syntax, deployed version vs `config/setup_nodes.vars.conf`, version age,
   `sys_log` target, and that the R RStudio launches reads the deployed file.
2. **Fragment chain** — inventory against the expected 14 fragments (v12.10),
   missing/unexpected fragments, shared-prefix load-order hazards,
   per-fragment syntax, template vs deployed count.
3. **Byte-compiled bundle** (v12.3) — `bundle.Rc` + `manifest.txt` presence,
   manifest md5 freshness vs on-disk fragments, bundle age vs newest fragment.
4. **Guard installation** *(runtime)* — `solve()`, `dist()`, `outer()`,
   `expand.grid()` guards, `.biome_env`, `tools:biome_calc` attachment,
   critical tools (`biome_make_cluster`, `status`).
5. **BLAS & threading** — `libopenblas0-serial` vs `pthread`, active BLAS
   alternative, CORETYPE wrappers; *(runtime)* BLAS + thread caps in-session.
6. **Renviron.site contract** — required vars, last `TMPDIR` definition on
   `/Rtmp`, local-disk `R_LIBS_USER` (v12.4+), login scripts that rewrite
   users' `~/.Renviron` (hotfix: `fix_login_script_rlibs_inplace.sh`, §5);
   *(runtime)* the file actually reaches the session.
7. **Per-user startup** (`--user NAME`) — home, `~/.Renviron`, `~/.Rprofile`,
   workspace restore (`~/.RData`), RStudio session state, per-user system
   dirs, and *(runtime)* an A/B run: system baseline vs the same R with the
   user's own startup files, executed as that user.
8. **Worker survival** *(runtime)* — PSOCK fast path (v10.0 `return()` regression).
9. **Runtime profile load** *(runtime)* — dispatcher entered, MAIN block
   completed, load time, fragment error logs.
10. **Forensic tools** — `r_minimal` launcher + minimal profile availability.

```bash
sudo bash scripts/99_check_rprofile_health.sh --static-only                  # node integrity (cron)
sudo bash scripts/99_check_rprofile_health.sh --user researcher1             # full check as that user
sudo bash scripts/99_check_rprofile_health.sh --user researcher1 --fix       # repair plan (dry-run)
sudo bash scripts/99_check_rprofile_health.sh --user researcher1 --fix --commit
sudo bash scripts/99_check_rprofile_health.sh --user researcher1 --reset-profile --commit
sudo bash scripts/99_check_rprofile_health.sh --user researcher1 --undo-reset list
```

Runs from the repo checkout (not deployed to `/usr/local/bin`). A non-root
caller may only name themselves in `--user`. `-y` skips the confirmation
prompt (required without a TTY). `R_LIBS_*` lines in `~/.Renviron` are
reported but not changed here: `50_setup_nodes.sh` option 4 and
`99_check_user_renviron_overrides.sh --fix --commit` own them.

**Output:** stdout PASS/WARN/FAIL/CRIT per check; summary with verdict.
**Exit codes:** `0` all clear · `1` CRIT/FAIL · `2` warnings only (or runtime
tier skipped) · `3` invocation error / refused · `4` a requested fix, reset or
undo was not (fully) applied.
**Next step on FAIL:** each finding prints its fix. System findings usually
point to `sudo bash scripts/50_setup_nodes.sh` option 3 (config files only),
then `sudo systemctl restart rstudio-server`; section 7 findings feed the
`--fix` plan.
**Regression test:** `tests/rprofile_health_test.sh` (fixture trees via
`BIOME_HEALTH_ROOT`, real R; CI job `r-runtime-static`).

### `scripts/99_diagnose_rstudio_plot_pane.R`  *(R script, not bash)*

**Run when:** user reports blank RStudio Plots pane; `plot()` or
`print(ggplot)` produces no visible output in browser.
**Run from:** RStudio console: `source("scripts/99_diagnose_rstudio_plot_pane.R")`
**Mutates:** no (diagnostic only; repair mode is opt-in).
**What it checks:** current graphics device, RStudioGD availability,
`ragg::agg_png` guard presence, Rprofile fragment version, interactive-
session detection.
**Output:** CRITICAL/WARN/OK per check; attempts `options(device="RStudioGD")`
repair if safe.
**Next step:** see [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) §1.7.

### `scripts/99_botanical_plot_stress_test.R`  *(R script, not bash)*

**Run when:** validating RStudio graphics pipeline after deploy or
upgrade; reproducing Plots-pane issues under controlled conditions.
**Run from:** RStudio console: `source("scripts/99_botanical_plot_stress_test.R")`
**Mutates:** no (writes test plots to `/Rtmp/biome_<user>/plot_cache/`).
**What it checks:** base-R plot, ggplot2, ragg device, plot caching to
`/Rtmp`, RStudioGD WebSocket round-trip. Iterates over multiple plot
types and reports which render and which fail.
**Output:** pass/fail per plot type; timing per render.
**Next step on FAIL:** run `99_diagnose_rstudio_plot_pane.R` on the same
session.

---

## 2. Domain / identity

### `scripts/99_verify_domain_join.sh`

**Run when:** after `10_/11_join_domain_*.sh`; after any `passwd`
issue; when `id <ad-user>` returns nothing.
**Auto-detects:** SSSD vs Samba/Winbind backend.
**Mutates:** no.
**Checks:** realm presence, ticket cache, home-dir mount, fallback
homedir template, `id` resolution, kinit reachability.
**Next step:** see [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) §3.

---

## 3. Postmortem (after a crash you didn't witness)

### `scripts/99_postmortem_forensics.sh`

**Run when:** a researcher reports "it crashed" / "it doesn't work" and
you have no live repro.
**Modes:**

```bash
sudo bash 99_postmortem_forensics.sh --user <name>
sudo bash 99_postmortem_forensics.sh --user <name> --hours 4
sudo bash 99_postmortem_forensics.sh --user <name> --output /tmp/report.txt
```

**Mutates:** no.
**Output:** structured text dump:

* Crash type classification (SIGSEGV / OOM / hang / disk-full / PAM).
* Guard coverage (which `Rprofile_site.d/` fragment was the last to load).
* Unguarded edge cases identified.
* Actionable fix recommendation (system-side, per HC-13).

**Next step:** the recommendation either (a) names a fragment to edit
under `templates/Rprofile_site.d/` and redeploy via
`50_setup_nodes.sh`, or (b) names a system config knob in
`config/setup_nodes.vars.conf`.

### `scripts/99_troubleshoot_env.sh`

**Run when:** something is broken but you don't know which subsystem.
**Mode:** `--rprofile` for deep R-runtime check.
**Mutates:** no.
**Output:** consolidated diagnostic dump (logs, env, integration tests,
Rprofile state).
**Next step:** grep the dump for `FAIL` lines.

---

## 4. User-script triage (HC-13 ladder)

### `scripts/99_diagnose_user_script.sh`  *(generic harness, v1.4)*

**Run when:** a user reports their `.R` script reproducibly fails on
this server. Run it **as that user** (`su - <user>`); it refuses root
unless `BIOME_DIAG_ALLOW_ROOT=1` (forensic only).
**Mutates:** no — **never** modifies the user's `.R` (HC-13).
**What it does:** an infra probe and a user-code layer, then the same
unmodified script through four system layers:

* **L0:** `biome_diag()`, `biome_nfs_check()`, `biome_fork_probe()` under
  `r_minimal` — OS / NFS / fork health. The user script does not run yet.
* **L0a (NEW v1.3):** static lint over the user's `.R` via
  `scripts/lib/r_lint.R` + `scripts/lib/r_lint_rules.tsv` (22 rules,
  HIGH/MED/LOW). **Gated by `L0==PASS`** — only runs once infra is
  proven green, so the verdict reads "infra OK, *your code* needs X"
  rather than the usual sysadmin/researcher cut-and-paste loop.
  Skip with `--no-lint` or `BIOME_DIAG_NO_LINT=1`. Findings are
  *describe-only* — never patches the file. R020 (hardcoded credential)
  emits a SECURITY banner.
* **L0b (NEW v1.3, opt-in):** smoke run via `scripts/lib/r_smoke.R`
  with shrunk knobs (`BIOME_SMOKE_NITER`, `BIOME_SMOKE_NBURN`,
  `BIOME_SMOKE_N_CHAINS`, `BIOME_SMOKE_N_CHUNKS`, `BIOME_SMOKE_CHUNK_SIZE`).
  Enable with `--smoke` or `BIOME_DIAG_SMOKE=1`. Default timeout
  `BIOME_DIAG_SMOKE_TIMEOUT_S=300`.
* **L1:** `r_minimal_rscript` — minimal forensic profile, no `Rprofile.site`.
* **L2:** dispatcher with **every deployed fragment disabled**. The
  `BIOME_DISABLE_FRAGMENTS` list is built from the fragments in
  `BIOME_DIAG_FRAG_DIR` (default `/etc/R/Rprofile_site.d`), so a fragment
  added later cannot stay on (v1.3's hardcoded list left 04/05/42/52
  active). SKIPPED if no fragment is deployed.
* **L3s (v1.4):** full system profile (dispatcher + all fragments).
* **L3:** production — the full system profile **plus** the user's
  `~/.Renviron` and `~/.Rprofile`.

L1, L2 and L3s read **no** user startup files: `R_ENVIRON_USER=` (set but
empty) skips `./.Renviron` and `~/.Renviron`, `--no-init-file` skips both
`.Rprofile`s. L3s differs from L3 only by those files, so **L3s PASS +
L3 FAIL** blames the user's startup files: a config-layer repair with
`99_check_rprofile_health.sh --user <them> --fix`, never a code change.
L4 (clean-VM baseline, [`CLEAN_VM_BASELINE.md`](CLEAN_VM_BASELINE.md)) is
manual; the harness recommends it when every layer fails.

**Output:** `/tmp/user_diag_<user>_<TS>/` (or `BIOME_DIAG_OUT_DIR`) with
`report.md` (verdict, recommended next step, notes, per-layer table),
`summary.tsv` and per-layer `.log`/`.err`. `report.md` ends with the
**`old_vs_new` appendix** (v1.3) reading `/sys/fs/cgroup/$cgroup/{memory.max,
memory.current,cpu.max}` and contrasting actual cgroup limits against
the legacy "16 vCPU / 512 GB / 2 TB no-cgroup" VM — counters the
"sul vecchio server funzionava" deflection with hard numbers.

**Attribution when L3 fails:**

| L3s | L2 | L1 | Verdict → where the fix lands |
|---|---|---|---|
| PASS | any | any | the user's `~/.Renviron` / `~/.Rprofile` → `99_check_rprofile_health.sh --user <u> --fix` |
| FAIL | PASS | any | a fragment → bisect `BIOME_DISABLE_FRAGMENTS` without user startup files, patch it |
| FAIL | FAIL | PASS | dispatcher core or fragment-load contract (`templates/Rprofile_site.R.template`) |
| FAIL | FAIL | FAIL | not a profile issue → L4 clean VM, then L5 |
| other (SKIPPED / PROGRESSING) | | | "cause not attributable" → deploy what is missing, or re-run with a longer `--timeout` |

FAIL in this table also covers KILLED and TIMEOUT; for those two the report
adds a note to confirm with a second run, because they vary with load.

**Exit codes (v1.4 — keyed on the production layer L3):**

* `0` — L3 passed. Reduced-layer differences become notes (e.g. L3s FAIL +
  L3 PASS: the script only works with this user's startup files).
* `1` — L0 infra failed, or L3 failed (FAIL / KILLED / TIMEOUT).
* `2` — invocation error (missing script, bad flag, run as root).
* `3` — inconclusive: L3 was PROGRESSING when the timeout fired; re-run
  with `--timeout` doubled.
* `4` (v1.3) — **INFRASTRUCTURE GREEN — user code has HIGH-severity
  lint finding(s).** L3 passes, but L0a flagged HIGH issues. The
  research script is the bug; share `report.md` and the user-guide
  anchors with the researcher.

Up to v1.3 every run actually exited `143` (the cleanup trap killed the
harness itself), so nothing could rely on these codes.

Lint rule catalogue and good-vs-bad worked examples:
[`../user_guides/PARALLEL_R_DOS_AND_DONTS.md`](../user_guides/PARALLEL_R_DOS_AND_DONTS.md).

→ Full method: [`USER_SCRIPT_TROUBLESHOOTING.md`](USER_SCRIPT_TROUBLESHOOTING.md).

### `scripts/99_diagnose_lussu_hang.sh`  *(Lussu-specific overlay, v1.6)*

**Run when:** the user is "Lussu" or the symptom matches: long
`mclapply` over `terra::rast` stalls forever.
**Runs** the generic harness first (forwards `--timeout`,
`--progress-window`, `--no-lint`, `--smoke`; its exit code feeds the
overlay verdict), then three probes, all UNINTRUSIVE:

* **(E)** PSOCK swap — same code, but `mclapply → parLapply` on a
  PSOCK cluster, after a self-test that master globals reach the
  workers. Done in a sibling `.R` that `source()`s the user file
  via `local()` shim. The user's file is untouched.
* **(F)** terra todisk — preloads `terraOptions(todisk=TRUE,memfrac=0.2)`
  before sourcing.
* **(G)** allocator caps — asserts `MALLOC_ARENA_MAX`,
  `MALLOC_TRIM_THRESHOLD_` and `R_GC_MEM_GROW` reach PSOCK workers
  (v12.9.4). Does not source the user script.

**Output:** when the generic L3 did not pass, which probe makes the hang
go away: E → a PSOCK launcher or an mclapply-swap fragment; F →
`terraOptions(todisk=TRUE)` default in `50_pkg_hooks.R.template`. A failing
G points at `env_vec` in `30_psock_factory.R.template`. Files land in
`/tmp/lussu_diag_<user>_<TS>/` (generic `report.md`, `lussu_overlay.tsv`,
`shims/`).
**Exit codes:** `0` generic and all probes pass · `1` a genuine failure ·
`2` invocation error · `3` PROGRESSING only · `4` generic exit 4 and all
probes pass. Up to v1.5 the overlay died with `143` right after the generic
harness and never ran the probes (fixed in v1.6).

→ Full method: [`LUSSU_HANG_BISECTION.md`](LUSSU_HANG_BISECTION.md).

---

## 5. One-shot fixes (these DO mutate state)

### `scripts/13_harden_pam_password.sh`

**Run when:** new install, after AD join, before RStudio config.
**Mutates:** purges `libpam-krb5`, removes `biome-localguard`
profile, regenerates `/etc/pam.d/common-*`. Idempotent.
**Doc:** [`../deployment/PAM_HARDENING.md`](../deployment/PAM_HARDENING.md).

### `scripts/fix_pam_segfault_inplace.sh`

**Run when:** retrofitting an OLDER deployed node that ships the bad PAM
config.
**Modes:**

```bash
sudo bash scripts/fix_pam_segfault_inplace.sh --check   # diagnose only
sudo bash scripts/fix_pam_segfault_inplace.sh           # apply
```

**Mutates:** YES (when invoked without `--check`). Idempotent.
**Doc:** [`../deployment/PAM_HARDENING.md`](../deployment/PAM_HARDENING.md).

### `scripts/fix_login_script_rlibs_inplace.sh`

**Run when:** the deployed login script `/etc/profile.d/00_rstudio_user_logins.sh`
still writes `R_LIBS_USER` into users' `~/.Renviron` (health check section 6:
"Login script writes R_LIBS_USER"). Required before `ENABLE_R_LIBS_LOCAL=true`:
the copy in `~/.Renviron` is read after `Renviron.site` and overrides the
local-disk path, and it comes back after every Step 9 / cleanup run.
**Modes:**

```bash
sudo bash scripts/fix_login_script_rlibs_inplace.sh                 # dry-run: prints the diff
sudo bash scripts/fix_login_script_rlibs_inplace.sh --commit        # apply
sudo bash scripts/fix_login_script_rlibs_inplace.sh --rollback /root/login-script-hotfix-<ts>
```

**Mutates:** only with `--commit` / `--rollback`: the one `R_LIBS_USER` entry of
the deployed login script becomes a comment. Backup in `/root/login-script-hotfix-<ts>/`,
atomic swap, owner/mode kept, original mtime kept (the per-user `/tmp` stamps stay
valid, so nobody re-runs the login script because of it; `--rerun-logins` changes
that). No restart, no effect on running sessions. Refuses a file not rendered from
the template, and a login script whose `USER_PROJECTS_BASE_DIR` differs from
`NFS_HOME` (only then is R's default `~/R/...` library the same directory; `--force`
after checking). Users' existing `R_LIBS_USER` lines are not touched: with local
libs disabled they equal R's default; remove them with `50_setup_nodes.sh` option 4
after the hotfix, never before.
**Why not `20_configure_rstudio.sh` option 3:** options 1 and 3 run
`chown -R root:<group>` / `chmod -R g+rwx` on `R_PROJECTS_ROOT` (`/nfs/home`, every
user's home) — do not run them on a populated node until that is refactored.
The template carries the same change, so a later redeploy keeps the fix.
Tested by `tests/login_rlibs_hotfix_test.sh`.

---

## 6. Forensic launcher (not a 99_ script, but core to the toolbox)

### `r_minimal` / `r_minimal_rscript`

Deployed by `50_setup_nodes.sh` to `/usr/local/bin/`.

```bash
r_minimal                            # interactive R, /etc/R/Rprofile_minimal.R
r_minimal -e 'biome_diag()'          # one-shot
r_minimal_rscript user.R [args...]   # batch
```

**When to run:** L0/L1 of the HC-13 ladder. Proves whether a hang or
SIGSEGV reproduces under "pure R + minimal profile" — i.e. whether the
fix should land in the dispatcher / fragments (system) or in the user
script (only legitimate L5 verdict).

The minimal profile is `templates/Rprofile_site.minimal.R.template`
and intentionally does **not** source `/etc/R/Rprofile_site.d/`.

---

## 7. Tools (`scripts/tools/`) — auxiliary utilities

These are not `99_*` diagnostics but are essential for day-2 operations.
All are read-only unless noted.

### `scripts/tools/hw_report.sh`

**Run when:** onboarding a new node; quarterly hardware audit; after
Proxmox VM resize.
**Mutates:** no.
**What it reports:** CPU model/cores/sockets, RAM total, disk layout
(`lsblk`), NUMA topology, `/Rtmp` filesystem type and size, network
interfaces.
**Output:** color-coded text report to stdout.
**Next step:** compare against other nodes; flag discrepancies for the
VM host admin.

### `scripts/tools/deployment_summary.sh`

**Run when:** after a full `init.sh` run; quarterly audit; before
handing a node to researchers.
**Mutates:** no.
**What it reports:** R version, RStudio Server version, BLAS variant,
Rprofile version, AD join status, cgroup v2 presence, NFS mounts,
`/Rtmp` size, SSL cert expiry, running BIOME services.
**Output:** structured text summary with PASS/WARN/FAIL per check.
**Next step on FAIL:** cross-reference [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md).

### `scripts/tools/manage_r_sessions.sh`

**Run when:** a user has orphaned rsession processes; before
maintenance reboots; when `/Rtmp` is full from stale sessions.
**Mutates:** YES (in `--kill-orphans` mode). Read-only otherwise.
**Modes:**

```bash
sudo bash manage_r_sessions.sh                      # list all active sessions
sudo bash manage_r_sessions.sh --user <username>    # filter by user
sudo bash manage_r_sessions.sh --kill-orphans       # kill orphaned rsessions
```

**Output:** table of active sessions (PID, user, CPU%, MEM%, runtime);
orphan classification.
**Next step on orphan flood:** investigate why RStudio session cleanup
failed; check `rstudio-server` health.

### `scripts/tools/check_processor_threads.sh`

**Run when:** user reports `detectCores()` returns unexpected value;
after cgroup config change; when benchmarking parallel performance.
**Mutates:** no.
**What it checks:** physical cores, logical threads, cgroup-effective
cores (`/sys/fs/cgroup/cpu.max`), `nproc` soft limit, R's
`parallel::detectCores()` output under the BIOME profile.
**Output:** comparison table of each core-count source.
**Next step on mismatch:** verify `user-.slice.d/50-biome-limits.conf`
and re-run `50_setup_nodes.sh`.

### `scripts/tools/bigger_usage_reports.sh`

**Run when:** quarterly capacity planning; investigating `/Rtmp` growth;
before expanding storage.
**Mutates:** no.
**What it reports:** per-user `/Rtmp` usage (top 20), per-user home-dir
usage, total `/Rtmp` age distribution, largest file listing.
**Output:** text report.
**Next step on high usage:** notify top consumers; run orphan cleanup;
consider per-user quotas.

### `scripts/tools/check_installed_R_Package.sh`

**Run when:** verifying a package install across nodes; after
`r_env_manager.sh` package batch; when a user says "package X is
missing".
**Mutates:** no.
**Wraps:** `scripts/tools/check_installed_R_Package.R`.
**Usage:** `sudo bash check_installed_R_Package.sh <pkg-name>`
**Output:** installed version, library path, loaded-from path.
**Next step if missing:** add to `config/r_env_manager.conf` and re-run
`r_env_manager.sh`.

### `scripts/tools/check_pkg_config.sh`

**Run when:** troubleshooting R package compilation failures (missing
system libs); after OS upgrade; when `install.packages()` fails with
"configuration failed".
**Mutates:** no.
**What it checks:** system library presence for common R package
dependencies: `libgdal`, `libproj`, `libgeos`, `libudunits2`, `libgsl`,
`libharfbuzz`, `libfribidi`, `libmysqlclient`, `libpq`, `libsodium`,
`libsecret`, `libsasl2`, `libcurl`, `libxml2`, `libssl`, `libfontconfig`.
**Output:** installed/not-installed per library.
**Next step on missing:** `apt-get install` the missing `-dev` package.

### `scripts/tools/r_pkg_drift_detector.R`  *(R script)*

**Run when:** wrapped by `scripts/99_check_pkg_drift.sh`; directly for
interactive investigation.
**Mutates:** no (unless `--update-baseline`).
**What it does:** compares installed R packages against a sysadmin-owned
baseline (`/var/lib/biome-calc/pkg_baseline.rds`). Classifies drift by
severity: HIGH (base/recommended packages), MEDIUM (CRAN packages in
`r_env_manager.conf`), LOW (user-installed packages).
**Output:** JSON report with per-package diff.
**Next step:** see `99_check_pkg_drift.sh` entry in §1.

---

## 8. Where each script logs

| Script | Log location |
|---|---|
| All numbered phase scripts | `/var/log/biome-log/core/<script>.log` |
| `99_postmortem_forensics.sh` | `--output` arg or `/tmp/postmortem_<user>_<TS>.txt` |
| `99_diagnose_lussu_hang.sh` | `/tmp/lussu_diag_<user>_<TS>/` (generic `report.md` lands here too) |
| `99_diagnose_user_script.sh` | `/tmp/user_diag_<user>_<TS>/` (override: `BIOME_DIAG_OUT_DIR`) |
| `99_check_pkg_drift.sh` | `${BIOME_CONF}/pkg_drift/baseline.csv` + stdout |
| `99_audit_r_environment.sh` | `${BIOME_CONF}/audit/` |
| `99_health_check.sh` | stdout (intended for cron + email) |
| `99_check_rprofile_health.sh` | stdout (operator captures) |
| `99_troubleshoot_env.sh` | stdout (operator captures) |
| `13_harden_pam_password.sh` / `fix_pam_segfault_inplace.sh` | `/var/log/biome-log/core/` |
| RStudio | `/var/log/rstudio-server/` |
| Nginx | `/var/log/nginx/{access,error}.log` |
| ttyd wrapper | `/var/log/secure_access/` |
| Telemetry | `journalctl -u botanical-telemetry` |
| SSSD | `journalctl -u sssd` + `/var/log/sssd/` |
| Samba | `journalctl -u smbd -u winbind` + `/var/log/samba/` |

→ Full inventory of log paths: [`diagnostic_logs.md`](diagnostic_logs.md).

---

## 9. Nginx / auth_pam package drift

### Node comparison for nginx auth_pam regression

**Run when:** nginx worker segfaults on portal login; `[alert] worker
process exited on signal 11` in nginx error log; kernel segfaults in
`ngx_http_auth_pam_module.so`.

**Mutates:** no.

**What it checks:** nginx package versions, auth_pam module version,
PAM stack identity, Winbind health, privileged pipe access, domain
trust.

**Commands (run on BOTH failed and working nodes):**

```bash
hostname
dpkg -l | grep -E 'nginx|auth-pam|samba|winbind|libpam-winbind|libnss-winbind|pam-runtime|libpam0g'
systemctl status nginx winbind smbd nmbd --no-pager -l
id www-data
getent group winbindd_priv
ls -ld /var/lib/samba/winbindd_privileged
ls -l /var/lib/samba/winbindd_privileged/pipe
wbinfo -t
wbinfo -P
grep -Hn 'pam_winbind\|pam_unix\|pam_deny\|pam_permit\|pam_lastlog' /etc/pam.d/common-auth /etc/pam.d/common-account /etc/pam.d/common-session /etc/pam.d/common-session-noninteractive /etc/pam.d/nginx
```

**Known-bad state:** nginx `1.24.0-2ubuntu7.10` with
`libnginx-mod-http-auth-pam 1:1.5.5-2build2`.

**Next step:** [`NGINX_AUTH_PAM_REGRESSION_2026-06.md`](NGINX_AUTH_PAM_REGRESSION_2026-06.md).

---

## 10. Decision tree (TL;DR)

```
Did the user say "it crashed" / "it broke"?
  └─► 99_postmortem_forensics.sh --user <them>

Does a specific .R reproducibly fail?
  ├─► Generic:  99_diagnose_user_script.sh   (run as the user)
  │     ├─► L3s PASS + L3 FAIL = the user's ~/.Renviron / ~/.Rprofile
  │     │     → 99_check_rprofile_health.sh --user <them> --fix
  │     ├─► add --smoke to actually execute a shrunk run (L0b)
  │     ├─► exit 4 = infra green, user code has HIGH lint findings
  │     │     → hand researcher PARALLEL_R_DOS_AND_DONTS.md anchors
  │     └─► report.md ends with old_vs_new cgroup appendix
  └─► Lussu-style: 99_diagnose_lussu_hang.sh (forwards --smoke / exit 4)

Does `passwd` segfault?
  └─► fix_pam_segfault_inplace.sh --check

Are nodes diverging on R packages?
  └─► 99_check_pkg_drift.sh

Is the system "weird" but you can't pinpoint it?
  └─► 99_troubleshoot_env.sh --rprofile

Welcome banner missing / guards inactive / Rprofile parse error?
  └─► 99_check_rprofile_health.sh
        ├─► CRIT on dispatcher → redeploy: 50_setup_nodes.sh (option 3)
        ├─► FAIL on fragments  → redeploy: 50_setup_nodes.sh (option 3)
        ├─► FAIL on bundle     → redeploy: 50_setup_nodes.sh (option 3)
        ├─► FAIL on guards     → check fragment 45_memory_guards.R
        ├─► CRIT on BLAS       → apt-get remove pthread, install serial
        └─► FAIL/WARN in section 7 (--user) → --fix (plan) → --fix --commit,
              or --reset-profile --commit (reversible: --undo-reset)

Routine pre-deploy / post-deploy gate?
  └─► 99_health_check.sh + 99_check_rprofile_health.sh + 99_audit_r_environment.sh
```
