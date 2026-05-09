<!-- docs/operations/OPERATOR_QUICKSTART.md -->
# Operator Quickstart — Day-to-Day Sysadmin Runbook (HC-13)

**Audience:** the on-call sysadmin / IT officer.
**Status:** normative. One-page summary of *what to actually do* now that
HC-13 (Adapt System, Not User Script) is encoded in the project.
**Last updated:** 2026-05-09.

---

## Responsibility Boundaries (HC-13 — read first, every time)

> *We adapt system → profile → fragments → env so that portable user R code
> keeps working. **We do not patch user scripts.** When the system has been
> exhausted and the failure persists, the clean-VM baseline (L4) proves
> whether the residual issue is in the user's code or upstream.*

> **You do NOT customise the deployment per user script. You deploy the
> node profile ONCE. You only run the diagnostic harness when there is
> an incident ticket. When triage finds a system-side cause, the fix
> lands in the system (fragment / Renviron / mount / cap) — never in the
> user's `.R` file.**

If you ever feel tempted to edit a researcher's `.R`, stop and re-read
the ordering invariant in `.ai/agents.md` §6.6.

---

## TL;DR

| Question | Answer |
|---|---|
| Do I customise scripts per user? | **No.** Per HC-13, never. |
| Do I redeploy `50_setup_nodes.sh` for every new user script? | **No.** Deploy once per node. |
| When do I run the diagnostic harness? | **Only on an incident ticket** ("my script hangs/crashes"). |
| Where do fixes land? | In the **system** — Renviron, fragment, mount opt, cgroup. The user re-runs unchanged code. |
| What if the system is innocent? | Escalate to L4 clean-VM, then L5 (user/upstream) **with evidence**. |

---

## One-Time Deployment (per BIOME-CALC node)

Run on each compute node, once, as root:

```bash
cd /home/jfs/00_Antigravity_workspace/R-studioConf
sudo bash scripts/50_setup_nodes.sh
# Pick option H (HC-13 tools) — or run the full deploy, which now includes H.
```

Verify:

```bash
ls -l /etc/R/Rprofile_minimal.R                       # bare-bones forensic profile
ls -l /usr/local/bin/r_minimal /usr/local/bin/r_minimal_rscript
ls -l /usr/local/bin/99_diagnose_user_script.sh
ls -l /usr/local/bin/99_diagnose_lussu_hang.sh
r_minimal -e 'biome_diag()'                           # smoke-test
```

| Path on node | Role |
|---|---|
| `/etc/R/Rprofile.site` | full production profile (`Rprofile_site.R` + `Rprofile_site.d/*`) |
| `/etc/R/Rprofile_minimal.R` | minimal HC-13 forensic profile (L0/L1) |
| `/etc/R/Renviron.site` | thread/BLAS caps, GDAL/POLARS, `TMPDIR=/Rtmp` |
| `/Rtmp` | 400 GB ext4 — large R temp |
| `/usr/local/bin/r_minimal` | runs `R` with `R_PROFILE_USER=Rprofile_minimal.R --no-site-file` |
| `/usr/local/bin/r_minimal_rscript` | same, for `Rscript` |
| `/usr/local/bin/99_diagnose_user_script.sh` | generic L0..L3 harness |
| `/usr/local/bin/99_diagnose_lussu_hang.sh` | Lussu pattern overlay (probes E/F) |

After this, you do **not** redeploy unless a fragment changes.

---

## The Three Day-to-Day Modes

### Mode A — Happy path (95% of days)

Researcher runs their `.R` against the production profile (`Rscript user.R`
inside RStudio). It works. **You do nothing.** No per-script step.

### Mode B — Incident ticket: "my script hangs / crashes"

```bash
# 1. Run the generic harness against the user's UNMODIFIED .R
sudo /usr/local/bin/99_diagnose_user_script.sh /path/to/user.R

# 2. Read the verdict
less /tmp/user_diag_<ts>/report.md          # ends with: LAYER X FAILED: <reason>
```

Map the verdict to action via the table in
`docs/operations/USER_SCRIPT_TROUBLESHOOTING.md` ("Verdict → action mapping").
The fix lands **system-side**:

| Verdict | Where the fix lands |
|---|---|
| `L0 FAILED` (infra) | NFS mount opts, kernel/cgroup, BLAS pkg → re-run `50_setup_nodes.sh` for the affected step |
| `L3 FAILED but L2 (fragments-off) PASSED` | a fragment in `templates/Rprofile_site.d/` → patch + redeploy that fragment |
| `L1+L3 FAILED, L2 PASSED` | dispatcher core in `templates/Rprofile_site.R.template` |
| `L1+L3 BOTH FAILED` | escalate to L4 (`CLEAN_VM_BASELINE.md`) |
| `ALL PASSED` | ask user for exact reproduction (inputs/args/env/exit code) |

Then the user **re-runs their unchanged `.R`** and the ticket closes. No
script edit was suggested.

### Mode C — Pattern-specific overlay (when a known anti-pattern is suspected)

Some failure shapes are recurrent enough to have a dedicated overlay that
runs additional probes (PSOCK swap, `terraOptions(todisk=TRUE)`, …)
against the **same unmodified** user script:

```bash
sudo /usr/local/bin/99_diagnose_lussu_hang.sh /path/to/user.R
# probe E = PSOCK swap of mclapply
# probe F = terra todisk
# all probes leave the user's .R untouched (LD_PRELOAD / R_PROFILE_USER shims only)
```

If probe E or F passes, the system-side fix is to default that behaviour
in a fragment (`50_pkg_hooks.R.template` for terra; documented PSOCK
launcher for fork+NFS) — never to ask the researcher to rewrite their code.

---

## Worked Example — Martina's NIMBLE Parallel Chains

**Ticket shape:** "NIMBLE MCMC with N parallel chains hangs / OOMs / crashes
mid-run."

**Step 0 — do NOT touch the script.** Run the generic harness:

```bash
sudo /usr/local/bin/99_diagnose_user_script.sh /home/martina/run_chains.R
```

While it runs, the likely surfaces map to **existing** system knobs:

| Likely surface | Where in the system it is already controlled |
|---|---|
| NIMBLE C++ compilation needs lots of temp space | `Renviron.template` sets `TMPDIR=/Rtmp` (400 GB ext4); not `/tmp` |
| User doesn't `setwd()` to a writable dir before MCMC | `templates/Rprofile_site.d/60_safe_setwd.R.template` enforces a fallback |
| BLAS threads × N chains overload CPU/RAM | `templates/Rprofile_site.d/05_thread_guard.R.template` caps `OMP_NUM_THREADS=1`, `OPENBLAS_NUM_THREADS=1`; OpenBLAS-serial is the installed BLAS (HC-§6.1) |
| Per-chain memory guards (large posterior samples) | `templates/Rprofile_site.d/45_memory_guards.R.template` caps `future.globals.maxSize`, ulimits, `R_MAX_VSIZE` |
| `parallel::detectCores()` returns hyperthreads → too many chains | `45_memory_guards` / NIMBLE conventions: use `parallel::detectCores(logical=FALSE)` (HC-§6.5) |
| Forked workers + NFS lock contention | overlay probe E (`99_diagnose_lussu_hang.sh`) — PSOCK swap |

**If verdict says `L3 FAILED but L2 (fragments-off) PASSED`:**
Bisect with `BIOME_DISABLE_FRAGMENTS="45"` then `"05"` then `"50"`, etc.
The guilty fragment gets patched in `templates/Rprofile_site.d/`,
redeployed via `50_setup_nodes.sh`, and Martina re-runs her **unchanged**
script.

**If verdict says `ALL PASSED` but Martina still reports an issue:**
Ask her for exact inputs (seed, N chains, iterations, model file) so the
harness can reproduce. *Then* — only if L0+L1+L2+L3+L4 all clear — is a
user-script suggestion admissible per the HC-13 ordering invariant, and
**only with cited evidence** (`.ai/agents.md` §6.6).

---

## What you write back to the user

Templates from `USER_SCRIPT_TROUBLESHOOTING.md`:

- **System-side fix landed (L0..L3):**
  *"Your script ran into a system-level issue (`<short reason>`). We have
  adapted the system. Please re-run; no changes to your code are needed."*

- **Clean-VM reproduces (L4):**
  *"We reproduced your failure on a clean reference VM. Minimal reproducer
  attached, kernel stack attached. Could you confirm and consider an
  upstream report?"*

- **User-script bug with evidence (L5):**
  *"Reproduces in isolation against `<pkg>@<ver>` on stock R. We propose
  `<patch>` for **your** review — we will not change your file without
  your OK."*

You **never** prescribe a code change at L0..L3.

---

## Quick command reference

```bash
# system smoke-test (no user script)
r_minimal -e 'biome_diag(); biome_nfs_check(); biome_fork_probe()'

# attach to a hanging session
pgrep -f 'user.R' | head
r_minimal -e 'biome_hang_diag(c(<pid1>,<pid2>))'
r_minimal -e 'biome_worker_tail()'

# generic harness on a ticket
sudo /usr/local/bin/99_diagnose_user_script.sh /path/to/user.R

# pattern overlay (mclapply + terra + NFS)
sudo /usr/local/bin/99_diagnose_lussu_hang.sh /path/to/user.R

# binary bisection of fragments by hand
BIOME_DISABLE_FRAGMENTS="45,50" Rscript /path/to/user.R

# package drift (surface 6)
Rscript scripts/tools/r_pkg_drift_detector.R
```

---

## See also

- `docs/operations/USER_SCRIPT_TROUBLESHOOTING.md` — full decision tree, verdict→action mapping, forensic helpers.
- `docs/operations/LUSSU_HANG_BISECTION.md` — worked example (mclapply + terra + NFS).
- `docs/operations/CLEAN_VM_BASELINE.md` — L4 reference VM SOP.
- `docs/architecture/USER_CONTRACT.md` — what "portable R" means at the input boundary.
- `.ai/agents.md` §6.6 — HC-13 architectural rule + ordering invariant.
