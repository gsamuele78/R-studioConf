# Rprofile_site.R — CHANGELOG

Historical changelog for `templates/Rprofile_site.R.template`. Extracted from
the monolithic header during the v12.1 modularization (2026-04-25).

See `templates/Rprofile_site.R.template` header for the current architecture,
and `templates/Rprofile_site.d/` for feature fragments.

---

## v12.10-doc (2026-06-05) — "RStudioGD plot-pane diagnostics + runbook"

### Trigger

A researcher on biome-calc01 reported that plots were no longer appearing
in the RStudio Server Plots pane. Commands like `plot(1,1)` and
`print(my_ggplot)` executed without errors but produced no visible output
in the browser. The stress-test and diagnostic scripts
(`99_botanical_plot_stress_test.R`, `99_diagnose_rstudio_plot_pane.R`)
confirmed the session was healthy except for one finding: `options("device")`
was a function that did **not** mention `RStudioGD`.

### Investigation

Tracing through the deployed host files vs. the GitHub template revealed
the root cause:

* **Deployed `/etc/R/Rprofile_site.d/50_pkg_hooks.R`** (stale, pre-v12.2):

  ```r
  if (has_ragg) options(device = ragg::agg_png)
  ```

  This fires **unconditionally** and replaces `RStudioGD` with
  `ragg::agg_png` — a file-writing device. All plots then write to
  `/Rtmp/*.png` files instead of being streamed over the WebSocket to
  the browser.

* **GitHub `templates/Rprofile_site.d/50_pkg_hooks.R.template`** (current, v12.2+):

  ```r
  is_interactive_rstudio <- interactive() &&
    (nzchar(Sys.getenv("RSTUDIO", "")) ||
     nzchar(Sys.getenv("RSTUDIO_USER_IDENTITY", "")))
  if (has_ragg && !is_interactive_rstudio) options(device = ragg::agg_png)
  ```

  This correctly guards against overwriting `RStudioGD` in interactive
  RStudio Server sessions while still setting `ragg::agg_png` as the
  default for headless/Rscript contexts (where file output is correct).

**Conclusion:** The GitHub template is correct. The production node was
running a stale deploy. The durable fix is redeploying via
`scripts/50_setup_nodes.sh` → option 3 (Config files only).

### Fix (T1 authoritative)

No change to Rprofile fragments. The fragment semantics are unchanged.

**1. Hardened `scripts/99_diagnose_rstudio_plot_pane.R` (TEST 2).**
The diagnostic now:

* Detects whether the session is interactive RStudio via `RSTUDIO` /
  `RSTUDIO_USER_IDENTITY` env vars.
* Classifies 12 file-writing devices (`ragg::agg_png`, `png`, `jpeg`,
  `pdf`, `svg`, etc.) as **CRITICAL** inside interactive RStudio — not
  a soft WARN as before.
* Attempts `options(device = "RStudioGD")` repair automatically.
* Prints the exact sysadmin remediation commands when a stale fragment
  is detected.

**2. Fixed `scripts/99_botanical_plot_stress_test.R` formatting bug.**
`message("...fast (%.3f s).", display_elapsed)` → `message(sprintf(...))`.
`message()` does not format `%f`, so the elapsed time was appended as
literal text after the format string. The stress test already uses base
`substr()` (not `rlang::str_sub`) — the host runtime error with
`rlang::str_sub` was from a stale deployed copy.

**3. Added `docs/operations/TROUBLESHOOTING.md` §1.7.**
New runbook section: "RStudio Plots pane blank / plots not displayed
in browser". Covers symptom, root cause (`grep` verification on the
production node), quick per-session workaround, durable sysadmin fix
(redeploy option 3 + restart), diagnostic script reference, and
secondary causes checklist (user `.Rprofile`, collapsed pane, browser
cache).

**4. Updated `templates/Rprofile_site.d/50_pkg_hooks.R.template` header.**
Added cross-reference comment pointing operators to
`docs/operations/TROUBLESHOOTING.md §1.7` for the full investigation
and remediation context.

### Files touched

* `scripts/99_diagnose_rstudio_plot_pane.R` (TEST 2 hardened: +60 lines)
* `scripts/99_botanical_plot_stress_test.R` (line 536 `message→sprintf` fix)
* `docs/operations/TROUBLESHOOTING.md` (new §1.7 runbook entry)
* `templates/Rprofile_site.d/50_pkg_hooks.R.template` (header comment cross-reference)
* `docs/reference/Rprofile_site.CHANGELOG.md` (this entry)

### No RPROFILE_VERSION bump

RPROFILE_VERSION remains `"12.10"`. None of the Rprofile fragment
semantics changed — the v12.2 guard was already in the GitHub template
and in `config/setup_nodes.vars.conf`. The changes in this commit are
diagnostic-tooling and documentation only, which do not cause a
byte-compiled bundle mismatch.

### Tier deltas

* **T2 (docker-deploy):** Same `50_pkg_hooks.R.template` fragment
  applies. The diagnostic scripts and runbook are T1-host specific;
  T2 containers inherit the template at build time.
* **T3 (kubernetes-deploy):** SKELETON_NOT_READY — defer.

### Operator remediation on the production host

```bash
git pull
sudo bash scripts/50_setup_nodes.sh
# → select option 3 (Config files only — Rprofile + Renviron, Step 8)
sudo systemctl restart rstudio-server
```

---

## v12.10 (2026-05-11) — "install-storm safety valve (opt-in) + R010 doc reconciliation"

### Trigger

Users on biome-calc occasionally hit the confusing 2-step failure of
`install.packages("foo")`:

```
Warning: 'lib = "/usr/lib/R/site-library"' is not writable
Would you like to use a personal library instead? (yes/No/cancel)
```

In batch jobs (no TTY), step 2 hangs until wall-time. Even in interactive
sessions, the wording suggests "say yes and it works" — which then drifts
the user lib away from the cluster pin in `r_env_manager.conf`. Same class
of trap for `remotes::install_github()`, `devtools::install_github()`,
`pak::pkg_install()` and `BiocManager::install()`.

A parallel issue: `docs/user_guides/PARALLEL_R_DOS_AND_DONTS.md §R010` and
`scripts/lib/r_lint_rules.tsv :: R010` referenced an aspirational env var
`BIOME_USER_CORES` that is **never exported anywhere** in T1, T2 or T3.
Users following the doc verbatim got `as.integer("")` ⇒ `NA` ⇒ silent
fall-through to default 4.

### Fix (T1 authoritative)

**1. New fragment `templates/Rprofile_site.d/42_install_block.R.template`
— shipped DORMANT (default OFF).** Per HC-13 ("adapt the system to
portable user code; never silently change behaviour") v12.10 ships only
the *machinery* to short-circuit the install path. Default behaviour is
identical to v12.9.4: a bare `install.packages("foo")` still gets the
stock R "would you like a personal library?" / EACCES path.

A sysadmin arms the block only when an install-storm becomes a real
incident (e.g. one user looping `install.packages` inside a parLapply).
Once armed, the call dies on line 1 with a single self-explanatory
message:

```
BIOME-CALC: install.packages() is disabled on this cluster.
            Ask the sysadmin to add 'pkgname' to
            config/r_env_manager.conf :: R_USER_PACKAGES_CRAN,
            then re-run.
            (This block was armed by the sysadmin via
             ENABLE_INSTALL_BLOCK=TRUE or BIOME_FORCE_INSTALL_BLOCK=1.)
```

Mechanism:

* `utils::install.packages` wrapped at fragment-load time via
  `.biome_install_wrapper` (fragment 40) — same lexical-scope-preserving
  pattern as the v11.4 `safe_makeCluster`.
* `remotes`, `devtools`, `pak`, `BiocManager` install entry-points wrapped
  on demand via `setHook(packageEvent(<pkg>, "onLoad"), ...)` so the deny
  fires before the user's first call but after the namespace is loaded.
* Feature flag `ENABLE_INSTALL_BLOCK <- FALSE` (PSE cat. 2, **default
  OFF**) with runtime opt-in `BIOME_FORCE_INSTALL_BLOCK=1` for per-session
  arming. Fleet-wide arming = flip the constant in the template and
  redeploy via `scripts/50_setup_nodes.sh`.
* Originals saved into `.biome_env$original_install.packages` etc. so
  even with the block armed the sysadmin path can call through
  (`.biome_env$original_install.packages(...)`) without disarming
  globally.

**2. R010 doc reconciliation.** `scripts/lib/r_lint_rules.tsv` and
`docs/user_guides/PARALLEL_R_DOS_AND_DONTS.md §R010` now point at
`parallel::detectCores(logical = FALSE)`, which is already cgroup-aware
on biome-calc via fragment `05_thread_guard`. Removed the dangling
`BIOME_USER_CORES` reference. R007 and R023 sections now also document
the v12.10 opt-in safety valve so users / sysadmins know the knob exists.

**3. RPROFILE_VERSION bump.** `config/setup_nodes.vars.conf` :
`12.9.4 → 12.10`. Justified even with default OFF: a new fragment ships
in `Rprofile_site.d/`, dispatcher inventory changes, and §R007/§R010/§R023
of the user guide land — all per HC-18 (RPROFILE_VERSION bumps land with
matching CHANGELOG + cross-doc updates in the same commit).

### Files touched

* `templates/Rprofile_site.d/42_install_block.R.template` (NEW)
* `templates/Rprofile_site.d/README.md` (inventory: row for fragment 42)
* `config/setup_nodes.vars.conf` (`RPROFILE_VERSION="12.10"`)
* `scripts/lib/r_lint_rules.tsv` (R010 fix-text reconciled; pattern unchanged)
* `docs/user_guides/PARALLEL_R_DOS_AND_DONTS.md` (R007 + R010 + R023 sections)
* `docs/reference/Rprofile_site.CHANGELOG.md` (this entry)

### Tier deltas

* **T2 (docker-deploy)**: install_block fragment NOT yet ported.
  Containers pin via `Dockerfile` at build time, so the install path is
  cold and the trap is rare; will follow in the next T2 mirror with the
  same default-OFF posture.
* **T3 (kubernetes-deploy)**: SKELETON_NOT_READY — defer with the rest.

### Arming the block (sysadmin)

```bash
# A) Per-session arm (one R session only, no redeploy):
BIOME_FORCE_INSTALL_BLOCK=1 R

# B) Fleet-wide arm (when an install-storm is a real incident):
sed -i 's/ENABLE_INSTALL_BLOCK <- FALSE/ENABLE_INSTALL_BLOCK <- TRUE/' \
    templates/Rprofile_site.d/42_install_block.R.template
sudo bash scripts/50_setup_nodes.sh   # redeploys to all calc nodes

# C) Disarm fleet-wide: flip back to FALSE, redeploy.
```

### Rollback

```bash
# Remove the fragment entirely from a node:
sudo rm /etc/R/Rprofile_site.d/42_install_block.R
# (Re-running scripts/50_setup_nodes.sh will reinstall it default-OFF.)

# Full revert: drop RPROFILE_VERSION back to 12.9.4, remove the fragment
# template, restore R010 fix-text in r_lint_rules.tsv to the v12.9.4 text.
```

### Verification

```bash
# 1. Parse the new fragment with the same rule setup_nodes.sh uses:
Rscript -e 'parse(file = "templates/Rprofile_site.d/42_install_block.R.template")'

# 2. Lint regression: no rule pattern changed, so 31/31 still pass:
./tests/r_lint_test.sh

# 3a. Default-OFF smoke (no env var): install path unchanged from v12.9.4
R --no-save -e 'cat(Sys.getenv("BIOME_FORCE_INSTALL_BLOCK"), "\n")'
# → empty line; install.packages() behaves like stock R.

# 3b. Armed smoke (per-session opt-in):
BIOME_FORCE_INSTALL_BLOCK=1 R --no-save \
    -e 'install.packages("nonexistent")' 2>&1 | grep "BIOME-CALC"
```

---

## v12.9.4 (2026-05-11) — "glibc allocator caps + cgroup-aware terraOptions (Lussu RSS-climb)"

### Symptom on biome-calc03 (post-v12.9.3 deploy)

After v12.9.3 unblocked the 4103-chunk cascade, Lussu's
`block1_aoh_to_rij.R` continued to climb in RSS on every PSOCK worker:

```
chunk_size=2  (smallest possible) → worker RSS: 1G → 8G → 24G → 63G → OOM
gc(full=TRUE) at every chunk boundary → no effect on RSS
```

`Rss` in `/proc/<pid>/status` grew monotonically across the run even
when the R-level heap (per `gc()`) reported < 2 GB live. Master also
climbed; so did `terra::values(r, mat=FALSE)` calls inside
`process_one_aoh_worker()`.

### Root cause: 3 sub-bugs in T1, all interacting

**(1) Renviron.template missing glibc allocator caps.**
glibc defaults to `8 × n_cores` per-thread arenas (= 256 on a 32-core
host). Memory `free()`'d by R's `R_alloc` / `Rf_allocVector` returns to
the per-thread arena, **not** to the kernel via `munmap` / `sbrk(-)`.
Result: long-running parallel R workloads (terra::values,
data.table by-reference, parLapply fan-out) leak RSS unboundedly even
when R's heap is healthy. Industry-standard mitigation
(Apache Arrow R team, Rust/jemalloc folklore): set
`MALLOC_ARENA_MAX=2`, `MALLOC_TRIM_THRESHOLD_=128MB`, `R_GC_MEM_GROW=0`.

**(2) Fragment 30 (`30_psock_factory.R.template`) not propagating
allocator vars to PSOCK workers.** Even with (1) fixed, every PSOCK
worker spawned by `parallelly::makeClusterPSOCK(rscript_envs=env_vec)`
inherits **only the env vars listed in `env_vec`** — it does NOT
inherit the master's full environment. `MALLOC_*` were silently absent
from `env_vec`, so workers re-created the default 8×n_cores arenas
regardless of what Renviron.site said.

**(3) Fragment 50 (`50_pkg_hooks.R.template`) using host RAM for
`terraOptions(memfrac=0.5)`.** terra's `memfrac` is a fraction of the
**bare-host RAM**, not the cgroup quota. On a 256 GB host with a 64 GB
user.slice quota, `memfrac=0.5` ⇒ terra targets 128 GB ⇒ OOM-kill
fires before the v12.4 `todisk=TRUE` spill kicks in.

### Fix

**Renviron.template (T1) + docker-deploy/templates/Renviron.template (T2 mirror)**: new
"GLIBC ALLOCATOR TUNING" block before `ARROW_DEFAULT_MEMORY_POOL`:

```bash
MALLOC_ARENA_MAX=2
MALLOC_TRIM_THRESHOLD_=134217728
R_GC_MEM_GROW=0
```

**`templates/Rprofile_site.d/30_psock_factory.R.template`**: add the same
three vars to `env_vec` so they reach every PSOCK worker spawned via
`.biome_make_cluster_impl()` / `biome_make_cluster()` / fragment 52's
fork-reroute path.

**`templates/Rprofile_site.d/50_pkg_hooks.R.template`**: cgroup-aware
`memmax` resolved through fragment 20's `.biome_env$.get_ram_gb()`
accessor; capped at 50 % of the cgroup quota (or 8 GB fallback).

```r
.biome_cgroup_ram_gb <- tryCatch(.biome_env$.get_ram_gb(),
                                 error = function(e) NA_real_)
.biome_terra_memmax <- if (is.finite(.biome_cgroup_ram_gb))
  max(2, floor(.biome_cgroup_ram_gb * 0.5))
else
  8L
terra::terraOptions(memfrac = 0.5, memmax = .biome_terra_memmax,
                    tempdir = td, verbose = FALSE,
                    todisk  = .terra_todisk)
```

### Tier deltas

| Tier | Status | Notes |
|------|--------|-------|
| T1 host | **fixed** | All 3 sub-bugs patched in this commit. |
| T2 docker | **partial** | Renviron mirrored. Rprofile fragments arrive via shared `templates/` symlink in `docker-deploy/templates/` (already covered). |
| T3 k8s | **deferred** | SKELETON_NOT_READY; will inherit when T2 stabilizes. |

### HC-13 boundary reaffirmed

User script bugs identified during audit (e.g. `terra::values(r, mat=FALSE)`
materializing 8 GB per chunk; `i %% 10 == 0` progress logger never
firing for `chunk_size < 10`) are **NOT** patched here. Per project
ethos: *"esattamente mai patchare script utente se c'è problema sul
server"*. The user fixes those in their own copy of
`block1_aoh_to_rij.R`.

### Files touched (8)

* `templates/Renviron.template`
* `templates/Rprofile_site.d/30_psock_factory.R.template`
* `templates/Rprofile_site.d/50_pkg_hooks.R.template`
* `config/setup_nodes.vars.conf` (RPROFILE_VERSION 12.9.3 → 12.9.4)
* `docs/reference/Rprofile_site.CHANGELOG.md` (this file)
* `docs/operations/UPGRADE_TO_v12.4.md` (new §17)
* `scripts/99_diagnose_lussu_hang.sh` (HARNESS_VERSION 1.3 → 1.4, new Probe F)
* `docker-deploy/templates/Renviron.template` (T2 mirror)

### Validation

`scripts/99_diagnose_lussu_hang.sh` Probe F (new) spawns a PSOCK cluster
and asserts that workers report `Sys.getenv("MALLOC_ARENA_MAX") == "2"`.
A regression in fragment 30's env_vec will trip Probe F (`exit 1`).

### Deploy

```bash
git pull
sudo bash scripts/50_setup_nodes.sh        # menu option 3 (Rprofile + Renviron only)
sudo systemctl restart rstudio-server
sudo bash scripts/99_diagnose_lussu_hang.sh # confirm Probe F passes
```

---

## v12.9.3 (2026-05-10) — "Fragment 52 GLOBAL-SYNC: PSOCK reroute parity with mclapply fork"

### Symptom on biome-calc03

User Lussu's portable `parallel::mclapply()` pipeline
(`block1_aoh_to_rij.R`, 4103 chunks × 10 PSOCK workers, terra+data.table
loaded at master) failed every single chunk with:

```
1: chunk_unhandled_error  could not find function "process_chunk"
2: chunk_unhandled_error  could not find function "process_chunk"
…
4103: chunk_unhandled_error  could not find function "process_chunk"
```

`process_chunk` was defined at the top level of the user's `.R` file,
right above the `mclapply()` call. With stock `parallel::mclapply`
(fork) the helper would have been visible in every worker — fork
inherits the master's globalenv. Under our v12.4 fork-guard
(fragment 52, fork → PSOCK auto-reroute) the workers are FRESH R
processes and never see the helper.

### Root cause: GLOBAL-SYNC missing in fragment 52

`templates/Rprofile_site.d/52_mclapply_guard.R.template` shipped (since
v12.4) two replication blocks for the PSOCK reroute path:

1. **PKG-SYNC** (v12.7) — replicates master's *attached* packages.
2. **clusterSetRNGStream** for `mc.set.seed`.

But it never replicated the master's **`globalenv()` user objects** to
the workers. Every helper function, every `template_info`,
`species_dt`, `chunk_dir`, etc. defined at the script's top level
was invisible to the FUN closure as soon as parLapply executed it.

This is a silent HC-13 violation: the reroute is supposed to be
invisible. v12.4-v12.9.2 it was invisible **only when FUN was
self-contained** (no references to globals). Lussu's portable code,
which works on stock R + mclapply, broke on biome-calc.

### Fix

In `templates/Rprofile_site.d/52_mclapply_guard.R.template`, after
PKG-SYNC and before `parLapply`, a new GLOBAL-SYNC block:

```r
master_globals <- tryCatch(ls(envir = globalenv(), all.names = FALSE),
                           error = function(e) character(0))
if (length(master_globals)) {
  tryCatch({
    parallel::clusterExport(cl, master_globals, envir = globalenv())
    sys_log("ForkGuard", "GLOBAL-SYNC",
            sprintf("exported %d global(s) to %d worker(s)",
                    length(master_globals), length(cl)))
  }, error = function(e) {
    sys_log("ForkGuard", "WARN",
            sprintf("clusterExport globals failed (%s); user globals unavailable on workers",
                    conditionMessage(e)))
  })
}
```

Design notes:

* `all.names = FALSE` deliberately skips dotted housekeeping
  (`.Random.seed`, `.biome_*` internals) — exactly fork's
  "user-visible" set.
* `tryCatch` wrappers ensure failures degrade to today's behaviour
  (logged, never fatal).
* Only fires on the reroute path (already inside the PSOCK branch).
* Lookups against `globalenv()` only — exactly what fork would have
  given the worker.
* Bypass invariato: `BIOME_DISABLE_FORK_GUARD=1` (operator escape
  hatch — falls back to native fork mclapply, full futex-deadlock
  risk).

### Diagnostic harness updated (v1.3)

`scripts/99_diagnose_lussu_hang.sh` Probe E (PSOCK swap shim) bumped
to HARNESS_VERSION 1.3:

* Shim's swapped `mclapply` now mirrors fragment 52: replicates
  attached packages AND exports `globalenv()` user objects to
  workers before `parLapply`.
* Self-test added: probe defines `.__probe_E_helper` at master and
  asserts `mclapply(1:3, function(i) .__probe_E_helper(i), mc.cores=2)`
  returns `c(8L, 15L, 22L)` BEFORE source()ing the user script.
  Fails with explicit `HC-13 regression: fragment 52 GLOBAL-SYNC
  missing or broken` if globals don't propagate, so future fragment
  regressions can never silently pass this probe.

`HARNESS_VERSION="1.3"` is script-only; does NOT bump
`RPROFILE_VERSION`.

### Deploy

```bash
cd /opt/R-studioConf && git pull
sudo bash scripts/50_setup_nodes.sh
# Selezione: 3   (Step 8 — fragments redeploy + bundle rebuild atomico)
sudo systemctl restart rstudio-server
sudo bash scripts/50_setup_nodes.sh --verify
# Atteso: Rprofile.site version: 12.9.3
```

### Validation

```bash
# (a) Smoke test — exact reproducer of Lussu's pattern
sudo -u <user> Rscript -e '
  library(terra); library(data.table)
  process_chunk <- function(cid) data.table(chunk_id = cid, ok = TRUE)
  res <- parallel::mclapply(1:4, function(i) process_chunk(i), mc.cores = 4)
  stopifnot(length(res) == 4L,
            all(vapply(res, function(x) x$ok, logical(1))))
  cat("v12.9.3 GLOBAL-SYNC OK\n")
'
# v12.9.2: 4× "could not find function process_chunk" → checkForRemoteErrors
# v12.9.3: "v12.9.3 GLOBAL-SYNC OK"

# (b) Audit log breadcrumb
grep -E 'ForkGuard +(REROUTE|PKG-SYNC|GLOBAL-SYNC|WARN)' \
     /var/log/biome-log/r_biome_system.log | tail
# Atteso una linea GLOBAL-SYNC per ogni mclapply rerouted.

# (c) Lussu probe (catches future regressions)
sudo -u <user> /usr/local/bin/99_diagnose_lussu_hang.sh /path/script.R
# Atteso "[probe_E] self-test OK: master globals propagate to PSOCK workers"
```

### Rollback

```bash
sudo cp /etc/R/Rprofile_site.d/52_mclapply_guard.R.bak \
        /etc/R/Rprofile_site.d/52_mclapply_guard.R
sudo rm -rf /etc/R/Rprofile_site.d/.compiled
sudo systemctl restart rstudio-server
sed -i 's/RPROFILE_VERSION="12.9.3"/RPROFILE_VERSION="12.9.2"/' \
  /opt/R-studioConf/config/setup_nodes.vars.conf
```

### Tier deltas

* **T1 (host)**: implementato.
* **T2 (docker)**: N/A — `docker-deploy/templates/` non contiene
  `Rprofile_site.d/` (backlog strutturale v12.7, vedi v12.7 §Tier
  deltas). Il fix v12.9.3 verrà port-forward solo quando T2 verrà
  allineato all'intera modularizzazione v12.1+.
* **T3 (k8s)**: SKELETON_NOT_READY — vedi v12.7.

### Files touched

* `templates/Rprofile_site.d/52_mclapply_guard.R.template` (+34 lines, GLOBAL-SYNC block)
* `scripts/99_diagnose_lussu_hang.sh` (HARNESS_VERSION 1.2 → 1.3, Probe E rewrite + self-test)
* `config/setup_nodes.vars.conf` (RPROFILE_VERSION 12.9.2 → 12.9.3)
* `docs/operations/UPGRADE_TO_v12.4.md` (new §16 — v12.9.3 deploy notes)
* `docs/reference/Rprofile_site.CHANGELOG.md` (this entry)

---

## v12.9.2 (2026-05-10) — "Writer-agnostic canonical-path fallback in fragment 04"

### Symptom on biome-calc03

After v12.9 + v12.9.1 deploy, three AD users still saw NFS-only `.libPaths()`
even though their `/var/lib/biome-Rlibs/<u>/4.5` leaf existed with correct
ownership:

| user                | leaf exists | leaf writable | `.libPaths()[1]`        |
|---------------------|-------------|---------------|-------------------------|
| user.two  | yes         | yes           | NFS ❌                  |
| user.three  | yes         | yes           | NFS ❌                  |
| user.four    | yes         | yes           | NFS ❌                  |
| sysadmin.user | yes         | yes           | local ✅                |
| martina.livornese2  | yes         | yes           | local ✅                |

### Root cause: `~/.Renviron` multi-writer race

R reads files in order `$R_HOME/etc/Renviron → /etc/R/Renviron.site → ~/.Renviron`
(LAST WINS). Diagnostic via `Rscript /tmp/probe.R` showed the broken users had
`Sys.getenv("R_LIBS_USER")` equal to `/nfs/home/<u>/R/.../4.5` only — i.e.
`~/.Renviron` had pinned `R_LIBS_USER` and silently overrode the site value
`/var/lib/biome-Rlibs/%u/%v:/nfs/home/.../%v`.

Three different writers compete on `~/.Renviron`:

1. `scripts/50_setup_nodes.sh` per-user migration → backup `.Renviron.bak`
   (no timestamp suffix) + `sed -i '/^...R_LIBS_USER.../d'` (DELETE).
2. `scripts/99_check_user_renviron_overrides.sh --fix --commit` → backup
   `.bak.${TS}` + awk **comment-out** with marker
   `# [biome-cleanup YYYY-MM-DD] disabled (was: ...)`.
3. **A third writer** (not located in active scripts/; possibly archived
   provisioning code or a first-login PAM helper) re-appended a fresh live
   `R_LIBS_USER="/nfs/home/<u>/R/x86_64-pc-linux-gnu-library/4.5"` line at
   the end of the file AFTER the v99 cleanup ran. Forensic evidence:
   `.Renviron.bak` was 741 B, current file 818 B (grew by 77 B = exactly one
   `R_LIBS_USER=...` line). Comment markers from the v99 awk were present
   on lines 4-5; the live override was on line 13.

Since fragment 04 v12.9 derives its prepend list from the **raw**
`R_LIBS_USER`, and the raw value contained no `/var/lib/biome-Rlibs/`
entry for these users, `existing_targets` was empty and the prepend was
correctly skipped (HC-13 — never invent paths the env var did not declare).

### Fix philosophy: stop trying to be the only writer

Per HC-13 (do not touch user files) and ethos #17 (adapt the system to
portable user R code — never silently patch user scripts), the right
solution is NOT to hunt the third writer and not to enforce a
single-writer policy on `~/.Renviron`. Instead, make the runtime
**robust to ANY writer** by probing the well-known canonical path
independently of `R_LIBS_USER`.

### Fix (`templates/Rprofile_site.d/04_user_lib_bootstrap.R.template`)

After the v12.9 `existing_targets` derivation, add a writer-agnostic
fallback:

```r
canonical_target <- file.path("/var/lib/biome-Rlibs", user_login, ver_short)
canonical_ok <- tryCatch(
  nzchar(user_login) &&
    dir.exists(canonical_target) &&
    file.access(canonical_target, mode = 2L) == 0L,
  error = function(e) FALSE
)
if (isTRUE(canonical_ok)) {
  existing_targets <- unique(c(existing_targets, canonical_target))
}
```

This:

* Touches NO user files (HC-13 honored — only in-session `.libPaths()`).
* Idempotent (`unique(c(...))` preserves first-occurrence order).
* Defense-in-depth: works even if a future writer breaks `R_LIBS_USER`.
* Pessimistic: explicit `file.access(_, 2)` write check, not just
  `dir.exists()`. If write-access is missing the prepend is skipped
  (HC-13 — never set the user up to fail at `install.packages()`).

### Audit script enhancement (`scripts/99_check_user_renviron_overrides.sh`)

Added `WRITER-CONFLICT` flag: when a `~/.Renviron` contains BOTH a
`# [biome-cleanup ...] disabled (was: R_LIBS_*` marker AND a later
uncommented `R_LIBS_USER` / `R_LIBS_SITE` / `R_LIBS` line, the audit
table prints a yellow `WRITER-CONFLICT` flag pointing at the original
cleanup date. This surfaces the third-writer race for ops monitoring
without blocking the existing override audit.

### Immediate remediation (one-shot)

Before the v12.9.2 fragment lands, the live appended override can be
neutralized with the existing tool:

```bash
sudo /opt/R-studioConf/scripts/99_check_user_renviron_overrides.sh \
  --fix --commit -y
```

Run on biome-calc03 (2026-05-10): patched 3 files (user.two,
user.three, user.four); post-patch `.libPaths()[1]` is
local-disk for all three. Recommend running the same on
biome-calc01/02/04 as a sweep.

### Files touched (T1 only)

| File                                                                | Change |
|---------------------------------------------------------------------|--------|
| `templates/Rprofile_site.d/04_user_lib_bootstrap.R.template`        | +24 lines (canonical-path fallback block + comments); header `v12.9 → v12.9.2` |
| `config/setup_nodes.vars.conf`                                      | `RPROFILE_VERSION="12.9" → "12.9.2"` (HC-18) |
| `docs/reference/Rprofile_site.CHANGELOG.md`                         | This v12.9.2 section (HC-18) |
| `scripts/99_check_user_renviron_overrides.sh`                       | +`WRITER-CONFLICT` flag detection |
| `docs/operations/UPGRADE_TO_v12.4.md`                               | §14: v12.9.2 deploy step + sweep command |

T2/T3: no deviation. Container images rebuilt from patched scripts/ pick
up the fragment automatically.

### Verification (post-deploy)

```bash
for u in user.two user.three user.four; do
  sudo -u "$u" -i Rscript -e '
    cat(.libPaths()[1L], "\n")
  '
done
# Expect: /var/lib/biome-Rlibs/<u>/4.5 for each.
```

---

## v12.9 (2026-05-10) — "User-lib bootstrap REAL fix: %u non-expansion + libPaths cache + AD enumeration + parent-dir ownership"

### v12.9.1 follow-up patch (same day, post-deploy on biome-calc03)

Two regressions surfaced after the initial v12.9 deploy:

1. **`scripts/50_setup_nodes.sh` line 39 forward-ref to `log_error`.**
   The pre-flight `[[ ! -f "${VARS_CONF}" ]]` and root-check error paths
   called the `log_error` wrapper which is defined ~60 lines later in
   the same file. Bash parses but does not evaluate function bodies
   until call-time, so the bug stayed dormant until a checkout was
   missing `config/setup_nodes.vars.conf`. Fix: both pre-flight error
   paths now call the base `log "ERROR" "..."` from `lib/common_utils.sh`
   (already sourced at line ~34), which is guaranteed available.

2. **Step 7c warmup created `/var/lib/biome-Rlibs/<u>/` parent dirs as
   `root:root`.** GNU `install -d -m PERM -o U -g G LEAF` only applies
   `-o/-g` to the LEAF (`<v>/`), not to the auto-created parent
   (`<u>/`). On biome-calc03, every AD user except `user.one`
   (whose parent was created by his own R session via fragment 04
   `dir.create(recursive=TRUE)`) ended up with a root-owned subtree —
   meaning `install.packages()` from RStudio would fail with
   "lib not writable" on first contact. Fix: warmup now uses explicit
   `mkdir -p` + `chmod 0755` + `chown ${u}:${gid}` on **both** the
   parent and the leaf. Re-running the loop also HEALS dirs left
   root-owned by earlier (broken) deploys — no manual cleanup needed.

Both fixes are tier-T1 patches (host scripts). Files touched:

* `scripts/50_setup_nodes.sh` — lines ~39, ~71, and Step 7c warmup loop.

No tier-T2/T3 deviation; T2 mirrors automatically once compose images
rebuild from the patched scripts/.

---

CONTEXT. v12.8 shipped three fixes (UID gate widened to `>=1000 && !=65534`,
fragment 04 reads RAW `R_LIBS_USER`, expand_one resolves `%u %v %V %p %o %a`

* shell-style `$HOME/$USER/~`). On `biome-calc03`, post-deploy reproduction
on `user.one` (UID 100000001) and `sysadmin.user` (UID 100000002)
showed v12.8 **did not fix the symptom**: `.libPaths()` still returned only
the NFS fallback. Step 7c warmup logged `warmed=1 skipped=40` — only
`ladmin` was warmed; every AD user fell off the bottom of the loop. v12.8
audit log confirmed fragment 04's `dir.create()` succeeded (the dir was
created with correct ownership), and yet `.libPaths()` did not include it.

ROOT CAUSE — THREE INDEPENDENT v12.8 RESIDUAL DEFECTS.

1. **`templates/Rprofile_site.d/04_user_lib_bootstrap.R` — `.libPaths(.libPaths())` is a NO-OP.**
   v12.8 ended the fragment with:

   ```r
   tryCatch({ .libPaths(.libPaths()) }, error = function(e) invisible(NULL))
   ```

   intending to "force a re-scan so the freshly created dir appears as `[1]`".
   This is structurally impossible. R's `base::.libPaths()` getter
   *returns the already-filtered cache*: when called with no argument it
   yields the live, normalised, existence-checked vector. Passing that
   back as the setter argument is mathematically idempotent — by the time
   the dir is created, the cache (computed at session startup) has
   *already dropped* the non-existent local entry, and getting+setting
   the same cache cannot re-introduce it. To make R re-scan, you must
   pass an explicit list that *includes* the new path. Audit log on
   user.one confirmed: `[2026-05-10 ...] 04_user_lib_bootstrap (v12.8):
   created /var/lib/biome-Rlibs/user.one/4.5` followed seconds later
   by `.libPaths()` still showing only NFS.

2. **R does NOT expand `%u` in `Renviron.site`.**
   `templates/Renviron.template` ships:

   ```
   R_LIBS_USER=/var/lib/biome-Rlibs/%u/%v:${HOME}/R/x86_64-pc-linux-gnu-library/%v
   ```

   Per R-admin §B.1 the only Renviron tokens R recognises are `%V %v %p %o %a`.
   `%u` is **not** in that list — R passes it through verbatim. So the
   actual `R_LIBS_USER` env var seen by the session is the literal string
   `/var/lib/biome-Rlibs/%u/4.5:...`, which R then drops at startup
   because `/var/lib/biome-Rlibs/%u/4.5` does not exist as a directory.
   The v12.8 fragment 04 *did* expand `%u` in its own parser
   (`expand_one`) and create the right dir — but the *kernel*
   `.libPaths()` cache had already discarded the literal-`%u` path and
   never knew to look at the cleaned variant. Defect 1 then prevented
   recovery.

3. **`scripts/50_setup_nodes.sh` Step 7c warmup — bulk `getent passwd` blind to SSSD AD users.**
   v12.8 widened the UID gate (correct), but kept the enumeration source
   as `getent passwd` (bulk). On Debian, `sssd.conf` defaults to
   `enumerate = false` (per upstream best practice — full AD enumeration
   on a 100k-entry forest is a DoS vector). Bulk `getent passwd`
   therefore returns ONLY `/etc/passwd` entries — every AD user is
   invisible. Per-name `getent passwd <name>` *does* hit SSSD and
   resolves correctly. Confirmed empirically on biome-calc03:
   `getent passwd user.one` returns the full passwd line;
   `getent passwd | grep michele` returns nothing.

WHY v12.8 PASSED LOCAL TESTS. The v12.8 dev path validated against
`ladmin` (local UID 1000): bulk `getent passwd` lists ladmin → warmup
runs → dir exists at startup → `.libPaths()[1]` resolves correctly →
fragment 04 short-circuits via `length(missing) == 0` → no
`.libPaths(.libPaths())` codepath ever exercised. The bug was reachable
only on AD users who lacked the warmup.

FIX (T1 first per HC-3, T2 N/A per `tier_deltas`).

**Fix 1 — `templates/Rprofile_site.d/04_user_lib_bootstrap.R` (v12.9).**

After `dir.create()` for missing entries, build the EXPANDED+VALIDATED
list of entries that NOW exist under `/var/lib/biome-Rlibs/`, and
explicitly prepend them to the live `.libPaths()`:

```r
existing_targets <- entries[
  vapply(entries,
         function(p) startsWith(p, "/var/lib/biome-Rlibs/") && dir.exists(p),
         logical(1L))
]
if (length(existing_targets)) {
  tryCatch({
    cur <- .libPaths()
    .libPaths(unique(c(existing_targets, cur)))
  }, error = function(e) invisible(NULL))
}
```

`unique()` keeps the existing ordering for any path R already resolved.
`startsWith` guard preserves the v12.8 path-validation contract — only
paths under the local-disk root are ever introduced. The `tryCatch`
graceful-degrades to NFS-only on any failure (e.g. read-only `/etc/R`
on a forensic host).

**Fix 2 — `scripts/50_setup_nodes.sh` Step 7c warmup (v12.9).**

Replace the single-source `< <(getent passwd)` with a hybrid enumeration
that unions local-files passwd with per-name SSSD lookups derived from
the NFS home directory listing:

```bash
done < <(
  {
    getent -s files passwd                                # local /etc/passwd
    if [[ -d "${nfs_home_base}" ]]; then
      local ad_name
      while IFS= read -r ad_name; do
        [[ -n "${ad_name}" ]] || continue
        getent passwd -- "${ad_name}" 2>/dev/null || true
      done < <(find "${nfs_home_base}" -mindepth 1 -maxdepth 1 \
                    -type d -printf '%f\n' 2>/dev/null | sort -u)
    fi
  } | awk -F: '!seen[$1]++'
)
```

`getent -s files passwd` is the explicit, race-free way to read
`/etc/passwd` only. `find /nfs/home -mindepth 1 -maxdepth 1 -type d`
is the canonical "who has a home dir on this cluster?" probe — it does
not depend on SSSD enumeration and is O(1) regardless of forest size.
Each home-dir name is then resolved via per-name `getent passwd <name>`
which DOES go to SSSD (NSS per-name lookups bypass `enumerate=false`).
`awk '!seen[$1]++'` deduplicates by username so a local user with a
matching `/nfs/home/<u>` stub appears once. `nfs_home_base` defaults to
`/nfs/home`; overridable via `NFS_HOME_BASE` in
`config/setup_nodes.vars.conf`.

**Fix 3 — version + docs (HC-18).**

* `RPROFILE_VERSION` 12.8 → **12.9** in `config/setup_nodes.vars.conf`.
* Commented `NFS_HOME_BASE="/nfs/home"` knob added next to RPROFILE_VERSION.
* This CHANGELOG entry.
* New §14 in `docs/operations/UPGRADE_TO_v12.4.md` (deploy + validate +
  rollback + operator one-shot remediation).
* §3.5 step 2 of the runbook: removed `R --vanilla` (vanilla bypasses
  `Rprofile.site`, `Renviron.site`, `R_LIBS_USER` — i.e. it bypasses
  EVERYTHING this fix deploys, making it useless as a validation
  vector). Replaced with `R --no-save -e ...`.

NOTE on `Renviron.template`. We deliberately do NOT remove `%u` from the
template. R's silent-drop of the literal `%u` path is benign once
fragment 04 v12.9 prepends the cleaned path to `.libPaths()` — and
keeping `%u` in the template documents intent (per-user library) for
operators reading `/etc/R/Renviron.site`. Fragment 04 is the canonical
source of truth for the actual prepend.

TIER DELTAS.

* T2 (`docker-deploy/`): `Rprofile_site.d/` still absent (v12.7 backlog).
  No mirror of fragment 04 needed until that backlog is closed.
  `setup_nodes.sh` is host-only.
* T3 (`kubernetes-deploy/`): SKELETON_NOT_READY — N/A.

OPERATOR ONE-SHOT REMEDIATION (apply NOW on already-deployed v12.6/v12.7/v12.8
nodes; unblocks every existing AD user without waiting for redeploy):

```bash
sudo bash -c '
  while IFS= read -r u; do
    pwline=$(getent passwd -- "$u") || continue
    IFS=: read -r name _ uid gid _ home shell <<<"$pwline"
    [[ ${uid} -ge 1000 && ${uid} -ne 65534 ]] || continue
    [[ "${shell}" == */nologin || "${shell}" == */false ]] && continue
    [[ -d "${home}" ]] || continue
    install -d -m 0755 -o "${uid}" -g "${gid}" \
      "/var/lib/biome-Rlibs/${name}/4.5"
  done < <(find /nfs/home -mindepth 1 -maxdepth 1 -type d -printf "%f\n" | sort -u)
'
```

After v12.9 deploy + Step 7c re-run, every existing AD user is warmed
(Layer A); any new AD user added later self-heals at first R startup
via the v12.9-rewritten fragment 04 (Layer D, now actually working).

ROLLBACK. Revert four files; `RPROFILE_VERSION` back to 12.8. The v12.8
fragment 04 + Step 7c remain structurally broken for AD/SSSD users but
non-fatal (NFS fallback works), so reverting just re-introduces the
original symptom.

VERIFICATION.

(a) Step 7c warmup actually enumerates AD users

```bash
sudo bash scripts/50_setup_nodes.sh   # selection 1 or 7
grep -F 'Warm-up:' /var/log/biome-log/r_biome_system.log | tail -1
# Expect warmed=N where N includes ALL AD users with /nfs/home/<u> dirs.
```

(b) Affected user sees the local lib **without** --vanilla

```bash
sudo -u user.one -i R --no-save -e '.libPaths()'
# Expect /var/lib/biome-Rlibs/user.one/4.5 as [1].
# DO NOT use --vanilla — it bypasses Renviron.site + Rprofile.site.
```

(c) Runtime fragment self-heals on a fresh user (delete + relog)

```bash
sudo rm -rf /var/lib/biome-Rlibs/<test_user>
sudo -u <test_user> R --no-save -e '.libPaths()[1L]'
# Expect /var/lib/biome-Rlibs/<test_user>/4.5 (recreated by fragment 04
# AND prepended to live .libPaths via the v12.9 unique(c(...)) block).
ls -ld /var/lib/biome-Rlibs/<test_user>/4.5
# Expect owner=<test_user>, mode 0755.
```

(d) HC-13 not violated — no user file touched

```bash
sudo find /nfs/home/<test_user> -newer /var/lib/biome-Rlibs/<test_user>/4.5
# Expect zero entries.
```

---

## v12.8 (2026-05-10) — "User-lib bootstrap fix for AD/SSSD high-UID users"

CONTEXT. On `biome-calc03` AD-joined users authenticated via SSSD/Samba
(example: `sysadmin.user`, UID 100000002, gid 100000513
`domain_users`) reported that `R -e '.libPaths()'` showed only the NFS
fallback `/nfs/home/<user>/R/x86_64-pc-linux-gnu-library/4.5` — the
local-disk first entry `/var/lib/biome-Rlibs/<user>/4.5` from the v12.4
`Renviron.site` (`R_LIBS_USER=/var/lib/biome-Rlibs/%u/%v:${HOME}/R/...`)
never appeared. Symptom on every fresh node, every AD user, every R
session. `ls /var/lib/biome-Rlibs` only contained `ladmin` + `lost+found`,
confirming neither the v12.6 deploy-time warmup nor the v12.6 runtime
Rprofile fragment ever created the per-user dir.

ROOT CAUSE — TWO INDEPENDENT DEFECTS, SAME VICTIM (high-UID AD users).

1. **`scripts/50_setup_nodes.sh` Step 7c warmup UID gate.**
   The loop in `setup_nodes_local_rlibs()` had:

   ```bash
   [[ ${uid} -ge 1000 && ${uid} -lt 65000 ]] || continue
   ```

   SSSD/Samba SID-map AD users into the 100M+ range (UID 100000002 in
   our case), so every single AD user fell off the upper edge of the
   gate and was silently `continue`-d. The "warmed=N" log line at the
   end of Step 7c showed N = number of *local* accounts only, never AD.

2. **`templates/Rprofile_site.d/04_user_lib_bootstrap.R` runtime fragment.**
   The fragment read `target <- .libPaths()[1L]`. But R *silently filters
   out non-existent directories* before populating `.libPaths()` — so
   when `/var/lib/biome-Rlibs/<u>/<v>` does not yet exist (Defect 1
   guaranteed it never did for AD users), `.libPaths()[1]` is *already*
   the NFS fallback. The subsequent guard
   `if (!startsWith(target, "/var/lib/biome-Rlibs/"))` returns FALSE
   and the function exits without creating anything. The fragment could
   not self-heal — by design, given the broken assumption.

WHY THE BUGS HID. v12.6 was developed and verified against `ladmin`
(local UID 1000), which sits comfortably inside `[1000, 65000)`. The
warmup created `ladmin/4.5/` on every node, and (because the dir
existed) `.libPaths()[1]` resolved to it correctly, so the runtime
fragment never *needed* to create anything in the test environment —
masking Defect 2 entirely.

FIX (T1 first per HC-3, T2 mirror N/A per `tier_deltas`).

**Fix 1 — `scripts/50_setup_nodes.sh` Step 7c warmup gate.**

```bash
# v12.8: gate accepts AD/SSSD users (UIDs 100M+). Excludes system
# accounts (<1000) and the nobody sentinel (65534).
[[ ${uid} -ge 1000 && ${uid} -ne 65534 ]] || { warmup_skipped=$((warmup_skipped+1)); continue; }
```

Drops the upper ceiling, keeps the explicit nobody guard.

**Fix 2 — `templates/Rprofile_site.d/04_user_lib_bootstrap.R` (this fragment).**
Read RAW `Sys.getenv("R_LIBS_USER")` instead of `.libPaths()[1L]`.
Split on `:`, expand R Renviron tokens (`%u %v %V %p %o %a`) and
shell-style `${HOME}/${USER}/$HOME/$USER/~`, then `dir.create()` every
entry whose path `startsWith("/var/lib/biome-Rlibs/")` and does not yet
exist. Force a re-scan via `.libPaths(.libPaths())` so the *current*
session sees the freshly-created dir as `[1]` (otherwise R keeps the
filtered cache it computed at startup and the user still gets NFS-only
`.libPaths()` until next session). All operations wrapped in
`tryCatch`; failures fall through silently to the NFS fallback as
before. `BIOME_DISABLE_USER_LIB_BOOTSTRAP=1` escape hatch preserved.

**Fix 3 — version + docs (HC-18).**

* `RPROFILE_VERSION` 12.7 → **12.8** in `config/setup_nodes.vars.conf`.
* This CHANGELOG entry.
* Cross-reference appended to `docs/operations/UPGRADE_TO_v12.4.md`
  §11 (v12.6 user-lib auto-bootstrap section).

TIER DELTAS.

* T2 (`docker-deploy/`): no `Rprofile_site.d/` directory exists in T2
  templates yet (T2 still ships the v9-era monolithic
  `Rprofile_site.R.template`). No mirror needed for Fix 2. Recorded
  here as a known T2 lag — picked up when T2 adopts the fragment system.
* T2 also has no `setup_nodes.sh` equivalent; the warmup is host-only.
* T3 (`kubernetes-deploy/`): SKELETON_NOT_READY — N/A.

OPERATOR REMEDIATION (apply *now* on already-deployed v12.6/v12.7 nodes).
The code fix lands on next deploy. To unblock affected users immediately
without waiting for redeploy:

```bash
# Per affected user (substitute login + gid + R short version):
sudo install -d -m 0755 -o sysadmin.user -g domain_users \
  /var/lib/biome-Rlibs/sysadmin.user/4.5
```

After v12.8 deploy + Step 7c re-run, every existing AD user is
warmed up, and any new AD user added later self-heals at first R
startup via the rewritten fragment 04.

ROLLBACK. Revert the three files; `RPROFILE_VERSION` back to 12.7.
The v12.7 fragment 04 is structurally broken for AD/SSSD users but
non-fatal (NFS fallback works), so reverting just re-introduces the
original symptom.

VERIFICATION.

(a) Warmup ran for AD users

```
sudo bash scripts/50_setup_nodes.sh   # selection 1 or L
grep -F 'Warm-up:' /var/log/biome-log/r_biome_system.log | tail -1
# Expect warmed=N where N includes the AD users present in `getent passwd`.
```

(b) Affected user can now see the local lib without the manual chown

```
sudo -u sysadmin.user -i R --vanilla -e '.libPaths()'
# Expect /var/lib/biome-Rlibs/sysadmin.user/4.5 as [1].
```

(c) Runtime fragment self-heals on a fresh user (delete + relog)

```
sudo rm -rf /var/lib/biome-Rlibs/<some_test_user>
sudo -u <some_test_user> R --vanilla -e '.libPaths()[1L]'
# Expect /var/lib/biome-Rlibs/<some_test_user>/4.5 (recreated by fragment 04).
ls -ld /var/lib/biome-Rlibs/<some_test_user>/4.5
# Expect owner=<some_test_user>, mode 0755.
```

(d) HC-13 not violated — no user file touched

```
sudo find /nfs/home/<test_user> -newer /var/lib/biome-Rlibs/<test_user>/4.5
# Expect zero entries (we only created /var/lib/biome-Rlibs/...).
```

---

## v12.7 (2026-05-10) — "ForkGuard PSOCK pkg-replication (closes silent `could not find function` on mclapply reroute)"

CONTEXT. Post-v12.6 triage on `biome-calc03` of two researcher scripts
(`block1_aoh_to_rij.R`, `Mod7_sq_diff_original.R`) via
`/usr/local/bin/99_diagnose_user_script.sh` produced verdicts
`L0 PASS / L1 TIMEOUT 600s / L2 TIMEOUT 601s / L3 FAIL 82s` with the
following error from layer L3 (full kernel + all fragments):

```
Error in checkForRemoteErrors(val):
  10 nodes produced errors; first error:
    could not find function "data.table"
```

The asymmetry is the smoking gun: L1 (minimal Rprofile, fragment 52
absent) succeeded — the user's bare `mclapply()` ran on the fork path.
L3 (full profile, fragment 52 active) failed in 82 s on every chunk —
the reroute fired (user code does `library(terra)`), the cluster spawned,
the FUN closure called `data.table(...)`, and every PSOCK worker died
with "could not find function".

ROOT CAUSE (fragment 52 design defect since v12.4).
`52_mclapply_guard.R` reroutes a `mclapply()` call to a PSOCK cluster
when any fork-unsafe namespace (terra, sf, raster, …) is loaded in the
master. fork() inherits the master's full search path; PSOCK workers are
**fresh** R processes that start with the default base set only. The
fragment created the cluster, set RNG, and called `parLapply(cl, X, FUN, ...)`
**without** replicating the master's attached packages. Any user FUN
that called a non-base function via bare-name lookup (`data.table(...)`,
`mutate(...)`, `vect(...)`) crashed instantly on every worker. This
silently broke a swathe of portable user code — a direct HC-13 invariant
violation by the very fragment whose name promises HC-13 compliance.

FIX (T1). One block inserted in `.biome_mclapply_safe`, **after**
`clusterSetRNGStream` and **before** `parLapply`:

```r
master_pkgs <- setdiff(rev(.packages()),
                       c("base","methods","datasets","utils",
                         "grDevices","graphics","stats","parallel"))
if (length(master_pkgs)) {
  parallel::clusterCall(cl, function(pkgs) {
    for (p in pkgs) suppressPackageStartupMessages(
      tryCatch(library(p, character.only = TRUE), error = function(e) NULL))
  }, pkgs = master_pkgs)
}
```

Wrapped in `tryCatch`; failure logs `ForkGuard WARN` via `sys_log` and
falls through to `parLapply` (graceful degradation — fully-qualified
`pkg::fun()` call sites still work). Success logs `ForkGuard PKG-SYNC`
with the replicated pkg list and worker count.

| Artefact                                                | Change                                                                                                       | Status |
|---------------------------------------------------------|--------------------------------------------------------------------------------------------------------------|--------|
| `templates/Rprofile_site.d/52_mclapply_guard.R.template`| Insert `clusterCall` pkg-replication block before `parLapply`. ~30 LOC. No change to fork path or wrapper installer. | EDIT   |
| `config/setup_nodes.vars.conf`                          | `RPROFILE_VERSION="12.6"` → `"12.7"`.                                                                        | BUMP   |
| `docs/operations/UPGRADE_TO_v12.4.md` §12               | New section pointing to this entry; deploy = selezione 3 (Step 8 fragments + bundle rebuild).                | DOC    |

DESIGN NOTES.

* **Why `.packages()` not `loadedNamespaces()`**: we replicate only
  packages on the *search path* (those the user did `library()`/
  `require()` on). Loaded-but-not-attached namespaces are reachable via
  `pkg::fun` and don't need attaching on workers; attaching them all
  would balloon worker startup time and risk masking conflicts.
* **Excluded set** (`base, methods, datasets, utils, grDevices,
  graphics, stats, parallel`): always present on every R worker; calling
  `library()` on them is a no-op but pollutes the log.
* **Bundle invalidation**: editing fragment 52 changes its md5 → the
  v12.3 byte-compiled bundle manifest mismatches → next session
  demotes to the legacy per-fragment `sys.source` loop until Step 8
  rebuilds. PSE-safe by construction (see v12.3 entry).

KNOWN LIMITATIONS (deliberate, NOT fixed in v12.7).

* Master-only `library()` calls made *between* the cluster creation and
  `parLapply` are not propagated (we snapshot `.packages()` once). Edge
  case; practical user code attaches before `mclapply`.
* Worker library paths come from the worker's own `.libPaths()` —
  identical to fork() semantics on a single host (workers see the same
  `/var/lib/biome-Rlibs/<user>/<R-ver>` via `Renviron.site`). On a
  multi-host PSOCK cluster (not supported by fragment 30) this would
  need additional `clusterCall` to set `.libPaths`.

DEPLOYMENT (per node, idempotent — same procedure as v12.5/v12.6 §3):

```bash
cd /opt/R-studioConf && git pull
sudo bash scripts/50_setup_nodes.sh
# Selezione: 3   (Step 8 — fragments redeploy + bundle rebuild)
sudo systemctl restart rstudio-server
```

VALIDATION:

```bash
# (a) Reproduce the original crash on a v12.6 box (control)
sudo -u <user> Rscript -e '
  library(terra); library(data.table)
  res <- parallel::mclapply(1:4, function(i) data.table(x=i)[, y := x*2], mc.cores=4)
  str(res)'
# v12.6 (broken): 4 errors "could not find function 'data.table'"
# v12.7 (fixed):  list of 4 data.tables.

# (b) Inspect ForkGuard PKG-SYNC log line in /var/log/biome-log/r_biome_system.log
grep -E 'ForkGuard +(REROUTE|PKG-SYNC|WARN)' /var/log/biome-log/r_biome_system.log | tail
# Expect: REROUTE then PKG-SYNC entries on every mclapply call with terra loaded.

# (c) Re-run the offending harness layer — L3 must now FAIL on TIMEOUT (long
#     compute) rather than FAIL on "could not find function". A separate
#     follow-up (Track B, harness-only, no RPROFILE bump) fixes the
#     verdict-misclassification of long compute as TIMEOUT.
sudo /usr/local/bin/99_diagnose_user_script.sh /path/to/block1_aoh_to_rij.R
```

ROLLBACK. Three artefacts: (1) revert the inserted block in fragment 52
(file-level via `*.bak`), (2) bump `RPROFILE_VERSION` back to `12.6`,
(3) Step 8 rebuilds the bundle. No data migration. Per-user emergency
bypass remains `BIOME_DISABLE_FORK_GUARD=1` (disables the whole
fragment 52 reroute, not only the new pkg-sync block).

TIER DELTAS.

* **T1 (host)**: implemented (this entry).
* **T2 (docker)**: pending — and worse, **the entire `Rprofile_site.d/`
  directory is currently absent from `docker-deploy/templates/`**
  (verified 2026-05-10: only `Rprofile_site.R.template` is shipped).
  The T2 image therefore mirrors v12.0 monolith semantics, not v12.1+
  fragments. Fork-guard, thread-guard, options-guard, user-lib
  bootstrap, etc. are ALL missing in T2. This is a structural backlog
  item, not a v12.7 regression — flagging here so the next T2 sync
  surfaces it. To port v12.7 specifically, the entire `Rprofile_site.d/`
  tree must be copied into `docker-deploy/templates/` AND the rstudio
  Dockerfile must add the `COPY` + dispatcher-rendering step that
  `50_setup_nodes.sh` currently performs at install time.
* **T3 (k8s)**: pending — same gap. The fragments would ship as a
  ConfigMap mounted at `/etc/R/Rprofile_site.d/`; bundle rebuild via
  init container.

CROSS-REF: `docs/operations/UPGRADE_TO_v12.4.md` §12 — "v12.7 ForkGuard
pkg-sync (HC-13 closure)".

---

## v12.6 (2026-05-10) — "User-lib auto-bootstrap (`/var/lib/biome-Rlibs/<user>/<R-ver>/`)"

CONTEXT. Post-v12.5 validation on `biome-calc03` exposed a UX regression
inherited from the original v11.x library-layout migration: the very first
`install.packages()` call by an AD user that had **never logged into the
node before** failed with

```
Warning: lib = "/var/lib/biome-Rlibs/<user>/4.4" is not writable
Error:   unable to install packages
```

The root cause is structural — the per-user, per-R-major-minor library
directory under `/var/lib/biome-Rlibs/<u>/<R-ver>/` is owned root:root with
mode 0755 by default and is never created until *something* explicitly
invokes `dir.create()`. Fragment `05_thread_guard.R` already self-bootstraps
its log dir, but no fragment was responsible for the **lib** dir; the
parent `/var/lib/biome-Rlibs/<u>/` is created at PAM-session time by
`pam_mkhomedir`+`50_setup_nodes.sh` Step 7c, but the **R-version
sub-directory** (e.g. `4.4/`) was assumed to be hand-created by the
operator on every R minor bump. That assumption broke for new AD users
discovered between deploys.

FIX (T1, **layered D+A strategy**, single source of truth, ports to T2/T3).

| Artefact                                                             | Change                                                                                                                                                                                                  | Status |
|----------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|--------|
| `templates/Rprofile_site.d/04_user_lib_bootstrap.R.template`         | NEW fragment. Idempotent; runs in **all** R sessions (interactive + Rscript); path-validated `startsWith("/var/lib/biome-Rlibs/")`; honours `BIOME_DISABLE_USER_LIB_BOOTSTRAP=1`; full `tryCatch` wrap.  | NEW    |
| `scripts/50_setup_nodes.sh` (Step 7c, end of `setup_nodes_local_rlibs`) | Added deploy-time warmup loop. Detects R `<major>.<minor>` from `R --version`; iterates `getent passwd` UID 1000–64999 with shell ≠ nologin/false and existing home; `install -d -m 0755 -o $u -g $gid` per user. Honours `ENABLE_R_LIBS_LOCAL_WARMUP` and `DRY_RUN`. Counts warmed/skipped/failed. | EDIT |
| `config/setup_nodes.vars.conf`                                       | New var `ENABLE_R_LIBS_LOCAL_WARMUP=true` (default on). `RPROFILE_VERSION="12.5"` → `"12.6"`.                                                                                                            | BUMP   |
| `scripts/99_check_user_renviron_overrides.sh`                        | (Already added pre-bump.) Audit + `--fix --commit` cleanup of stale `~/.Renviron` files rsync'd from old server. Cross-referenced from `UPGRADE_TO_v12.4.md` §10.                                        | DOC    |
| `docs/operations/UPGRADE_TO_v12.4.md` §11                            | New section pointing operators at the v12.6 layered fix; obsoletes the manual per-user `mkdir`/`chown` workflow.                                                                                        | DOC    |

DESIGN — D+A LAYERS (covers both new-deploy and runtime-discovery paths):

* **Layer A (deploy-time, eager):** `50_setup_nodes.sh` Step 7c warmup
  loop creates the dir for **every existing AD user** at the moment Step 7
  runs. Catches the "fresh node, fresh R minor bump, AD users already
  exist" case immediately; no first-login wait.
* **Layer D (runtime, lazy):** Fragment `04_user_lib_bootstrap.R`
  self-creates the dir on the **first R session** of a brand-new AD user
  who appeared *after* the last `50_setup_nodes.sh` run (or on a node
  where the operator skipped Step 7). EUID matches the user (since the
  fragment runs inside their R session under `Rprofile.site`), so plain
  `dir.create()` succeeds without setuid gymnastics.

Both layers are idempotent — re-running either is a no-op when the dir
already exists with the right owner.

SCOPE OF FRAGMENT (per user-approved choice "3 a tutti"):

* Runs in **all** R sessions: interactive **and** non-interactive
  (`Rscript`, batch jobs, `R CMD BATCH`, RStudio child processes).
  Rationale: an `Rscript` that calls `install.packages()` from cron must
  not fail just because no human ever opened an interactive session.

PATH VALIDATION (per user-approved choice "4 ok"):

```r
target <- file.path(LIB_ROOT, user, r_majmin)
if (!startsWith(normalizePath(target, mustWork=FALSE), "/var/lib/biome-Rlibs/"))
  return(invisible(NULL))   # refuse to create anything outside the contract
```

DEPLOYMENT (per node, idempotent):

```bash
cd /opt/R-studioConf && git pull
sudo bash scripts/50_setup_nodes.sh
# Selection: 7   (Step 7c — local Rlibs root + warmup loop)
# Selection: 3   (Step 8 — fragment deploy, picks up 04_user_lib_bootstrap.R)
sudo systemctl restart rstudio-server
```

OVERRIDE (forensic-only, leave default ON in production):

```bash
# Disable the runtime fragment globally for one host (e.g. read-only /var):
echo 'BIOME_DISABLE_USER_LIB_BOOTSTRAP=1' >> /etc/R/Renviron.site
# Disable the deploy-time warmup loop:
ENABLE_R_LIBS_LOCAL_WARMUP=false sudo bash scripts/50_setup_nodes.sh
```

VALIDATION:

```bash
# (a) Layer A — warmup actually ran
sudo bash scripts/50_setup_nodes.sh   # Step 7
# Expect tail: "[Step 7c] Rlibs warmup: warmed=N skipped=M failed=0"

# (b) Layer D — fragment self-creates on first session
sudo userdel -r testuser_v126 2>/dev/null; sudo useradd -m -s /bin/bash testuser_v126
sudo -u testuser_v126 Rscript -e 'cat(.libPaths(), sep="\n")'
ls -ld /var/lib/biome-Rlibs/testuser_v126/*/   # Expect: drwxr-xr-x testuser_v126 testuser_v126

# (c) install.packages() works on first try
sudo -u testuser_v126 Rscript -e 'install.packages("jsonlite", repos="https://cloud.r-project.org")'
```

ROLLBACK. Three artefacts to revert: (1) delete the fragment file, (2)
remove the warmup loop block in Step 7c (clearly delimited), (3) bump
`RPROFILE_VERSION` back to `12.5`. No data migration — directories
already created remain valid; rollback only stops *new* dirs from being
auto-created.

TIER DELTAS.

* **T1**: implemented (this entry).
* **T2 (docker)**: pending. The fragment template is tier-agnostic and
  copies into the rstudio image unchanged; the warmup loop in
  `50_setup_nodes.sh` is host-specific and must be ported to the
  rstudio container's entrypoint (or its `init.d` boot hook) since
  Docker containers don't run `50_setup_nodes.sh`.
* **T3 (k8s)**: pending. Same as T2 plus: `/var/lib/biome-Rlibs/` is a
  PVC bind mount; the per-pod init container should run the warmup
  loop against the mounted volume.

---

## v12.5 (2026-05-10) — "Minimal-profile + audit-log permission hotfix"

CONTEXT. Two latent bugs surfaced during the post-v12.4 validation pass on
`biome-calc03`:

1. **Minimal Rprofile crashed on load.** `templates/Rprofile_site.minimal.R.template`
   used `stats::setNames()` inside the irreducible-safety env-var block, but
   `Rprofile.site`/`R_PROFILE_USER` are sourced **before** base packages are
   attached — `setNames` is unbound at that moment. Result:
   `Error in setNames(list("1"), v) : could not find function "setNames"`,
   the minimal profile aborted before defining `biome_diag()`/`biome_nfs_check()`/
   `biome_fork_probe()`, and every HC-13 harness layer (L0/L1) failed in 0s.
2. **Cross-user EACCES on `/Rtmp/biome_thread_guard/guard_<host>.log`.**
   Fragments `05_thread_guard.R` and `55_options_guard.R` write an audit
   trail to a single shared logfile per host. The first user to start R
   created the dir+file with their default umask (0644 file ownership =
   that user). Every subsequent user got `cannot open file ... :
   Permission denied` (3 warnings per session) because the kernel cannot
   open a foreign-owned 0644 file in append mode.

FIX (T1, **single source of truth**, ported to T2/T3 in follow-up).

| Artefact                                                | Change                                                                                                          | Status |
|---------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------|--------|
| `templates/Rprofile_site.minimal.R.template`            | Replace `setNames(list("1"), v)` with `args <- list("1"); names(args) <- v; do.call(Sys.setenv, args)`           | NEW    |
| `templates/Rprofile_site.d/05_thread_guard.R.template`  | Per-user log file `guard_<host>_<user>.log` + `Sys.umask("000")` + `chmod 1777` on dir-create (3 call sites)    | EDIT   |
| `templates/Rprofile_site.d/55_options_guard.R.template` | Per-user log file + same umask/chmod hardening (2 call sites)                                                   | EDIT   |
| `scripts/50_setup_nodes.sh` (Step 8)                    | Pre-create `/Rtmp/biome_thread_guard` with `install -d -m 1777`; remove pre-v12.5 stale shared `guard_<host>.log` | EDIT   |
| `config/setup_nodes.vars.conf`                          | `RPROFILE_VERSION="12.5"`                                                                                       | BUMP   |
| `docs/operations/UPGRADE_TO_v12.4.md` §3.5              | Clarified: `biome_diag()` runs via `/usr/local/bin/r_minimal`, NOT `R --vanilla`; selezione **H** è OBBLIGATORIA | DOC    |

DEPLOYMENT (per node, idempotent — same procedure as v12.4 §3):

```bash
cd /opt/R-studioConf && git pull
sudo bash scripts/50_setup_nodes.sh
# Selection: 3   (Step 8 — re-deploy fragments + create /Rtmp/biome_thread_guard 1777)
# Selection: H   (Step 11f — re-deploy minimal Rprofile + harnesses)
sudo systemctl restart rstudio-server
```

ONE-SHOT REMEDIATION (zero-code, sblocca subito i nodi già su v12.4):

```bash
sudo chmod 1777 /Rtmp/biome_thread_guard
sudo rm -f /Rtmp/biome_thread_guard/*.log   # let R recreate per-user files
```

VALIDATION:

```bash
# (a) minimal profile + forensic helpers
sudo /usr/local/bin/r_minimal -e 'biome_diag(); cat("\n"); biome_nfs_check(); cat("\n"); biome_fork_probe(n=10)'
# Expect: full one-page diag, no "could not find function" errors.

# (b) no more permission warnings on R startup
sudo -u <any_AD_user> R --vanilla -e 'invisible(NULL)' 2>&1 | grep -i 'permission denied'
# Expect: empty output.

# (c) Lussu harness now runs
sudo /usr/local/bin/99_diagnose_lussu_hang.sh /path/to/user_script.R
```

ROLLBACK. v12.5 only edits 4 files — all rollbacks are file-level via the
`*.bak` backups produced by Step 8 / Step 11f. The semantic contract of
fragments 05 and 55 is unchanged (still log to `/Rtmp/biome_thread_guard/`);
older bundles remain compatible — only the FILENAMING changes (split per
user). Rolling back to v12.4 simply re-introduces the cross-user EACCES.

HARNESS HARDENING (script-only follow-up — **does NOT bump RPROFILE_VERSION**).

`scripts/99_diagnose_user_script.sh` and `scripts/99_diagnose_lussu_hang.sh`
were tagged `HARNESS_VERSION="1.1"` and patched to close three pathologies
observed when sysadmin ran the Lussu harness as `sudo` on biome-calc03:

| Patch                                | Generic harness | Lussu overlay | Effect |
|--------------------------------------|:---------------:|:-------------:|--------|
| Refuse-root guard (opt-in via `BIOME_DIAG_ALLOW_ROOT=1`) | ✅ | ✅ | No more root-owned `/Rtmp/biome_root/`, `/Rtmp/Rtmp*`, `/tmp/{user,lussu}_diag_*` blocking other users. |
| Per-user `OUT_DIR` default `/tmp/<kind>_diag_${USER}_${TS}` | ✅ | ✅ | Cross-user runs cannot collide. |
| `setsid` + EXIT/INT/TERM trap → `kill -- -$PGID` | ✅ | ✅ | Orphan `mclapply`/PSOCK workers no longer survive `timeout` (which signalled only the parent PID). |
| Default `BIOME_DIAG_TIMEOUT_S` 1200/1800 → **600**          | ✅ | ✅ | Harness completes in ~40 min worst-case instead of 80–140 min. |

Operational rules now codified in `docs/operations/UPGRADE_TO_v12.4.md` §9:
the harness MUST be invoked from a PAM session of the affected user
(`su - <user>`), never as root. The `BIOME_DIAG_ALLOW_ROOT=1` override is
documented as forensic-only (debugging the harness itself, not user code).

These edits are confined to two `.sh` files and one runbook section. They
do NOT touch any `templates/Rprofile_site*.R*` artefact and therefore do
NOT bump `RPROFILE_VERSION`. Versioning is tracked via the inline
`HARNESS_VERSION="1.1"` header comment in each script.

TIER DELTAS.

* **T1**: implemented (this entry).
* **T2 (docker)**: pending. Same fragment templates apply; Dockerfile must
  add `RUN install -d -m 1777 /Rtmp/biome_thread_guard` if the container
  pre-creates `/Rtmp`.
* **T3 (k8s)**: pending. `/Rtmp` is per-pod `emptyDir` — sticky-1777 must
  be set via `securityContext.fsGroup` + an init container, OR the
  fragment's `Sys.umask("000") + chmod 1777` fallback handles first-touch.

---

## v12.4 (2026-05-09) — "Lussu fork-guard + NFS library-lookup storm fix"

CONTEXT. Two production pathologies surfaced after v12.2 stabilised:

1. **Lussu hang.** Long-running user code that loads `terra`/`sf`/`raster`/
   `stars`/`torch`/`arrow` and then calls `parallel::mclapply()` deadlocks
   the forked rsession workers (HC-13 probe E confirmed: PSOCK swap fixes it,
   pure fork does not). Root cause: those packages register C++/OpenMP
   thread pools that are not fork-safe.
2. **NFS library-lookup storm.** `R_LIBS_USER=$HOME/R/x86_64-pc-linux-gnu-library/%v`
   sat on NFS for every session. Each `library()` call walked the NFS tree
   and choked under concurrency (visible as `lookupcache` thrash on
   TrueNAS).

ARCHITECTURE. v12.4 is a **kernel-bump + 2 new fragments + 2 idempotent
deploy steps**. No user-facing R API change. No file outside `/etc/R/` and
`/var/lib/biome-Rlibs/` is touched.

| Artefact                                       | Lines | Status   | Purpose                                                                                |
|---|---|---|---|
| `templates/Rprofile_site.d/52_mclapply_guard.R.template` ⭐ |  ~120 | NEW      | Detect heavy-thread package load → reroute `mclapply` to a PSOCK cluster. HC-13 safe. |
| `templates/Rprofile_site.d/50_pkg_hooks.R.template`        |  +30  | EXTENDED | `terraOptions(memfrac=0.5, todisk=TRUE)` default on `/Rtmp`; `BIOME_TERRA_NORAM=0` opt-out. |
| `templates/Rprofile_site.R.template`           |   +6  | BUMP     | New flags `ENABLE_FORK_TO_PSOCK`, `ENABLE_TERRA_TODISK_DEFAULT`; version → `12.4`.    |
| `templates/Renviron.template`                  |   +2  | EXTENDED | `R_LIBS_USER=/var/lib/biome-Rlibs/%u/%v:${HOME}/R/x86_64-pc-linux-gnu-library/%v`.    |

⭐ = first numeric slot in the `52_*` range; sources cleanly after
`50_pkg_hooks.R` so its detector sees already-loaded namespaces.

WHAT CHANGED:

* [S1]  NEW FRAGMENT: `52_mclapply_guard.R.template` installs a wrapper on
          `parallel::mclapply` that, when a heavy-thread package is on
          `loadedNamespaces()`, transparently substitutes a PSOCK cluster
          (`makeCluster(getOption("mc.cores"))`). User code is **not** edited
          (HC-13). Bypass: `BIOME_DISABLE_FORK_GUARD=1`.
* [S2]  EXTENDED `50_pkg_hooks.R.template`: `setHook(packageEvent("terra",...))`
          now calls `terraOptions(memfrac=0.5, todisk=TRUE, tempdir="/Rtmp/<user>")`
          on first load. Bypass: `BIOME_TERRA_NORAM=1`.
* [S3]  KERNEL BUMP: `Rprofile_site.R.template` advertises `12.4` and gates
          the new fragments behind `ENABLE_FORK_TO_PSOCK=TRUE`,
          `ENABLE_TERRA_TODISK_DEFAULT=TRUE` (defaults: on).
* [S4]  RENVIRON: `R_LIBS_USER` now uses a **double path**, local-first,
          NFS-fallback. Existing user libraries on NFS keep working; the
          first `install.packages()` after the upgrade compiles into
          `/var/lib/biome-Rlibs/<user>/<R-ver>/`. Eliminates the
          per-`library()` NFS lookup storm.
* [S5]  CONFIG: `config/setup_nodes.vars.conf` gains
          `R_LIBS_LOCAL_DEVICE`, `R_LIBS_LOCAL_ROOT`, `R_LIBS_LOCAL_FSTYPE`,
          `R_LIBS_LOCAL_SIZE_GB` (optional dedicated disk; default Mode A
          uses rootfs at `/var/lib/biome-Rlibs/`), and
          `NFS_AUDIT_REQUIRE_VERS`, `NFS_AUDIT_REQUIRE_NCONNECT`,
          `NFS_AUDIT_REQUIRE_LOOKUPCACHE` (read-only audit thresholds).
* [S6]  SCRIPT: `scripts/50_setup_nodes.sh` adds two idempotent functions:
          - `setup_nodes_local_rlibs` (Step 7c): create `/var/lib/biome-Rlibs/`
            with sticky `1777`. Mode A (rootfs only) or Mode B (`mkfs` +
            UUID-based fstab + mount on `R_LIBS_LOCAL_DEVICE`). Fails fast
            (HC-14) on chmod/permission errors.
          - `setup_nodes_audit_nfs` (Step 7d): read-only audit of every NFS
            mount for `vers ≥ 4.1`, `nconnect ≥ 4`, `lookupcache=positive`.
            **Never remounts** — surfaces gaps via `[audit] WARN`.
          Wired into menu option `1` (full deploy) and new option `L`
          (local-Rlibs + NFS audit only).
* [S7]  DOCS: end-to-end runbook
          `docs/operations/UPGRADE_TO_v12.4.md` (procedure for new and
          already-deployed nodes is identical; per-phase rollback; user
          bypass; FAQ).
* [S8]  BUNDLE INVALIDATION (interaction with v12.3 fast-path): adding
          `52_mclapply_guard.R` invalidates the byte-compiled fragment
          bundle (`/etc/R/Rprofile_site.d/.compiled/{bundle.Rc,manifest.txt}`)
          because the manifest is an md5sum-of-fragments. `50_setup_nodes.sh`
          Step 8 (NEW v12.3) rebuilds the bundle atomically (stage→`mv`).
          Without this rebuild, sessions would load the legacy loop
          (correct behavior, but slower). PSE invariant: a stale bundle
          NEVER masks a fragment change — the manifest mismatch forces
          fall-back to the per-fragment loop.

VERIFICATION:

* `bash -n scripts/50_setup_nodes.sh` PASSES.
* Lussu probe E (PSOCK swap) → previously HANG, now PASS via fork-guard.
* Lussu probe F (`terra::terraOptions(todisk=TRUE)`) → PASS via default.
* `sudo -u <ad-user> R --vanilla -e '.libPaths()'` → first entry
  `/var/lib/biome-Rlibs/<user>/<R-ver>`; second entry the legacy NFS path.
* `sudo bash scripts/50_setup_nodes.sh --verify` reports `Rprofile.site
  version: 12.4`.

ROLLBACK PATH (per-phase, see runbook §4):

```bash
# Re-install old Rprofile.site and Renviron from auto-backups
sudo cp /etc/R/Rprofile.site.bak  /etc/R/Rprofile.site
sudo cp /etc/R/Renviron.site.bak  /etc/R/Renviron.site
sudo rm  /etc/R/Rprofile_site.d/52_mclapply_guard.R   # disable fork-guard only
sudo systemctl restart rstudio-server
```

Per-user emergency bypass (no admin needed):

```bash
export BIOME_DISABLE_FORK_GUARD=1   # disable mclapply→PSOCK reroute
export BIOME_TERRA_NORAM=1          # disable terra todisk default
export R_LIBS_USER="${HOME}/R/x86_64-pc-linux-gnu-library/$(R --version | head -1 | awk '{print $3}' | cut -d. -f1-2)"
```

TIER DELTAS:

* T2 (docker): pending — to be ported when T2 is realigned to T1.
* T3 (k8s):    pending — `R_LIBS_USER` will land on `emptyDir` per-pod;
               fork-guard will ship as the same fragment via ConfigMap.

---

## v12.3 (2026-05-07) — "Byte-compiled fragment bundle fast-path"

CONTEXT. After v12.2 split the kernel into 9 fragments (~2306 LOC), every
R/RStudio cold-boot re-parsed all of them via `sys.source()` — measurable
overhead on a fleet of long-running batch sessions and on rsession
startup latency for interactive users. The fragments are essentially
read-only between deploys, so the parse work is wasted.

ARCHITECTURE. v12.3 adds an **opt-out byte-compiled bundle fast-path**.
At deploy time, `50_setup_nodes.sh` Step 8 walks every
`/etc/R/Rprofile_site.d/*.R`, calls `compiler::cmpfile(optimize = 3L)`
on a concatenation, and writes:

```
/etc/R/Rprofile_site.d/.compiled/
  ├── bundle.Rc        # byte-compiled artefact (loaded via lazyLoad-style)
  └── manifest.txt     # md5sum  basename, lexically sorted, one per line
```

At session start, the dispatcher (`templates/Rprofile_site.R.template`,
FRAGMENT LOADER v12.3, ~L753+) does:

1. `ENABLE_FRAG_BUNDLE` (compile-time TRUE) AND `Sys.getenv("BIOME_DISABLE_BUNDLE") != "1"` ?
2. Read `manifest.txt`, recompute md5sum of every `.R` fragment on disk,
   compare line-by-line.
3. **Match** → load `bundle.Rc` once → done. Per-fragment `tryCatch`
   isolation is preserved by the bundling order.
4. **Mismatch** (any fragment hash differs, or new/missing fragment) →
   **fall back to the legacy `sys.source()` per-fragment loop**.

PSE invariant: the legacy loop is **ground truth**. A stale or corrupt
bundle is impossible to mask — the manifest mismatch always demotes to
the safe path. The fast-path is purely a perf optimisation.

ATOMIC INSTALL. `50_setup_nodes.sh` builds the bundle into a `mktemp -d`
staging dir, then `mv -T` swaps `.compiled/` into place. A half-written
bundle never reaches the live tree. After the swap, the script does
`cat .compiled/bundle.Rc > /dev/null` to warm the page cache (so the
first session benefits without the I/O hit).

GATES (in priority order):

| Knob                            | Default | Purpose                                       |
|---|---|---|
| `ENABLE_FRAG_BUNDLE` (R const)  | `TRUE`  | Compile-time off-switch in dispatcher header. |
| `BIOME_DISABLE_BUNDLE=1` (env)  | unset   | Per-session opt-out (debugging stale state).  |
| `manifest.txt` mismatch         | n/a     | Automatic, silent fall-back to legacy loop.   |

ADDITIVE FRAGMENTS (shipped alongside v12.3):

* `05_thread_guard.R.template` — wraps `parallel::detectCores()` to
    return the cgroup-derived `MAX_THREADS` cap; prevents BLAS/OMP
    over-subscription when user code calls `detectCores()` directly.
* `55_options_guard.R.template` — clamps `options(mc.cores = ...)`
    on every set, so a forgotten `options(mc.cores = 64)` at the top
    of a user script can never escape the cgroup limit.
* `60_safe_setwd.R.template` — split into asymmetric behaviour:
    **batch (`Rscript`/`R --no-save`)** = hard-fail on bad `setwd`
    (Martina-gate fix preserved); **interactive (RStudio)** = warn
    and continue (botanists routinely paste `setwd("...")` lines).
* Section -1.5 of the dispatcher now **reuses** `.biome_blas_cache`
    across sessions for the same user, avoiding the BLAS coretype probe
    on every cold boot.

WHAT CHANGED:

* [B1]  NEW DIRECTORY: `/etc/R/Rprofile_site.d/.compiled/` (created at
          deploy time by `50_setup_nodes.sh` Step 8). Owned `root:root`,
          mode `0755`; bundle file `0644`.
* [B2]  NEW DISPATCHER SECTION: FRAGMENT LOADER v12.3 (replaces the v12.2
          loop). ~70 lines. Computes md5 hashes via R-native digest of
          file bytes; reads manifest with `readLines()`; compares as a
          `setequal()` over `paste(hash, basename)` rows.
* [B3]  NEW DEPLOY STEP: `setup_nodes_compile_bundle()` in
          `scripts/50_setup_nodes.sh` (Step 8 of the menu). Builds
          `bundle.Rc` + `manifest.txt` in a staging tmpdir, atomic
          `mv -T`, then page-cache warm-up via `cat > /dev/null`.
* [B4]  NEW FRAGMENTS: `05_thread_guard.R`, `55_options_guard.R`.
          `60_safe_setwd.R` extended with batch/interactive split.
* [B5]  DISPATCHER: `.biome_blas_cache` reuse logic added in Section
          -1.5; cache key = `paste(user, R.version.string, blas_kind)`.
* [B6]  KERNEL BUMP: `Rprofile_site.R.template` advertises `12.3` and
          adds `ENABLE_FRAG_BUNDLE` flag (default `TRUE`).
* [B7]  CONFIG bump: `config/setup_nodes.vars.conf` →
          `RPROFILE_VERSION="12.3"`.

VERIFICATION:

* `Rscript --vanilla -e 'parse(file=...)'` PASSES for every fragment.
* `bash -n scripts/50_setup_nodes.sh` PASSES.
* Cold-boot R session timing (heavy fragment chain, 9 fragments):
  legacy loop ≈ 280–340 ms; bundle fast-path ≈ 35–55 ms (~6× faster);
  fall-back path identical to v12.2 (regression-free).
* Tampering test: edit one byte of any `.R` fragment in place → next
  session falls back to legacy loop, logs `[frag-bundle] manifest
  mismatch on <name>` to `sys_log`. No silent staleness.
* `ls /etc/R/Rprofile_site.d/.compiled/` shows `bundle.Rc` and
  `manifest.txt`; `wc -l manifest.txt` equals fragment count.

ROLLBACK PATH (per-knob):

```bash
# Disable fast-path globally for this host (one session):
sudo rm -rf /etc/R/Rprofile_site.d/.compiled
sudo systemctl restart rstudio-server   # next session uses legacy loop

# Per-user, per-session bypass (no admin needed):
export BIOME_DISABLE_BUNDLE=1
R    # legacy sys.source() loop, identical to v12.2

# Hard kernel revert (fall back to v12.2 dispatcher):
sed -i 's/RPROFILE_VERSION="12.3"/RPROFILE_VERSION="12.2"/' \
   config/setup_nodes.vars.conf
sudo bash scripts/50_setup_nodes.sh --step config_files
sudo rm -rf /etc/R/Rprofile_site.d/.compiled
```

The `.compiled/` directory is **derived state**. Removing it at any
time is safe; it will be re-built on the next `50_setup_nodes.sh` run.

INTERACTION WITH v12.4 (forward-pointer): adding a new fragment (e.g.
`52_mclapply_guard.R` in v12.4) invalidates the manifest. v12.4 deploy
re-runs Step 8, rebuilding the bundle atomically. A pre-v12.4 bundle on
a v12.4 fragment tree therefore demotes to the legacy loop until the
rebuild completes — never masks the new fragment.

TIER DELTAS:

* T2 (docker): pending — bundle build will move to image build time
                (read-only `/etc/R/Rprofile_site.d/.compiled/` baked into
                the layer).
* T3 (k8s):    pending — same as T2; ConfigMap-projected `.compiled/`
                directory is acceptable since it is regeneratable.

---

## v12.2 (2026-05-04) — "Hybrid-C thin dispatcher + full kernel split"

CONTEXT. v12.1 shipped a 2536-line monolith with an additive fragment dir
containing only 3 opt-in fragments (`35_compile_routing`, `60_safe_setwd`,
`80_tools_ext`). This worked but left the kernel unmodular: every change to
cgroup logic, PSOCK factory, memory guards, or package hooks required editing
a single giant file. v12.2 completes the modularization without changing
runtime semantics.

ARCHITECTURE. The `Rprofile_site.R.template` monolith is split along PSE-safe
lines:

* **Dispatcher** (`templates/Rprofile_site.R.template`, 693 lines) keeps only
  the safety-critical bootstrap that cannot tolerate fragment-deletion:
  integrity self-check, `.biome_early_err`, OpenBLAS coretype detection,
  user-tmp-root setup, BLAS serial/pthread SIGSEGV guard, PSOCK worker
  fast-path (half of an `if/else`, not fragmentable), `bspm` pre-load,
  `.biome_skip_main` idempotency guard, and the main `local({...})` opener
  through feature flags, `.biome_env` bootstrap, `sys_log`,
  `.biome_mark_time`, session timeout, library paths, and Smart Cleanup.

* **Fragments** (`templates/Rprofile_site.d/*.R.template`, 9 files, 2306
  total LOC) are sourced via `sys.source(envir = environment())` inside the
  dispatcher's main `local({...})` frame — so they inherit the closure
  (`sys_log`, `.biome_env`, `ENABLE_*`, `.C_*`, `VERSION`, `curr_user`,
  `USER_TMP_ROOT`, `MAX_THREADS`). Zero code was rewritten: fragments are
  mechanical `sed` slices of the v12.1 monolith body, line-for-line.

STRATEGY. Three approaches were considered:

* (A) STRICT split — promote every shared local to `.biome_env$*` and
        rewrite every reference. High risk, ~6-8h work.
* (B) PRAGMATIC — one `local({...})` wrapper, fragments sourced inside
        with `local=TRUE`. Chosen for lexical inheritance.
* (C) HYBRID — chosen. Two-pass loader (early at global scope, late inside
        `local`). In practice only the late pass was needed because every
        fragmentable region lives inside the main `local`. Worker fast-path
        and `bspm` stayed in the dispatcher per user request.

FRAGMENT INVENTORY (lexical load order):

| Fragment                           | Lines | Source range (v12.1) | Purpose                                                     |
|------------------------------------|-------|----------------------|-------------------------------------------------------------|
| `20_cgroup_reader.R.template`      |  272  | 592–855              | cgroup v1/v2 limit detection + `setup_adaptive_callback`    |
| `30_psock_factory.R.template`      |  103  | 857–951              | `.biome_make_cluster_impl` + `biome_make_cluster` + stash    |
| `35_compile_routing.R.template` ⭐  |  184  | (v12.1 additive)     | `BIOME_RUN_ID`, `.biome_get_compile_dir`, `safe_compileNimble` |
| `40_wrapper_installer.R.template`  |   84  | 952–1027             | `.biome_install_wrapper` (lexical-scope-preserving)         |
| `45_memory_guards.R.template`      |  229  | 1028–1248            | solve/dist/outer/expand.grid/safe_makeCluster guards        |
| `50_pkg_hooks.R.template`          |  581  | 1249–1821            | DEFERRED PACKAGE HOOKS (terra/raster/sf/nimble/stan/...)    |
| `60_safe_setwd.R.template` ⭐       |   67  | (v12.1 additive)     | `base::setwd` hard-fail guard (Martina-gate fix)            |
| `70_persistent_tools.R.template`   |  683  | 1822–2496            | `tools:biome_calc`, `biome_cluster_test`, diag dump, finalize |
| `80_tools_ext.R.template` ⭐        |  103  | (v12.1 additive)     | `biome_tmb_compile`, `biome_run_diagnostics`                |

⭐ = originated in v12.1 as opt-in fragments, unchanged in v12.2.

FRAGMENT FAILURE ISOLATION. Each fragment is wrapped in the dispatcher's
`tryCatch` at source-time. On parse or eval error: one line appended to
`/tmp/biome_frag_errors_<pid>.log`, `sys_log` entry with status `FAIL`,
next fragment still runs. Session NEVER aborts. This preserves PSE
fail-safe invariant 10 ("deploy scripts exit 1 on permission failure"
does not apply here — runtime fragment load is best-effort by design).

WHAT CHANGED:

* [S1]  NEW FILE: `templates/Rprofile_site.R.template` rewritten as thin
          dispatcher (693 lines). Preserves every early-scope section 1:1
          from v12.1 (SECTION 0 / -2 / -1.8 / -1.5 / -1, bspm pre-load,
          `.biome_skip_main` guard, main `local` opener through
          `cgroups_init` timer mark). Replaces lines 592–2502 (~1910 lines
          of body) with a 75-line fragment loader.
* [S2]  NEW FILE: `templates/Rprofile_site.R.template.legacy_v12.1_rollback`
          — byte-identical copy of the v12.1 monolith. Rollback path:
          `cp legacy_v12.1_rollback Rprofile_site.R.template && rm
           templates/Rprofile_site.d/{20,30,40,45,50,70}_*.R.template`.
* [S3]  NEW FILES: 6 new fragments mechanically sliced from the monolith:
          `20_cgroup_reader`, `30_psock_factory`, `40_wrapper_installer`,
          `45_memory_guards`, `50_pkg_hooks`, `70_persistent_tools`.
* [S4]  DISPATCHER loader uses `sys.source(envir = environment())`
          explicitly (NOT `source(..., local=TRUE)`) because the latter's
          `parent.frame()` resolution is fragile when called from inside
          a `for` loop inside a `tryCatch` — `sys.source` with an explicit
          env argument is deterministic.
* [S5]  CONFIG bump: `config/setup_nodes.vars.conf` → `RPROFILE_VERSION="12.2"`.
* [S6]  `scripts/50_setup_nodes.sh` required NO changes: the existing
          `setup_nodes_config_files()` already deploys every
          `templates/Rprofile_site.d/*.R.template` via glob and runs
          per-fragment `Rscript --vanilla -e 'parse(file=...)'` checks.
          Verified: `bash -n scripts/50_setup_nodes.sh` = OK.
* [S7]  HEADER comment block in dispatcher updated to describe v12.2
          Hybrid-C architecture and list the 9-fragment inventory.

CROSS-FRAGMENT DEPENDENCIES (load order matters):

* `30_psock_factory` MUST load before `45_memory_guards` — the latter's
    `safe_makeCluster` auto-route path reads `.biome_env$.biome_make_cluster_impl`
    stashed by the former.
* `40_wrapper_installer` MUST load before `45_memory_guards` and
    `50_pkg_hooks` — both use `.biome_install_wrapper`.
* `35_compile_routing` MUST load before `50_pkg_hooks` — the latter's
    NIMBLE hook expects `safe_compileNimble` to exist for monkey-patch install.
* `70_persistent_tools` MUST load before `80_tools_ext` — the latter
    attaches helpers to `tools:biome_calc` which the former creates.

Lexical `[0-9]{2}_` prefix ordering satisfies all of the above.

VERIFICATION:

* `parse(file=...)` PASSES for dispatcher + all 9 fragments (after `%%VAR%%` → `0` substitution).
* `bash -n scripts/50_setup_nodes.sh` PASSES.
* Fragment total LOC (2306) + dispatcher (693) = 2999 lines vs v12.1 monolith (2536) + loader-stub (30) = 2566 lines. Δ +433 lines is per-fragment header comments (inventory banner, deploy path, inherited closure docs, source line-range provenance).
* Sandbox validation DEFERRED — sandbox marked KNOWN BROKEN in `.clinerules`; smoke-test against user/researcher env (Martina's `Mod7_sq_diff_DEBUG_test.R`) is the acceptance test.

ROLLBACK PATH (if v12.2 breaks production):

  ```bash
  cd /home/jfs/00_Antigravity_workspace/R-studioConf
  cp templates/Rprofile_site.R.template.legacy_v12.1_rollback \
     templates/Rprofile_site.R.template
  rm templates/Rprofile_site.d/{20,30,40,45,50,70}_*.R.template
  # keep 35_, 60_, 80_ (v12.1 additive, independently rollback-able)
  sed -i 's/RPROFILE_VERSION="12.2"/RPROFILE_VERSION="12.1"/' \
     config/setup_nodes.vars.conf
  sudo bash scripts/50_setup_nodes.sh --step config_files
  ```

---

%%BIOME_HOST%% SYSTEM PROFILE v%%RPROFILE_VERSION%% — LOCAL-DISK ARCHITECTURE
VM:      QEMU on Proxmox 9.x (Ceph), x86-64-v4 CPU, %%VM_VCORES%% vCores, ~%%VM_RAM_GB%%GB RAM
System:  Ubuntu 24.04, R 4.5.x, bspm enabled
BLAS:    openblas-serial (safe with rsession pthreads — rstudio/rstudio#7031)
OpenMP:  libgomp (capped by OMP_NUM_THREADS, coordinated per-user)
Contact: %%BIOME_CONTACT%%

v12.0 CHANGES (from v11.4) — "cgroup fair-share enforcement: remove R-level user-counting":
  Context: 50_setup_nodes.sh now deploys systemd cgroup v2 slice limits via
  setup_nodes_cgroups() (Step 11A). Kernel enforces per-user memory and CPU
  scheduling at the slice level — R-level user counting was a best-effort
  approximation that is now redundant and misleading.

  WHAT CHANGED:

* [C1]  REMOVED: get_active_users() — /proc-scanning to count R processes.
          The kernel's CPUWeight=100 on user-.slice enforces proportional CPU
          fair-share automatically. Counting pids was both unreliable
          (Rscript/future workers inflate count) and unnecessary.
* [C2]  REMOVED: per-user RAM division in update_resources().
          quota = ram_gb / n_procs → now quota = ram_gb * 0.9.
          MemoryHigh/MemoryMax on user slice is the real enforcement boundary.
* [C3]  REMOVED: fair_cores = eff_vc / n_procs division.
          CPUWeight handles scheduler fairness. fair_cores now reflects the
          full cgroup-capped vcore count; bt = min(fair_cores, MAX_THREADS)
          still prevents BLAS livelock (CPUWeight != thread count cap).
* [C4]  REMOVED: BIOME-RESCALE notification box.
          Was triggered by n_procs change; kernel throttles silently now.
* [C5]  REMOVED: ENABLE_RESOURCE_MGMT flag — only gated removed logic.
          Thread management (OMP/BLAS/MKL) is now under ENABLE_BLAS_MGMT.
* [C6]  FIXED:  ENABLE_CGROUP_AWARE path bug — previous code read
          /sys/fs/cgroup/memory.max (root cgroup, always "max"). User slice
          limits live at user.slice/user-<uid>.slice/. MY_UID is resolved
          before this block runs (Section: Portable UID).
* [C7]  UPDATED: status() and startup banner reflect cgroup enforcement.
* [C8]  API_VERSION bumped 10↑11.
  NOTE: biome_cgroup_verify() and .biome_cgroup_read_limits() preserved from v11.4.

v11.4 CHANGES (from v11.3) — "Lexical Scope Restoration":
  Discovery: v11.3 .biome_install_wrapper() set environment(fn) <- ns_env
  to make safe_makeCluster's default `type = getClusterOption("type")`
  resolve. This worked for that ONE case but broke every OTHER wrapper.
  Root cause: overwriting environment(fn) severs the closure's lexical
  scope chain. Wrappers like safe_expand_grid, safe_solve, safe_dist all
  reference `.biome_env` (saved originals, .get_ram_gb, blas_is_serial).
  After environment(fn) <- baseenv(), these lookups now search
  baseenv → emptyenv → FAIL. Result: first wrapper call crashes the
  session (reproducibly: library(ggplot2) triggers expand.grid load).

  VERIFIED FAILURE MODE (reproducible in Rscript):
    > library(ggplot2)
    Error in expand.grid(...): object '.biome_env' not found

  Fix strategy (different from v11.3):

* REVERT: .biome_install_wrapper NO LONGER writes environment(fn) <- ns_env.
            Closures keep their original lexical scope (the local() frame).
* TARGETED: safe_makeCluster uses parallel:::getClusterOption("type") as
              explicit default — triple-colon bypasses scoping entirely, no
              namespace tricks needed.
* KEEP:     was_locked state preservation, install/fail logging, centralized
              helper structure — those were genuine improvements.

  CHANGES:

* [L1]  REVERTED: environment(fn) <- ns_env removed from
                    .biome_install_wrapper (was v11.3 [W1] part 1).
* [L2]  FIXED:    safe_makeCluster default arg is now
                    `type = parallel:::getClusterOption("type")` — triple-
                    colon resolves directly against parallel namespace, no
                    closure-env hacking needed.
* [L3]  KEPT:     All other v11.3 improvements survive (was_locked
                    preservation, sys_log coverage, smart_io split with
                    captured .ref, parallelly requireNamespace guard,
                    safe_dist formals restore, phantom dir cleanup, etc.).
* [L4]  API_VERSION bumped 9→10 to signal the scope contract fix.

v11.3 CHANGES (from v11.2) — "Close the wrapper class-of-bug + PSE hardening":
  Discovery: production crash on biome-calc04 (2026-04-24) —
    Error in getClusterOption("type") : could not find function "getClusterOption"
  Root cause: safe_makeCluster default `type = getClusterOption("type")` failed
    at call time. assign(fn, envir=asNamespace("parallel")) does NOT change the
    closure's enclosing environment, so lookup of non-exported `getClusterOption`
    fell back to globalenv+baseenv → not found → crash on every makeCluster(N, ...)
    without explicit type=. Confirmed: the safeguard killed every PSOCK cluster
    created with bare makeCluster(), the exact opposite of its intent.

  CHANGES:

* [W1]  ADDED:   .biome_install_wrapper() — single helper for installing
                   namespace-binding wrappers. Sets environment(fn) <- ns_env
                   so default args resolving to non-exported symbols work.
                   Preserves original binding lock state (was_locked save/restore)
                   — fixes silent "cannot change value of locked binding" errors
                   when other packages try to patch same bindings later.
                   Logs every install/skip/fail via sys_log for post-mortem.
* [W2]  FIXED:   safe_makeCluster — now uses .biome_install_wrapper; default
                   `getClusterOption("type")` resolves against parallel ns.
                   Observed in prod: makeCluster(4, outfile=...) now works.
* [W3]  FIXED:   safe_dist — restored full formal args (method, diag, upper, p)
                   so tab completion, introspection, lintr, and positional
                   calls all work. Also delegates explicitly (no ... splat).
* [W4]  FIXED:   safe_distm — added `...` passthrough for forward compat
                   with future geosphere releases.
* [W5]  FIXED:   All safe_* wrappers migrated to .biome_install_wrapper —
                   was_locked state preserved; no more unconditional lockBinding.
* [W6]  FIXED:   Smart I/O — split .biome_smart_io into two dedicated wrappers
                   (.biome_smart_read_csv for utils::read.csv,
                    .biome_smart_fread  for data.table::fread). Each captures
                   its original via closure (not namespace lookup) so infinite
                   recursion is impossible even if .biome_env is cleared.
                   fread wrapper now matches real signature (input,file,text,cmd).
* [W7]  FIXED:   .biome_make_cluster_impl — requireNamespace("parallelly")
                   guard with explicit stop() message. No more silent fail in
                   minimal environments.
* [W8]  FIXED:   Section -1.8 — removed pre-creation of nimble_compile/
                   tmb_compile subdirs (phantom per v11.2 H1-H8). Not exported
                   to worker env anymore. Renamed comment: escape hatch docs.
* [W9]  FIXED:   Stan hook — separate flags per package (.cmdstanr_hook_done,
                   .brms_hook_done, .rstan_hook_done). Enables late-loading
                   packages to still pick up their routing.
* [W10] FIXED:   addTaskCallback fallback now covers non-RStudio Rscript —
                   if callback registration fails AND we're not in RStudio,
                   run init/hooks immediately so guards are still installed.
* [W11] FIXED:   get_active_users — counts Rscript and bare R too, not just
                   rsession. Future::multisession and callr-spawned processes
                   now counted correctly in fair-share computation.
* [W12] DOCUMENTED: solve/dist/outer wrappers are bypassed by S4 dispatch
                   (e.g., Matrix::solve on dgCMatrix). Added warning in header
                   of each guard so future maintainers know the scope.
* [W13] API_VERSION bumped 8→9 to signal contract change (new helper + fixes).

Key design principles (v11.0):

* CORETYPE auto-detected from CPU vendor on EVERY session start (migration-safe)
* NO static CORETYPE, OMP, or BLAS thread counts in env files
* Boot-time detection: biome-detect-coretype.service (systemd oneshot)
* Per-session detection: this profile (handles live migration without reboot)
* Thread cap: %%MAX_BLAS_THREADS%% max to prevent QEMU livelock + BLAS oversubscription
* PESSIMISTIC SYSTEM ENGINEERING: assume failure at every layer, fail fast

ARCHITECTURE (v11.0 — LOCAL-DISK FOR ALL SCRATCH):
  /Rtmp = dedicated 400GB local ext4 disk per VM (NOT tmpfs, NOT NFS, NOT OS /tmp)
  NFS   = user homes (/nfs/home/<user>) — FINAL results, saved RData, R libraries
  Each VM has its own /Rtmp → no cross-server tmp interference, no NFS cache hell

  EVERYTHING transient goes to /Rtmp/biome_<user>/<pkg>/:
    - NIMBLE compile artifacts  (was NFS in v10.0 — FIXED)
    - TMB compile artifacts
    - Rcpp/sourceCpp compile temp
    - Stan/rstan/cmdstanr output/compile
    - terra/raster/stars/gdal temp rasters
    - ncdf4/climate4R temp datasets
    - keras/tensorflow cache + XLA tmpdir
    - ggplot/ragg font cache + plot cache
    - PSOCK cluster worker logs
    - future plan cluster scratch
    - R native tempdir() — inherited from TMPDIR=/Rtmp

  NFS home keeps ONLY:
    - ~/R/x86_64-pc-linux-gnu-library/4.5/  (persistent user packages)
    - biome_save_session() RData backups
    - User scripts, datasets, results

v11.2 CHANGES (from v11.1) — "The honest cleanup" — REMOVE PHANTOM APIs:
  Discovery: v11.0/v11.1 targeted routing APIs that DO NOT EXIST.
  Verified empirically (2026-04-22) by grepping the upstream source repos:
    *options("nimble.dirName")       — NIMBLE never reads this option.
                                         Only NIMBLE getOption call is for
                                         "nimble.Makevars.file". Compile dir
                                         is controlled via `dirName` ARGUMENT
                                         to compileNimble() or, when NULL,
                                         defaults to file.path(tempdir(),
                                         "nimble_generatedCode").
    * Sys.setenv("TMB_COMPILE_DIR")   — TMB never reads this env var.
    *options("rstan.auto_write")     — rstan uses its OWN option storage via
                                         rstan_options("auto_write"), NOT
                                         base::options().
    * Sys.setenv("STAN_TMPDIR")       — Stan never reads this env var.

  Verified as REAL and kept in v11.2:
    *options("cmdstanr_output_dir")  — cmdstanr/R/options.R:27
    * options("brms.file_refit")      — brms/R/brm.R:469

  PSOCK NIMBLE ISOLATION — NATURAL, not engineered:
    Each PSOCK worker is a separate R process with its own tempdir()
    (R creates /Rtmp/RtmpXXXXXX on startup, driven by TMPDIR=/Rtmp from
    Renviron.site). NIMBLE's default compile dir is tempdir()/nimble_generatedCode.
    So each worker already compiles to a unique path on local disk with
    ZERO configuration required. Confirmed via clusterEvalQ showing 4
    unique tempdirs on /Rtmp/ for 4 workers.

  MARTINA-GATE — Original "NIMBLE race on NFS" crash was a misdiagnosis:
    The error `unserialize(node$con) : error reading from connection` in
    Martina's script was caused by `setwd("BECAUSE")` (an unsubstituted
    TODO placeholder) failing → cascading errors → `data_mod` never created
    in master → parLapply's serialize() throws on undefined symbol → socket
    closed → next recv fails with unserialize error. NIMBLE was not involved.

  CHANGES:

* [H1]  REMOVED: options(nimble.dirName = ...) in worker fast-path (phantom)
* [H2]  REMOVED: setHook(packageEvent("nimble", "onLoad"), ...) (phantom target)
* [H3]  REMOVED: setHook(packageEvent("nimbleHMC", "onLoad"), ...) (phantom)
* [H4]  REMOVED: Sys.setenv(TMB_COMPILE_DIR = ...) in worker fast-path (phantom)
* [H5]  REMOVED: setHook for TMB/glmmTMB (phantom target)
* [H6]  REMOVED: options(rstan.auto_write = ...) (phantom)
* [H7]  REMOVED: Sys.setenv(STAN_TMPDIR = ...) (phantom)
* [H8]  REMOVED: Per-worker subdir creation in BIOME_NIMBLE_DIR / BIOME_TMB_DIR
                   (cargo cult — NIMBLE uses tempdir() per worker, not these dirs)
* [H9]  KEPT:    options(cmdstanr_output_dir = worker_sd) for Stan output
                   routing — but only if BIOME_STAN_DIR is set (real API)
* [H10] KEPT:    options(brms.file_refit = "on_change") — real API
* [H11] KEPT:    BLAS thread capping via Sys.setenv (OMP_NUM_THREADS etc.) — real
* [H12] KEPT:    BIOME env var propagation via biome_make_cluster() — real
* [H13] KEPT:    cluster_logs outfile routing — real and useful
* [H14] ADDED:   Optional worker diagnostic log (BIOME_WORKER_DEBUG=1) writes
                   /tmp/biome_worker_<pid>.log to trace fast-path execution.
                   For use if a future mystery arises; no-op by default.
* [H15] API_VERSION bumped 7→8 to signal contract change (phantom APIs removed).

v11.1 CHANGES (from v11.0) — SUPERSEDED BY v11.2: attempted setHook fix for
  phantom API options(nimble.dirName). Since the option itself doesn't exist,
  the setHook approach was academic. Kept here for historical record:

* [F1]  Root cause observed in production (biome-calc04, R 4.5.3, 2026-04-22):
          Worker fast-path at Rprofile load creates worker_<pid>/ dirs correctly
          and BLAS env vars propagate, BUT options(nimble.dirName = worker_nd)
          does NOT persist — getOption("nimble.dirName") returns NULL in
          clusterEvalQ. Package-namespaced options set during Rprofile.site
          sourcing appear to be lost when the worker transitions to the
          parallel:::.slaveRSOCK() serve loop. Plain options (e.g.
          "biome.profile.loaded") survive; only package-dotted names are lost.
          Not fully understood; possibly related to the way Rscript handles
          the site profile vs the slave bootstrap expression.
* [F2]  FIX: register setHook(packageEvent("nimble", "onLoad"), ...) in the
          worker fast-path. Hook fires at require(nimble) / library(nimble)
          time — exactly when options(nimble.dirName) actually matters for
          compileNimble() routing. Hook closure captures worker_nd; safe
          across worker lifetime. Applied symmetrically to nimbleHMC.
* [F3]  Same setHook pattern applied to TMB/glmmTMB (env var TMB_COMPILE_DIR)
          and rstan/cmdstanr/brms (mixed options + STAN_TMPDIR). Belt-and-
          suspenders: also keep the original options()/Sys.setenv() calls in
          case either persists — harmless if redundant, saves you if one path
          gets broken by future R or package changes.
* [F4]  API_VERSION bumped 6→7 to signal the contract change.

* [N1]  NIMBLE compilation moved NFS→/Rtmp local disk (per-PID worker subdirs)
          Reason: acregmin=60,acdirmin=60 on NFS causes directory-cache races
          during concurrent compileNimble() in multi-chain MCMC via parLapply.
          Symptom: unserialize(node$con) worker death mid-chain. See rstudio#7031.
* [N2]  PSOCK fast-path receives BIOME_NIMBLE_DIR + BIOME_TMB_DIR env vars
          and creates worker_<pid> subdirs → zero parent-dir contention.
* [N3]  biome_make_cluster() propagates all /Rtmp routing env vars to workers
          and accepts outfile= argument (default: /Rtmp/.../cluster_logs/).
          Outfile captures worker stderr for post-mortem when a worker dies.
* [N4]  parallel::makeCluster() safeguard — warns + redirects to
          biome_make_cluster(). Educates users away from unsafe patterns.
* [N5]  doSNOW::registerDoSNOW() safeguard (symmetric to doParallel).
* [N6]  Rcpp/sourceCpp compile temp routed via TMPDIR (no new option needed,
          but documented — Rcpp uses tempdir() which inherits from Renviron).
* [N7]  rstan/cmdstanr/brms auto-config — if loaded, set output_dir and
          cache dirs to /Rtmp. Thread cap for stan_sampling.
* [N8]  BRISC / spNNGP / ranger — OMP thread cap for packages using libgomp
          directly (not BLAS). Set n.omp.threads option on load.
* [N9]  New tool: biome_future_plan() — helper that picks plan() based on
          workload. callr for compile-heavy (NIMBLE/Stan), cluster for I/O.
* [N10] New tool: biome_worker_diagnostics() — reads cluster_logs/ and shows
          last N crashes, quickly locates the worker that died mid-chain.
* [N11] Dynamic rJava heap — replaces hardcoded -Xmx4g (uses user's quota).
* [N12] parallel::mcmapply / pvec / mclapply warnings for NFS-bound users.
* [N13] R_USER_CACHE_DIR kept on NFS (persistent package install cache)
          but TMPDIR + per-pkg scratch dirs on /Rtmp (fast, ephemeral).
* [N14] brms::make_stancode + rstan::sampling cores arg capped at MAX_THREADS.

v10.0 CHANGES (from v9.8) — Local /Rtmp Disk Architecture:

* [T1]  Replaced 100GB RAM tmpfs with dedicated 400GB local disk at /Rtmp
* [T2]  Removed tmpfs→NFS split-brain routing
* [T3]  Removed NFS fallback
* [T4]  All per-package temp dirs use local /Rtmp/biome_<user>/<pkg>
* [T5]  RAMDISK_GB=0 (no RAM consumed by /Rtmp)
* [T7]  API_VERSION bumped 4→5

v9.8 CHANGES (from v9.7) — OpenBLAS Serial Safety:

* [B1]  SECTION -1.5: BLAS serial/pthread safety check at profile load
* [B2]  .biome_env$blas_is_serial: pessimistic flag
