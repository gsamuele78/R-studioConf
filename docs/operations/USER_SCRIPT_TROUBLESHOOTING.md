<!-- docs/operations/USER_SCRIPT_TROUBLESHOOTING.md -->
# User-Script Troubleshooting — HC-13 Generic Decision Tree

**Audience:** sysadmin / IT officer on call.
**Status:** normative. This is the operator-facing entry point for *any*
hang, crash, or "my R script doesn't work" ticket from a BIOME researcher.

---

## Responsibility Boundaries (HC-13 — read first, every time)

> *We adapt system → profile → fragments → env so that portable user R code
> keeps working. **We do not patch user scripts.** When the system has been
> exhausted and the failure persists, the clean-VM baseline (L4) proves
> whether the residual issue is in the user's code or upstream.*

| Surface | May the sysadmin change it without asking the user? |
|---------|------------------------------------------------------|
| `Renviron.site`, `Rprofile_site` dispatcher, fragments under `Rprofile_site.d/` | **YES** |
| BLAS/OMP/GDAL/POLARS/torch caps in `05_thread_guard`, `50_pkg_hooks` | **YES** |
| NFS mount options, kernel/cgroup limits, `/Rtmp` size | **YES** |
| Profile bundle (add/remove a fragment, raise a default) | **YES** |
| **The user's `.R` file** | **NO — never, without explicit consent in the same prompt** |

An AI-generated patch that silently rewrites a user-supplied `.R` is
**INVALID per HC-13** and must be rejected on review.

### Ordering invariant — when may a user-script edit be suggested?

A user-script modification suggestion is admissible **only after** triage
has positively excluded **all three** surfaces below, **in this order**:

1. **System bug** — L0 cleared (OS / NFS / fork / cgroup / kernel / BLAS).
2. **Configuration bug** — L1 + L2 + L3 cleared (Renviron, fragments, dispatcher).
3. **Unchecked case** — L4 clean-VM reproduces the failure with no NFS /
   no domain / no profile, AND a ≤30-line minimal reproducer with
   `sessionInfo()` + kernel-stack evidence has been captured.

Skipping any of (1), (2), (3) before proposing that the user edit their
`.R` is an HC-13 violation. Any user-facing suggestion to change `.R`
**must cite** the layer it cleared, e.g.
`"L4 PASS, evidence at /tmp/L4_clean_vm_<TS>/"`. The verdict line emitted
by `99_diagnose_user_script.sh` is the auditable proof that the ordering
was followed.

---

## The escalation ladder (run top-down, stop at first PASS)

| Layer | Probe | Tool | If PASS → | If FAIL → |
|-------|-------|------|-----------|-----------|
| **L0** | OS / NFS / fork health (no user script) | `r_minimal -e 'biome_diag(); biome_nfs_check(); biome_fork_probe()'` | infra healthy → continue to L1 | fix infra (NFS opts, kernel, cgroup); user blameless |
| **L1** | User script under **pure R** (minimal profile, no fragments) | `r_minimal_rscript user.R` | profile dispatcher or a fragment is the cause → L2 | infra-vs-script — continue all layers, then L4 |
| **L2** | User script with **all fragments disabled** | `BIOME_DISABLE_FRAGMENTS="20,30,35,40,45,50,55,60,70,80" Rscript user.R` | a fragment is guilty — bisect | the dispatcher core or non-fragment code is guilty |
| **L3** | User script under **full production profile** | `Rscript user.R` | reference baseline | reference baseline — compare to L1/L2 |
| **L4** | User script on **clean VM** (1 disk, no NFS, no domain, no profile) | see `CLEAN_VM_BASELINE.md` | issue is production-VM-specific (NFS / cgroup / fragment) | L5 |
| **L5** | User-script bug or upstream package bug | report to user **with kernel-stack evidence** | n/a | document; do not silently patch |

The full harness `scripts/99_diagnose_user_script.sh` runs L0..L3 in one
pass and writes a verdict line to `/tmp/user_diag_<ts>/report.md`.

---

## The 6-surface failure-pattern catalog

When triaging, the failing layer maps to one of six surfaces. This table
is the cheat-sheet for "what do I look at next?".

| # | Surface | Symptoms | Where to look | System-side fix lands in |
|---|---------|----------|---------------|--------------------------|
| 1 | **Env / Renviron** | hang/crash even under `r_minimal` (L0 or L1 fail without fragments); BLAS sigsegv; QEMU SIGILL | `Renviron.site`, `/etc/profile.d/biome-coretype.sh`, `Sys.getenv()` in `biome_diag()` | `templates/Renviron.template`, `templates/biome-coretype.sh` |
| 2 | **Rprofile fragment** | L1 PASS, L2 PASS, L3 FAIL → bisect via `BIOME_DISABLE_FRAGMENTS` | `templates/Rprofile_site.d/*.R.template` | the offending fragment |
| 3 | **Fork + NFS / terra** | L0 fork-probe PASS but user script using `mclapply` + `terra::rast` on NFS hangs; PSOCK swap (probe E) makes it pass | `biome_nfs_check()`, `lsof -p <child>`, `cat /proc/<child>/wchan` | `50_pkg_hooks.R.template` (default `terraOptions(todisk=TRUE)`); NFS mount opts; documented PSOCK launcher |
| 4 | **BLAS / threads** | SIGSEGV inside `Rblas.so`; CPU saturated by `n_workers × threads` even when user set 1 worker | `sessionInfo()$BLAS`, `OPENBLAS_*`, `OMP_*`, `MKL_*` | `Renviron.site`, `05_thread_guard`, ensure `libopenblas0-serial` (NOT pthread) |
| 5 | **Cgroup / kernel** | SIGKILL (137); OOM under load; `detectCores()` returns wrong number | `/sys/fs/cgroup/memory.max`, `cpu.max`, `dmesg`, `oom_score` | systemd unit limits, compose `deploy.resources.limits` (HC-01) |
| 6 | **Package drift** | works on one VM, fails on another; user installed a newer CRAN version into `R_LIBS_USER` | `installed.packages()`, `R_LIBS_USER`, `scripts/tools/r_pkg_drift_detector.R` | rebuild image with pinned versions; document `BIOME_DISABLE_USER_LIBS=1` |

---

## Verdict → action mapping (from the harness)

| Verdict line | Surface | Action |
|--------------|---------|--------|
| `LAYER L0 FAILED: infra (NFS/fork/cgroup)` | 1, 5 | Fix infrastructure. User blameless. |
| `ALL LAYERS PASSED: script is healthy in production` | — | Ask user for exact reproduction (inputs, args, env, exit code). |
| `LAYER L3 FAILED but L2 (fragments-off) PASSED: a profile fragment is the cause` | 2 | Manual bisection: `BIOME_DISABLE_FRAGMENTS="50"` then 45, 40, … until pass. Patch that fragment. |
| `LAYER L3 FAILED, L1 PASSED, L2 FAILED: dispatcher itself or fragment-load contract` | 2 | Inspect dispatcher `local({})` in `templates/Rprofile_site.R.template`. The bug survives "all fragments off" → it lives in the dispatcher core. |
| `LAYERS L1+L3 BOTH FAILED: NOT a profile issue → infra+terra+NFS or user-script bug` | 3, 4, 5, 6 | Escalate to L4 (`CLEAN_VM_BASELINE.md`). If L4 also fails → L5. |
| `L2 FAILED but L1+L3 PASSED: spurious — investigate run-to-run variance` | 3 (often) | Re-run with doubled timeout. Check for transient NFS contention with `biome_nfs_check()` during the failing minute. |

---

## Tooling on the host (deployed by `scripts/50_setup_nodes.sh`)

| Path | Role |
|------|------|
| `/etc/R/Rprofile_minimal.R` | bare-bones forensic profile (HC-13 L0/L1) |
| `/usr/local/bin/r_minimal` | launches `R` with `R_PROFILE_USER=/etc/R/Rprofile_minimal.R --no-site-file` |
| `/usr/local/bin/r_minimal_rscript` | same, but for `Rscript` |
| `/usr/local/bin/99_diagnose_user_script.sh` | generic L0..L3 harness |
| `/usr/local/bin/99_diagnose_lussu_hang.sh` | Lussu-flavored overlay (probes E, F) |
| `scripts/99_postmortem_forensics.sh` | crash-data collection (post-mortem) |
| `scripts/tools/r_pkg_drift_detector.R` | surface-6 drift diagnostic |

---

## Forensic helpers exposed by `r_minimal`

All are pure-R, no dependencies, exported to `.GlobalEnv`:

| Helper | Purpose |
|--------|---------|
| `biome_diag()` | one-page system summary (R, BLAS, env, cgroup, /Rtmp) |
| `biome_nfs_check()` | NFS mounts + flagged options (soft, actimeo=0, rsize<64K) |
| `biome_fork_probe(n=10)` | baseline `mclapply` fork health (~30 s) |
| `biome_terra_probe(path)` | open + read-first-tile of a raster (timing) |
| `biome_hang_diag(pids)` | `/proc/<pid>/{status,wchan,stack,syscall,cmdline}` + `ps` |
| `biome_worker_tail(pids, n=40)` | tail per-worker `/tmp/biome_worker_*.log` |

When a user script hangs:

```bash
# Terminal A — start the script under r_minimal so we know there's no profile noise
r_minimal_rscript /path/to/user.R

# Terminal B — wait until you see workers, then attach diagnostically
pgrep -f 'user.R' | head
r_minimal -e 'biome_hang_diag(c(12345, 12346))'
r_minimal -e 'biome_worker_tail()'
```

---

## What the sysadmin writes back to the user

Per HC-13 the user-facing message **never** prescribes a code change unless
L4 or L5 was reached and there is concrete evidence (kernel stack, package
drift hash, upstream bug ID). Templates:

**Verdict L0..L3 (system-side fix landed):**

> Your script ran into a system-level issue on our cluster (`<short reason>`).
> We have adapted the system (`<fragment X / mount Y / cap Z>`) and the
> script now completes against your unchanged `.R` file. Please re-run; no
> changes to your code are needed.

**Verdict L4 (clean-VM baseline reproduces):**

> We were able to reproduce your script's failure on a clean reference VM
> with no NFS / profile / domain. The minimal reproducer points to
> `<upstream pkg / specific call>`. Attached: kernel stack and package
> versions. Could you confirm the call and consider an upstream report?

**Verdict L5 (user-script bug, with evidence):**

> The script reproduces in isolation against `<package>@<version>` on
> stock R. Attached: minimal reproducer (≤30 lines), `sessionInfo()`,
> kernel stack from `biome_hang_diag()`. We propose `<patch suggestion>`
> for **your** review — we will not change your file without your OK.

---

## See also

- `docs/operations/LUSSU_HANG_BISECTION.md` — concrete worked example.
- `docs/operations/CLEAN_VM_BASELINE.md` — L4 reference VM SOP.
- `docs/architecture/USER_CONTRACT.md` — what "portable R" means at the
  input boundary; why the system absorbs the ugliness.
- `.ai/agents.md` §6.6 — HC-13 architectural rule.
