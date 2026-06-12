<!-- docs/operations/DIAGNOSTICS_INDEX.md -->
# Diagnostics Index — `99_*.sh` and `fix_*.sh` Toolbox

> **Audience:** sysadmins / on-call.  
> **Tier:** T1 host.  
> **Last updated:** 2026-06-12.

Every diagnostic and one-shot fix script in `scripts/` mapped to:
**when to run / what it produces / where logs land / what to do next.**
Cross-linked from [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md).

> **Pessimistic-engineering rule.** None of these scripts mutate state
> by default unless explicitly named `fix_*` or invoked with a
> destructive flag. They are safe on production hosts.

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
**Mutates:** no.
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

### `scripts/99_diagnose_user_script.sh`  *(generic harness, v1.3)*

**Run when:** a user reports their `.R` script reproducibly fails on
this server.
**Mutates:** no — **never** modifies the user's `.R` (HC-13).
**What it does:** L0..L4 infrastructure ladder + L0a/L0b user-code layer:

* **L0:** `r_minimal_rscript` — pure R, no Rprofile.
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
* **L1:** R with `Rprofile_minimal.R` — minimal forensic profile.
* **L2:** R with full dispatcher BUT `.d/` fragments off.
* **L3:** R with full dispatcher + all fragments.
* **L4:** RStudio session emulation.

**Output:** verdict L0..L5 + per-layer summary table in `report.md` +
**`old_vs_new` appendix** (NEW v1.3) reading `/sys/fs/cgroup/$cgroup/{memory.max,
memory.current,cpu.max}` and contrasting actual cgroup limits against
the legacy "16 vCPU / 512 GB / 2 TB no-cgroup" VM — counters the
"sul vecchio server funzionava" deflection with hard numbers.

**Exit codes:**

* `0` — ALL LAYERS PASSED.
* `3` — PROGRESSING-only (some layer hit timeout but none failed).
* `4` (NEW v1.3) — **INFRASTRUCTURE GREEN — user code has HIGH-severity
  lint finding(s).** L1/L3 pass, but L0a flagged HIGH issues. The
  research script is the bug; share `report.md` and the user-guide
  anchors with the researcher.
* `1` — actual failure somewhere in L0..L4.

Lint rule catalogue and good-vs-bad worked examples:
[`../user_guides/PARALLEL_R_DOS_AND_DONTS.md`](../user_guides/PARALLEL_R_DOS_AND_DONTS.md).

→ Full method: [`USER_SCRIPT_TROUBLESHOOTING.md`](USER_SCRIPT_TROUBLESHOOTING.md).

### `scripts/99_diagnose_lussu_hang.sh`  *(Lussu-specific overlay, v1.5)*

**Run when:** the user is "Lussu" or the symptom matches: long
`mclapply` over `terra::rast` stalls forever.
**Forwards** `--no-lint` / `--smoke` flags and exit code `4` to/from
the generic harness (v1.5).
**Adds two probes** to the generic harness, both UNINTRUSIVE:

* **(E)** PSOCK swap — same code, but `mclapply → parLapply` on a
  PSOCK cluster. Done in a sibling `.R` that `source()`s the user file
  via `local()` shim. The user's file is untouched.
* **(F)** terra todisk — preloads `terraOptions(todisk=TRUE,memfrac=0.2)`
  before sourcing.

**Output:** which probe makes the hang go away → tells you whether the
fix lands in `Rprofile_site.d/30_psock_factory.R.template` or
`35_compile_routing.R.template`.

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
| `99_diagnose_lussu_hang.sh` | `/tmp/lussu_diag_<TS>/` |
| `99_diagnose_user_script.sh` | `/tmp/user_script_diag_<user>_<TS>/` |
| `99_check_pkg_drift.sh` | `${BIOME_CONF}/pkg_drift/baseline.csv` + stdout |
| `99_audit_r_environment.sh` | `${BIOME_CONF}/audit/` |
| `99_health_check.sh` | stdout (intended for cron + email) |
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
  ├─► Generic:  99_diagnose_user_script.sh
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

Routine pre-deploy / post-deploy gate?
  └─► 99_health_check.sh + 99_audit_r_environment.sh
```
