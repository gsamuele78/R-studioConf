<!-- docs/operations/DIAGNOSTICS_INDEX.md -->
# Diagnostics Index — `99_*.sh` and `fix_*.sh` Toolbox

> **Audience:** sysadmins / on-call.  
> **Tier:** T1 host.  
> **Last updated:** 2026-05-09.

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

### `scripts/99_diagnose_user_script.sh`  *(generic harness)*

**Run when:** a user reports their `.R` script reproducibly fails on
this server.
**Mutates:** no — **never** modifies the user's `.R`.
**What it does:** L0..L4 escalation:

* **L0:** `r_minimal_rscript` — pure R, no Rprofile.
* **L1:** R with `Rprofile_minimal.R` — minimal forensic profile.
* **L2:** R with full dispatcher BUT `.d/` fragments off.
* **L3:** R with full dispatcher + all fragments.
* **L4:** RStudio session emulation.

**Output:** verdict L0..L5. Only L5 means "the user script is the bug".
Anything else means a SYSTEM patch lands somewhere in
`Renviron.template`, the dispatcher, or a specific fragment.

→ Full method: [`USER_SCRIPT_TROUBLESHOOTING.md`](USER_SCRIPT_TROUBLESHOOTING.md).

### `scripts/99_diagnose_lussu_hang.sh`  *(Lussu-specific overlay)*

**Run when:** the user is "Lussu" or the symptom matches: long
`mclapply` over `terra::rast` stalls forever.
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

## 7. Where each script logs

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

## 8. Decision tree (TL;DR)

```
Did the user say "it crashed" / "it broke"?
  └─► 99_postmortem_forensics.sh --user <them>

Does a specific .R reproducibly fail?
  ├─► Generic:  99_diagnose_user_script.sh
  └─► Lussu-style: 99_diagnose_lussu_hang.sh

Does `passwd` segfault?
  └─► fix_pam_segfault_inplace.sh --check

Are nodes diverging on R packages?
  └─► 99_check_pkg_drift.sh

Is the system "weird" but you can't pinpoint it?
  └─► 99_troubleshoot_env.sh --rprofile

Routine pre-deploy / post-deploy gate?
  └─► 99_health_check.sh + 99_audit_r_environment.sh
```
