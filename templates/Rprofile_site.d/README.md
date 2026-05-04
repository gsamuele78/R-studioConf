# Rprofile_site.d/ — Kernel Feature Fragments (v12.2)

Deployed by `scripts/50_setup_nodes.sh` to `/etc/R/Rprofile_site.d/`. Since
v12.2 the `Rprofile_site.R` dispatcher is a **thin bootstrap** that, after
its own critical setup (integrity check, BLAS safety, PSOCK worker fast-path,
bspm pre-load, `.biome_env` / `sys_log` / feature flags / Smart Cleanup),
sources every `[0-9][0-9]_*.R` file in this directory in **lexical name
order** via `sys.source(envir = environment())`. Fragments therefore inherit
the dispatcher's `local({...})` closure (`.biome_env`, `sys_log`,
`.biome_mark_time`, `ENABLE_*`, `.C_*` colors, `VERSION`, `curr_user`,
`USER_TMP_ROOT`, `MAX_THREADS`, …) without any further wiring.

## RStudio loading behavior

There is **no behavioural difference** vs. the v12.1 monolith from
`rsession`'s point of view:

* `rsession` sources `/etc/R/Rprofile.site` → the v12.2 dispatcher runs
  once per R session, exactly like v12.1.
* All `ENABLE_*` flags, `.biome_env`, `sys_log`, deferred task callbacks,
  `tools:biome_calc` attachment and Smart Cleanup happen in the same order.
* Fragment load is the **final step** of the dispatcher's main `local({...})`
  and happens before `rsession` is handed control to the user.
* Fragment failures are isolated (`tryCatch` per fragment) and logged to
  `/tmp/biome_frag_errors_<pid>.log`; the session **never** aborts.
* PSOCK workers (detected via `BIOME_WORKER_MODE` or `MASTER=` in
  `commandArgs`) still take the worker fast-path and do **not** run the
  fragment loader — same lean worker as v12.1.

If a fragment file is missing or corrupt, the loader emits a `FragLoader`
`WARN`/`FAIL` line and moves on. `setup_nodes.sh` runs `Rscript -e parse()`
on every fragment before deploy, which catches unsubstituted `%%VAR%%`
placeholders and syntax errors at build time, not runtime.

## Naming convention

```
<NN>_<slug>.R          deployed file
<NN>_<slug>.R.template source with %%VAR%% placeholders (optional)
```

`<NN>` is a two-digit priority (`00` first, `99` last). Leave gaps of 5-10 so
new fragments can be inserted between existing ones without renumbering.

## Contract each fragment MUST honor

1. **Must not call `stop()`**. Use `warning()` or `sys_log()` (inherited from
   the dispatcher closure — always available).
2. **Must tolerate re-sourcing.** Although the dispatcher has a
   `.biome_skip_main` idempotency guard, individual fragments may still be
   sourced by hand during development. Guard expensive state:
   `if (exists("x", inherits = FALSE)) return(invisible())`.
3. **Errors are caught by the loader** and written to
   `/tmp/biome_frag_errors_<pid>.log` — NEVER abort rsession boot.
4. **No external CDN/network.** Everything must work on an air-gapped VM.
5. **No global state outside documented names.** Attach persistent tools to
   `as.environment("tools:biome_calc")` (created by fragment `70_`) or to
   `.biome_env`.
6. **Respect cross-fragment load order** — see inventory table below. If a
   fragment depends on symbols created by a later-numbered fragment, it is a
   design bug; fix the numbering.

## Current fragments (v12.2)

| # | File | Source | Purpose |
|---|---|---|---|
| 20 | `20_cgroup_reader.R` | split from v12.1 monolith lines 592-855 | cgroup v1/v2 detection, quota/memory limits, `setup_adaptive_callback` |
| 30 | `30_psock_factory.R` | split from v12.1 monolith lines 857-951 | `.biome_make_cluster_impl` + `biome_make_cluster`; stashes impl into `.biome_env` for `45_`'s `safe_makeCluster` |
| 35 | `35_compile_routing.R` | additive (v12.1) | `BIOME_RUN_ID`, `.biome_get_compile_dir`, `safe_compileNimble` (absorbs Martina-gate NIMBLE routing) |
| 40 | `40_wrapper_installer.R` | split from v12.1 monolith lines 952-1027 | `.biome_install_wrapper` — lexical-scope-preserving function replacer (depended on by 45) |
| 45 | `45_memory_guards.R` | split from v12.1 monolith lines 1028-1248 | `solve` / `dist` / `outer` / `expand.grid` / `safe_makeCluster` memory guards (requires 40 and 30) |
| 50 | `50_pkg_hooks.R` | split from v12.1 monolith lines 1249-1821 | Deferred package hooks (terra, raster, sf, nimble, stan, cmdstanr, arrow, future, rgee, ggplot2, tensorflow, rJava…) via `addTaskCallback` |
| 60 | `60_safe_setwd.R` | additive (v12.1) | Hard-fail guard on `base::setwd()` when path missing (fixes Martina-gate class of bug) |
| 70 | `70_persistent_tools.R` | split from v12.1 monolith lines 1822-2496 | `biome_cluster_test`, `biome_worker_diagnostics`, `biome_plot_budget`, `tools:biome_calc` attachment, final diag dump, welcome banner |
| 80 | `80_tools_ext.R` | additive (v12.1) | `biome_tmb_compile()`, `biome_run_diagnostics()` attached to `tools:biome_calc` (requires 70) |

## Disabling fragments (dev / debug)

There are **three** supported mechanisms, in increasing order of
invasiveness:

### 1. Runtime env-var (recommended for debugging)

The dispatcher honors `BIOME_DISABLE_FRAGMENTS` as a comma/semicolon/colon/
space-separated list of tokens. A fragment is skipped when ANY token
either equals its 2-digit prefix **or** is a substring of its basename:

```bash
# Disable the memory guards only, for one session
BIOME_DISABLE_FRAGMENTS=45 rstudio-session

# Disable guards + package hooks
BIOME_DISABLE_FRAGMENTS="45,50" R

# Disable by slug substring
BIOME_DISABLE_FRAGMENTS="memory_guards" R
```

Skipped fragments are logged as `FragLoader SKIP <file> (BIOME_DISABLE_FRAGMENTS=<token>)`.
This mechanism never touches the filesystem and is safe for end users.

### 2. Per-component feature flags

Most fragments already check the dispatcher's `ENABLE_*` flags (e.g.
`ENABLE_SMART_ROUTING`, `ENABLE_PARALLEL_GUARD`, `ENABLE_CGROUP_AWARE`,
`ENABLE_STAN_OPT`, `ENABLE_TF_MGMT`…). To persistently disable one feature
while keeping the rest of the fragment loaded, flip the flag in the
dispatcher's main `local({...})` block (around line ~340 of
`Rprofile_site.R.template`) and redeploy.

### 3. Remove / rename the fragment file

```bash
# Single fragment
sudo rm /etc/R/Rprofile_site.d/45_memory_guards.R

# ALL fragments (degraded kernel mode — only dispatcher bootstrap remains)
sudo rm /etc/R/Rprofile_site.d/*.R
```

The loader silently skips a missing directory and emits `FragLoader WARN`
when the directory is empty. Re-run `scripts/50_setup_nodes.sh` to
reinstall.

## Rollback

To roll back the entire v12.2 split to the v12.1 monolith:

```bash
cp templates/Rprofile_site.R.template.legacy_v12.1_rollback \
   templates/Rprofile_site.R.template
rm -f templates/Rprofile_site.d/2?_*.R.template \
      templates/Rprofile_site.d/3?_*.R.template \
      templates/Rprofile_site.d/4?_*.R.template \
      templates/Rprofile_site.d/5?_*.R.template \
      templates/Rprofile_site.d/7?_*.R.template
# (keeps 35_, 60_, 80_ which were already additive in v12.1)
sudo bash scripts/50_setup_nodes.sh
```

The byte-identical v12.1 monolith is preserved at
`templates/Rprofile_site.R.template.legacy_v12.1_rollback`.
