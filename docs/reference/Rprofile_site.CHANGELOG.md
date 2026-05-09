# Rprofile_site.R — CHANGELOG

Historical changelog for `templates/Rprofile_site.R.template`. Extracted from
the monolithic header during the v12.1 modularization (2026-04-25).

See `templates/Rprofile_site.R.template` header for the current architecture,
and `templates/Rprofile_site.d/` for feature fragments.

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

- [S1]  NEW FRAGMENT: `52_mclapply_guard.R.template` installs a wrapper on
          `parallel::mclapply` that, when a heavy-thread package is on
          `loadedNamespaces()`, transparently substitutes a PSOCK cluster
          (`makeCluster(getOption("mc.cores"))`). User code is **not** edited
          (HC-13). Bypass: `BIOME_DISABLE_FORK_GUARD=1`.
- [S2]  EXTENDED `50_pkg_hooks.R.template`: `setHook(packageEvent("terra",...))`
          now calls `terraOptions(memfrac=0.5, todisk=TRUE, tempdir="/Rtmp/<user>")`
          on first load. Bypass: `BIOME_TERRA_NORAM=1`.
- [S3]  KERNEL BUMP: `Rprofile_site.R.template` advertises `12.4` and gates
          the new fragments behind `ENABLE_FORK_TO_PSOCK=TRUE`,
          `ENABLE_TERRA_TODISK_DEFAULT=TRUE` (defaults: on).
- [S4]  RENVIRON: `R_LIBS_USER` now uses a **double path**, local-first,
          NFS-fallback. Existing user libraries on NFS keep working; the
          first `install.packages()` after the upgrade compiles into
          `/var/lib/biome-Rlibs/<user>/<R-ver>/`. Eliminates the
          per-`library()` NFS lookup storm.
- [S5]  CONFIG: `config/setup_nodes.vars.conf` gains
          `R_LIBS_LOCAL_DEVICE`, `R_LIBS_LOCAL_ROOT`, `R_LIBS_LOCAL_FSTYPE`,
          `R_LIBS_LOCAL_SIZE_GB` (optional dedicated disk; default Mode A
          uses rootfs at `/var/lib/biome-Rlibs/`), and
          `NFS_AUDIT_REQUIRE_VERS`, `NFS_AUDIT_REQUIRE_NCONNECT`,
          `NFS_AUDIT_REQUIRE_LOOKUPCACHE` (read-only audit thresholds).
- [S6]  SCRIPT: `scripts/50_setup_nodes.sh` adds two idempotent functions:
          - `setup_nodes_local_rlibs` (Step 7c): create `/var/lib/biome-Rlibs/`
            with sticky `1777`. Mode A (rootfs only) or Mode B (`mkfs` +
            UUID-based fstab + mount on `R_LIBS_LOCAL_DEVICE`). Fails fast
            (HC-14) on chmod/permission errors.
          - `setup_nodes_audit_nfs` (Step 7d): read-only audit of every NFS
            mount for `vers ≥ 4.1`, `nconnect ≥ 4`, `lookupcache=positive`.
            **Never remounts** — surfaces gaps via `[audit] WARN`.
          Wired into menu option `1` (full deploy) and new option `L`
          (local-Rlibs + NFS audit only).
- [S7]  DOCS: end-to-end runbook
          `docs/operations/UPGRADE_TO_v12.4.md` (procedure for new and
          already-deployed nodes is identical; per-phase rollback; user
          bypass; FAQ).
- [S8]  BUNDLE INVALIDATION (interaction with v12.3 fast-path): adding
          `52_mclapply_guard.R` invalidates the byte-compiled fragment
          bundle (`/etc/R/Rprofile_site.d/.compiled/{bundle.Rc,manifest.txt}`)
          because the manifest is an md5sum-of-fragments. `50_setup_nodes.sh`
          Step 8 (NEW v12.3) rebuilds the bundle atomically (stage→`mv`).
          Without this rebuild, sessions would load the legacy loop
          (correct behavior, but slower). PSE invariant: a stale bundle
          NEVER masks a fragment change — the manifest mismatch forces
          fall-back to the per-fragment loop.

VERIFICATION:

- `bash -n scripts/50_setup_nodes.sh` PASSES.
- Lussu probe E (PSOCK swap) → previously HANG, now PASS via fork-guard.
- Lussu probe F (`terra::terraOptions(todisk=TRUE)`) → PASS via default.
- `sudo -u <ad-user> R --vanilla -e '.libPaths()'` → first entry
  `/var/lib/biome-Rlibs/<user>/<R-ver>`; second entry the legacy NFS path.
- `sudo bash scripts/50_setup_nodes.sh --verify` reports `Rprofile.site
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

- T2 (docker): pending — to be ported when T2 is realigned to T1.
- T3 (k8s):    pending — `R_LIBS_USER` will land on `emptyDir` per-pod;
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

- `05_thread_guard.R.template` — wraps `parallel::detectCores()` to
    return the cgroup-derived `MAX_THREADS` cap; prevents BLAS/OMP
    over-subscription when user code calls `detectCores()` directly.
- `55_options_guard.R.template` — clamps `options(mc.cores = ...)`
    on every set, so a forgotten `options(mc.cores = 64)` at the top
    of a user script can never escape the cgroup limit.
- `60_safe_setwd.R.template` — split into asymmetric behaviour:
    **batch (`Rscript`/`R --no-save`)** = hard-fail on bad `setwd`
    (Martina-gate fix preserved); **interactive (RStudio)** = warn
    and continue (botanists routinely paste `setwd("...")` lines).
- Section -1.5 of the dispatcher now **reuses** `.biome_blas_cache`
    across sessions for the same user, avoiding the BLAS coretype probe
    on every cold boot.

WHAT CHANGED:

- [B1]  NEW DIRECTORY: `/etc/R/Rprofile_site.d/.compiled/` (created at
          deploy time by `50_setup_nodes.sh` Step 8). Owned `root:root`,
          mode `0755`; bundle file `0644`.
- [B2]  NEW DISPATCHER SECTION: FRAGMENT LOADER v12.3 (replaces the v12.2
          loop). ~70 lines. Computes md5 hashes via R-native digest of
          file bytes; reads manifest with `readLines()`; compares as a
          `setequal()` over `paste(hash, basename)` rows.
- [B3]  NEW DEPLOY STEP: `setup_nodes_compile_bundle()` in
          `scripts/50_setup_nodes.sh` (Step 8 of the menu). Builds
          `bundle.Rc` + `manifest.txt` in a staging tmpdir, atomic
          `mv -T`, then page-cache warm-up via `cat > /dev/null`.
- [B4]  NEW FRAGMENTS: `05_thread_guard.R`, `55_options_guard.R`.
          `60_safe_setwd.R` extended with batch/interactive split.
- [B5]  DISPATCHER: `.biome_blas_cache` reuse logic added in Section
          -1.5; cache key = `paste(user, R.version.string, blas_kind)`.
- [B6]  KERNEL BUMP: `Rprofile_site.R.template` advertises `12.3` and
          adds `ENABLE_FRAG_BUNDLE` flag (default `TRUE`).
- [B7]  CONFIG bump: `config/setup_nodes.vars.conf` →
          `RPROFILE_VERSION="12.3"`.

VERIFICATION:

- `Rscript --vanilla -e 'parse(file=...)'` PASSES for every fragment.
- `bash -n scripts/50_setup_nodes.sh` PASSES.
- Cold-boot R session timing (heavy fragment chain, 9 fragments):
  legacy loop ≈ 280–340 ms; bundle fast-path ≈ 35–55 ms (~6× faster);
  fall-back path identical to v12.2 (regression-free).
- Tampering test: edit one byte of any `.R` fragment in place → next
  session falls back to legacy loop, logs `[frag-bundle] manifest
  mismatch on <name>` to `sys_log`. No silent staleness.
- `ls /etc/R/Rprofile_site.d/.compiled/` shows `bundle.Rc` and
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

- T2 (docker): pending — bundle build will move to image build time
                (read-only `/etc/R/Rprofile_site.d/.compiled/` baked into
                the layer).
- T3 (k8s):    pending — same as T2; ConfigMap-projected `.compiled/`
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

- **Dispatcher** (`templates/Rprofile_site.R.template`, 693 lines) keeps only
  the safety-critical bootstrap that cannot tolerate fragment-deletion:
  integrity self-check, `.biome_early_err`, OpenBLAS coretype detection,
  user-tmp-root setup, BLAS serial/pthread SIGSEGV guard, PSOCK worker
  fast-path (half of an `if/else`, not fragmentable), `bspm` pre-load,
  `.biome_skip_main` idempotency guard, and the main `local({...})` opener
  through feature flags, `.biome_env` bootstrap, `sys_log`,
  `.biome_mark_time`, session timeout, library paths, and Smart Cleanup.

- **Fragments** (`templates/Rprofile_site.d/*.R.template`, 9 files, 2306
  total LOC) are sourced via `sys.source(envir = environment())` inside the
  dispatcher's main `local({...})` frame — so they inherit the closure
  (`sys_log`, `.biome_env`, `ENABLE_*`, `.C_*`, `VERSION`, `curr_user`,
  `USER_TMP_ROOT`, `MAX_THREADS`). Zero code was rewritten: fragments are
  mechanical `sed` slices of the v12.1 monolith body, line-for-line.

STRATEGY. Three approaches were considered:

- (A) STRICT split — promote every shared local to `.biome_env$*` and
        rewrite every reference. High risk, ~6-8h work.
- (B) PRAGMATIC — one `local({...})` wrapper, fragments sourced inside
        with `local=TRUE`. Chosen for lexical inheritance.
- (C) HYBRID — chosen. Two-pass loader (early at global scope, late inside
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

- [S1]  NEW FILE: `templates/Rprofile_site.R.template` rewritten as thin
          dispatcher (693 lines). Preserves every early-scope section 1:1
          from v12.1 (SECTION 0 / -2 / -1.8 / -1.5 / -1, bspm pre-load,
          `.biome_skip_main` guard, main `local` opener through
          `cgroups_init` timer mark). Replaces lines 592–2502 (~1910 lines
          of body) with a 75-line fragment loader.
- [S2]  NEW FILE: `templates/Rprofile_site.R.template.legacy_v12.1_rollback`
          — byte-identical copy of the v12.1 monolith. Rollback path:
          `cp legacy_v12.1_rollback Rprofile_site.R.template && rm
           templates/Rprofile_site.d/{20,30,40,45,50,70}_*.R.template`.
- [S3]  NEW FILES: 6 new fragments mechanically sliced from the monolith:
          `20_cgroup_reader`, `30_psock_factory`, `40_wrapper_installer`,
          `45_memory_guards`, `50_pkg_hooks`, `70_persistent_tools`.
- [S4]  DISPATCHER loader uses `sys.source(envir = environment())`
          explicitly (NOT `source(..., local=TRUE)`) because the latter's
          `parent.frame()` resolution is fragile when called from inside
          a `for` loop inside a `tryCatch` — `sys.source` with an explicit
          env argument is deterministic.
- [S5]  CONFIG bump: `config/setup_nodes.vars.conf` → `RPROFILE_VERSION="12.2"`.
- [S6]  `scripts/50_setup_nodes.sh` required NO changes: the existing
          `setup_nodes_config_files()` already deploys every
          `templates/Rprofile_site.d/*.R.template` via glob and runs
          per-fragment `Rscript --vanilla -e 'parse(file=...)'` checks.
          Verified: `bash -n scripts/50_setup_nodes.sh` = OK.
- [S7]  HEADER comment block in dispatcher updated to describe v12.2
          Hybrid-C architecture and list the 9-fragment inventory.

CROSS-FRAGMENT DEPENDENCIES (load order matters):

- `30_psock_factory` MUST load before `45_memory_guards` — the latter's
    `safe_makeCluster` auto-route path reads `.biome_env$.biome_make_cluster_impl`
    stashed by the former.
- `40_wrapper_installer` MUST load before `45_memory_guards` and
    `50_pkg_hooks` — both use `.biome_install_wrapper`.
- `35_compile_routing` MUST load before `50_pkg_hooks` — the latter's
    NIMBLE hook expects `safe_compileNimble` to exist for monkey-patch install.
- `70_persistent_tools` MUST load before `80_tools_ext` — the latter
    attaches helpers to `tools:biome_calc` which the former creates.

Lexical `[0-9]{2}_` prefix ordering satisfies all of the above.

VERIFICATION:

- `parse(file=...)` PASSES for dispatcher + all 9 fragments (after `%%VAR%%` → `0` substitution).
- `bash -n scripts/50_setup_nodes.sh` PASSES.
- Fragment total LOC (2306) + dispatcher (693) = 2999 lines vs v12.1 monolith (2536) + loader-stub (30) = 2566 lines. Δ +433 lines is per-fragment header comments (inventory banner, deploy path, inherited closure docs, source line-range provenance).
- Sandbox validation DEFERRED — sandbox marked KNOWN BROKEN in `.clinerules`; smoke-test against user/researcher env (Martina's `Mod7_sq_diff_DEBUG_test.R`) is the acceptance test.

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

- [C1]  REMOVED: get_active_users() — /proc-scanning to count R processes.
          The kernel's CPUWeight=100 on user-.slice enforces proportional CPU
          fair-share automatically. Counting pids was both unreliable
          (Rscript/future workers inflate count) and unnecessary.
- [C2]  REMOVED: per-user RAM division in update_resources().
          quota = ram_gb / n_procs → now quota = ram_gb * 0.9.
          MemoryHigh/MemoryMax on user slice is the real enforcement boundary.
- [C3]  REMOVED: fair_cores = eff_vc / n_procs division.
          CPUWeight handles scheduler fairness. fair_cores now reflects the
          full cgroup-capped vcore count; bt = min(fair_cores, MAX_THREADS)
          still prevents BLAS livelock (CPUWeight != thread count cap).
- [C4]  REMOVED: BIOME-RESCALE notification box.
          Was triggered by n_procs change; kernel throttles silently now.
- [C5]  REMOVED: ENABLE_RESOURCE_MGMT flag — only gated removed logic.
          Thread management (OMP/BLAS/MKL) is now under ENABLE_BLAS_MGMT.
- [C6]  FIXED:  ENABLE_CGROUP_AWARE path bug — previous code read
          /sys/fs/cgroup/memory.max (root cgroup, always "max"). User slice
          limits live at user.slice/user-<uid>.slice/. MY_UID is resolved
          before this block runs (Section: Portable UID).
- [C7]  UPDATED: status() and startup banner reflect cgroup enforcement.
- [C8]  API_VERSION bumped 10↑11.
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

- REVERT: .biome_install_wrapper NO LONGER writes environment(fn) <- ns_env.
            Closures keep their original lexical scope (the local() frame).
- TARGETED: safe_makeCluster uses parallel:::getClusterOption("type") as
              explicit default — triple-colon bypasses scoping entirely, no
              namespace tricks needed.
- KEEP:     was_locked state preservation, install/fail logging, centralized
              helper structure — those were genuine improvements.

  CHANGES:

- [L1]  REVERTED: environment(fn) <- ns_env removed from
                    .biome_install_wrapper (was v11.3 [W1] part 1).
- [L2]  FIXED:    safe_makeCluster default arg is now
                    `type = parallel:::getClusterOption("type")` — triple-
                    colon resolves directly against parallel namespace, no
                    closure-env hacking needed.
- [L3]  KEPT:     All other v11.3 improvements survive (was_locked
                    preservation, sys_log coverage, smart_io split with
                    captured .ref, parallelly requireNamespace guard,
                    safe_dist formals restore, phantom dir cleanup, etc.).
- [L4]  API_VERSION bumped 9→10 to signal the scope contract fix.

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

- [W1]  ADDED:   .biome_install_wrapper() — single helper for installing
                   namespace-binding wrappers. Sets environment(fn) <- ns_env
                   so default args resolving to non-exported symbols work.
                   Preserves original binding lock state (was_locked save/restore)
                   — fixes silent "cannot change value of locked binding" errors
                   when other packages try to patch same bindings later.
                   Logs every install/skip/fail via sys_log for post-mortem.
- [W2]  FIXED:   safe_makeCluster — now uses .biome_install_wrapper; default
                   `getClusterOption("type")` resolves against parallel ns.
                   Observed in prod: makeCluster(4, outfile=...) now works.
- [W3]  FIXED:   safe_dist — restored full formal args (method, diag, upper, p)
                   so tab completion, introspection, lintr, and positional
                   calls all work. Also delegates explicitly (no ... splat).
- [W4]  FIXED:   safe_distm — added `...` passthrough for forward compat
                   with future geosphere releases.
- [W5]  FIXED:   All safe_* wrappers migrated to .biome_install_wrapper —
                   was_locked state preserved; no more unconditional lockBinding.
- [W6]  FIXED:   Smart I/O — split .biome_smart_io into two dedicated wrappers
                   (.biome_smart_read_csv for utils::read.csv,
                    .biome_smart_fread  for data.table::fread). Each captures
                   its original via closure (not namespace lookup) so infinite
                   recursion is impossible even if .biome_env is cleared.
                   fread wrapper now matches real signature (input,file,text,cmd).
- [W7]  FIXED:   .biome_make_cluster_impl — requireNamespace("parallelly")
                   guard with explicit stop() message. No more silent fail in
                   minimal environments.
- [W8]  FIXED:   Section -1.8 — removed pre-creation of nimble_compile/
                   tmb_compile subdirs (phantom per v11.2 H1-H8). Not exported
                   to worker env anymore. Renamed comment: escape hatch docs.
- [W9]  FIXED:   Stan hook — separate flags per package (.cmdstanr_hook_done,
                   .brms_hook_done, .rstan_hook_done). Enables late-loading
                   packages to still pick up their routing.
- [W10] FIXED:   addTaskCallback fallback now covers non-RStudio Rscript —
                   if callback registration fails AND we're not in RStudio,
                   run init/hooks immediately so guards are still installed.
- [W11] FIXED:   get_active_users — counts Rscript and bare R too, not just
                   rsession. Future::multisession and callr-spawned processes
                   now counted correctly in fair-share computation.
- [W12] DOCUMENTED: solve/dist/outer wrappers are bypassed by S4 dispatch
                   (e.g., Matrix::solve on dgCMatrix). Added warning in header
                   of each guard so future maintainers know the scope.
- [W13] API_VERSION bumped 8→9 to signal contract change (new helper + fixes).

Key design principles (v11.0):

- CORETYPE auto-detected from CPU vendor on EVERY session start (migration-safe)
- NO static CORETYPE, OMP, or BLAS thread counts in env files
- Boot-time detection: biome-detect-coretype.service (systemd oneshot)
- Per-session detection: this profile (handles live migration without reboot)
- Thread cap: %%MAX_BLAS_THREADS%% max to prevent QEMU livelock + BLAS oversubscription
- PESSIMISTIC SYSTEM ENGINEERING: assume failure at every layer, fail fast

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

- [H1]  REMOVED: options(nimble.dirName = ...) in worker fast-path (phantom)
- [H2]  REMOVED: setHook(packageEvent("nimble", "onLoad"), ...) (phantom target)
- [H3]  REMOVED: setHook(packageEvent("nimbleHMC", "onLoad"), ...) (phantom)
- [H4]  REMOVED: Sys.setenv(TMB_COMPILE_DIR = ...) in worker fast-path (phantom)
- [H5]  REMOVED: setHook for TMB/glmmTMB (phantom target)
- [H6]  REMOVED: options(rstan.auto_write = ...) (phantom)
- [H7]  REMOVED: Sys.setenv(STAN_TMPDIR = ...) (phantom)
- [H8]  REMOVED: Per-worker subdir creation in BIOME_NIMBLE_DIR / BIOME_TMB_DIR
                   (cargo cult — NIMBLE uses tempdir() per worker, not these dirs)
- [H9]  KEPT:    options(cmdstanr_output_dir = worker_sd) for Stan output
                   routing — but only if BIOME_STAN_DIR is set (real API)
- [H10] KEPT:    options(brms.file_refit = "on_change") — real API
- [H11] KEPT:    BLAS thread capping via Sys.setenv (OMP_NUM_THREADS etc.) — real
- [H12] KEPT:    BIOME env var propagation via biome_make_cluster() — real
- [H13] KEPT:    cluster_logs outfile routing — real and useful
- [H14] ADDED:   Optional worker diagnostic log (BIOME_WORKER_DEBUG=1) writes
                   /tmp/biome_worker_<pid>.log to trace fast-path execution.
                   For use if a future mystery arises; no-op by default.
- [H15] API_VERSION bumped 7→8 to signal contract change (phantom APIs removed).

v11.1 CHANGES (from v11.0) — SUPERSEDED BY v11.2: attempted setHook fix for
  phantom API options(nimble.dirName). Since the option itself doesn't exist,
  the setHook approach was academic. Kept here for historical record:

- [F1]  Root cause observed in production (biome-calc04, R 4.5.3, 2026-04-22):
          Worker fast-path at Rprofile load creates worker_<pid>/ dirs correctly
          and BLAS env vars propagate, BUT options(nimble.dirName = worker_nd)
          does NOT persist — getOption("nimble.dirName") returns NULL in
          clusterEvalQ. Package-namespaced options set during Rprofile.site
          sourcing appear to be lost when the worker transitions to the
          parallel:::.slaveRSOCK() serve loop. Plain options (e.g.
          "biome.profile.loaded") survive; only package-dotted names are lost.
          Not fully understood; possibly related to the way Rscript handles
          the site profile vs the slave bootstrap expression.
- [F2]  FIX: register setHook(packageEvent("nimble", "onLoad"), ...) in the
          worker fast-path. Hook fires at require(nimble) / library(nimble)
          time — exactly when options(nimble.dirName) actually matters for
          compileNimble() routing. Hook closure captures worker_nd; safe
          across worker lifetime. Applied symmetrically to nimbleHMC.
- [F3]  Same setHook pattern applied to TMB/glmmTMB (env var TMB_COMPILE_DIR)
          and rstan/cmdstanr/brms (mixed options + STAN_TMPDIR). Belt-and-
          suspenders: also keep the original options()/Sys.setenv() calls in
          case either persists — harmless if redundant, saves you if one path
          gets broken by future R or package changes.
- [F4]  API_VERSION bumped 6→7 to signal the contract change.

- [N1]  NIMBLE compilation moved NFS→/Rtmp local disk (per-PID worker subdirs)
          Reason: acregmin=60,acdirmin=60 on NFS causes directory-cache races
          during concurrent compileNimble() in multi-chain MCMC via parLapply.
          Symptom: unserialize(node$con) worker death mid-chain. See rstudio#7031.
- [N2]  PSOCK fast-path receives BIOME_NIMBLE_DIR + BIOME_TMB_DIR env vars
          and creates worker_<pid> subdirs → zero parent-dir contention.
- [N3]  biome_make_cluster() propagates all /Rtmp routing env vars to workers
          and accepts outfile= argument (default: /Rtmp/.../cluster_logs/).
          Outfile captures worker stderr for post-mortem when a worker dies.
- [N4]  parallel::makeCluster() safeguard — warns + redirects to
          biome_make_cluster(). Educates users away from unsafe patterns.
- [N5]  doSNOW::registerDoSNOW() safeguard (symmetric to doParallel).
- [N6]  Rcpp/sourceCpp compile temp routed via TMPDIR (no new option needed,
          but documented — Rcpp uses tempdir() which inherits from Renviron).
- [N7]  rstan/cmdstanr/brms auto-config — if loaded, set output_dir and
          cache dirs to /Rtmp. Thread cap for stan_sampling.
- [N8]  BRISC / spNNGP / ranger — OMP thread cap for packages using libgomp
          directly (not BLAS). Set n.omp.threads option on load.
- [N9]  New tool: biome_future_plan() — helper that picks plan() based on
          workload. callr for compile-heavy (NIMBLE/Stan), cluster for I/O.
- [N10] New tool: biome_worker_diagnostics() — reads cluster_logs/ and shows
          last N crashes, quickly locates the worker that died mid-chain.
- [N11] Dynamic rJava heap — replaces hardcoded -Xmx4g (uses user's quota).
- [N12] parallel::mcmapply / pvec / mclapply warnings for NFS-bound users.
- [N13] R_USER_CACHE_DIR kept on NFS (persistent package install cache)
          but TMPDIR + per-pkg scratch dirs on /Rtmp (fast, ephemeral).
- [N14] brms::make_stancode + rstan::sampling cores arg capped at MAX_THREADS.

v10.0 CHANGES (from v9.8) — Local /Rtmp Disk Architecture:

- [T1]  Replaced 100GB RAM tmpfs with dedicated 400GB local disk at /Rtmp
- [T2]  Removed tmpfs→NFS split-brain routing
- [T3]  Removed NFS fallback
- [T4]  All per-package temp dirs use local /Rtmp/biome_<user>/<pkg>
- [T5]  RAMDISK_GB=0 (no RAM consumed by /Rtmp)
- [T7]  API_VERSION bumped 4→5

v9.8 CHANGES (from v9.7) — OpenBLAS Serial Safety:

- [B1]  SECTION -1.5: BLAS serial/pthread safety check at profile load
- [B2]  .biome_env$blas_is_serial: pessimistic flag
