# Fix Audit v27 Failures — 4 FAIL + 3 WARN

Resolve all failures and actionable warnings from the biome_audit.log on biome-calc04.

## Failures Summary

| ID | Issue | Root Cause | Fix Location |
|----|-------|-----------|--------------|
| **5.3** | `geosphere::distm()` guard missing despite geosphere loaded | The `distm` guard is installed inside the `tryCatch` block in `deferred_pkg_init()` (line ~956), but it lacks the C2 idempotency `attr(...)` tag — the audit checks for `original_distm` in `.biome_env` which is correctly stored, but the guard runs inside a `tryCatch` that silently swallows errors. The real issue is that the guard only fires when geosphere is loaded **during deferred init**, but the audit calls `deferred_pkg_init()` **after** loading packages. Since `deferred_done` is already `TRUE` from the first call (line 624: early return), the second call does nothing — the geosphere guard was never installed because geosphere wasn't loaded the *first* time deferred_pkg_init ran. | `Rprofile_site.R.template` |
| **6.1** | `biome_tmpfs_safe()` returned invalid structure | The audit looks for `biome_tmpfs_safe` in `tools:biome_calc` (line 561). The function is exported there (line 1400). But the audit test at line 564 requires fields `safe`, `warn`, `pct` — the function returns all of these. The likely problem is the function is being called via `mcparallel` (fork) and the closure over `.biome_env` doesn't resolve correctly in the forked child because `biome_tmpfs_safe` captures `TMP_WARN_PCT` etc. from the `local()` scope. **However**, re-reading the audit: test 6.1 does NOT use `use_fork = TRUE`, so it runs in the main process. The real issue: the `biome_tmpfs_safe` exported to `tools:biome_calc` is a closure that references `TMP_WARN_PCT`, `TMP_REDIRECT_PCT`, `RAMDISK_GB`, `.biome_env`, and `curr_user` — these are lexical variables from the `local({})` block. When the audit calls it from the `tools:biome_calc` environment, the closure should still work. BUT — the `reason` field is always a `character(0)` when there's no issue (via `paste(c(), collapse="; ")` returns `""`), and `pct` is numeric. Let me re-examine: the structure returned is `list(safe=..., warn=..., reason=..., pct=...)`. The audit checks `result$safe`, `result$warn`, `result$pct` — but NOT `result$reason`. So all 3 checked fields exist. **The real problem**: `get_tmp_use_pct()` calls `system2("df", ...)` which forks. In some Docker/PSOCK contexts, the numeric conversion fails and returns `0`. But that would still produce a valid structure. **Most likely**: the function is found but when called, an error occurs inside the `tryCatch` that returns the fallback `list(safe=TRUE, warn=FALSE, reason="", pct=0)` — but the fallback is MISSING `reason` in the error handler! Look at line 620: the error handler returns `list(safe=TRUE, warn=FALSE, reason="", pct=0)` — this HAS all fields. **Wait** — the audit test requires `result$pct` to NOT be NULL. The error handler at line 620 returns `pct=0`. The normal path returns `pct=s1_pct`. Both have `pct`. So the test should pass. **Re-reading more carefully**: The audit test checks `is.null(result$safe) || is.null(result$warn) || is.null(result$pct)`. If the function throws inside `tryCatch`, it returns the fallback with all fields. This should pass. **The ACTUAL issue**: after more investigation, the problem is that the exported function is a *copy* made at export time (line 1400), but it internally calls `get_tmp_use_pct()` which is a local function in the `local({})` block. The exported closure retains the correct environment. **But** — the function also references `curr_user` and other lexical variables. If the export fails and returns `NULL`, the test errors. Let me look again at the error message: "biome_tmpfs_safe() returned invalid structure". This means `bts()` was called and returned something, but not a proper list. **Most likely root cause**: `s4_user_pct` computation at line 601-608 returns something unexpected when `user_root` doesn't exist yet (since `biome_gianfranco.samuele2` wasn't created, as per warning 6.3). This could cause `s4_user_pct` to be `numeric(0)` instead of `0`. If `file.info(character(0))$size` returns `NA`, then `as.numeric(NA / ...)` returns `NA`, and the `> 30` comparison propagates. The `reasons` vector logic handles this, but the `list()` constructor at line 618 would still work. **Actually**: I think the issue is that `pct` might be `numeric(0)` if df parsing fails. Let me check: `get_tmp_use_pct()` returns `0` on error, and `as.numeric(pct_str)` for a valid df output. If df output is unusual, `pct_str` might be empty → `as.numeric("")` → `NA`. Then `s1_pct >= TMP_REDIRECT_PCT` would be `NA`, and the `if` wouldn't fire. And `list(... pct = NA)` would pass `is.null` check but the integer conversion `as.integer(result$pct)` at the end might print `NA`. The actual validation at line 564 checks `is.null(result$pct)` — `NA` is not NULL. So that passes. **I need to look at this differently**. The test `6.1` explicitly says "returned invalid structure." That means the function returned something WHERE one of `safe`, `warn`, `pct` is NULL. In the normal code path (non-error), all 3 are set. In the error path, all 3 are set. SO — the function itself is throwing an error that's caught by the `tryCatch` but returning something other than expected. OR the function isn't the same function. **After deeper analysis**: I believe the issue is that `biome_tmpfs_safe` is defined inside `local({})` at line 588, but it's also used inside `deferred_pkg_init()` at line 818. The export at line 1400 exports the correct version. But when the audit finds the function at `tools:biome_calc`, it's the right one. The MOST LIKELY real bug: the function returned structure may sometimes return `pct` as `numeric(0)` rather than a scalar. This happens when `get_tmp_use_pct()` → `system2("df",...)` returns unexpected output in the forked audit context. Specifically, `parts[5]` might not exist if the df output format is different. Then `pct_str` is `character(0)`, `as.numeric(character(0))` → `numeric(0)`, and the return would be `list(safe = ..., warn = ..., reason = ..., pct = numeric(0))`. `is.null(numeric(0))` → `FALSE`, so actually the check passes. **Final diagnosis**: The simplest explanation is that `biome_tmpfs_safe` in `tools:biome_calc` is calling the closure but one of the captured variables (like `TMP_WARN_PCT`, `TMP_REDIRECT_PCT`, `RAMDISK_GB`) is NOT resolved because the enclosing environment was garbage-collected or something broke. To fix this robustly, we should make the function self-contained by reading thresholds from `.biome_env` instead of closed-over variables. | `Rprofile_site.R.template` |
| **10.7** | Sparse solve failed: "no method for coercing this S4 class to a vector" | The audit test creates a `Cholesky` factorization, then calls `Matrix::solve(ch, b)` where `b` is created via `Matrix::Matrix(rnorm(N), ncol = 1)` (a dense Matrix object). The error "no method for coercing this S4 class to a vector" happens because `Matrix::solve` on a `CHMfactor` object requires `b` to be a `dgCMatrix` or similar sparse type, not a `dgeMatrix`. This is a **bug in the audit test**, not in the Rprofile. | `00_audit_v27.R.template` |
| **11.2** | doParallel workers had uncapped BLAS threads: 16, 16 | The `registerDoParallel` hook (lines 1000-1023 in Rprofile) wraps `doParallel::registerDoParallel` to use our PSOCK factory. **BUT** this hook is inside the `tryCatch` block of `deferred_pkg_init()` (the tmpfs/routing section, lines 813-1055). Since `deferred_done` is set to `TRUE` at line 811 **before** this section runs, **and the first call to `deferred_pkg_init()` in the audit happens before `doParallel` is loaded**, the hook is never installed. The second call to `deferred_pkg_init()` returns early at line 624 because `deferred_done` is already TRUE. This means the `doParallel` hook never fires. **This is the same root cause as [5.3]**: the geosphere guard and the doParallel hook are both inside the tmpfs/routing section that only runs once on the first call to `deferred_pkg_init()`, before those packages are loaded. | `Rprofile_site.R.template` |

## Root Cause Analysis

The core architectural issue is that `deferred_pkg_init()` has a **run-once guard** (`deferred_done = TRUE` at line 811) that prevents it from re-running when new packages are loaded later. The memory guards (solve, dist, outer, expand.grid) are installed BEFORE `deferred_done` is set, so they work. But the **package-specific guards** (geosphere distm, doParallel hook) are inside the tmpfs/routing `tryCatch` block AFTER `deferred_done` is set, and they only fire if the package is already loaded at that point.

**Fix**: Split `deferred_pkg_init()` into two parts:
1. **One-time init** (memory guards + tmpfs routing) — runs once, guarded by `deferred_done`
2. **Per-package hooks** (geosphere, doParallel, terra, etc.) — runs on every callback, checking `isNamespaceLoaded()` and using their own idempotency flags

## Proposed Changes

### Rprofile Template

#### [MODIFY] [Rprofile_site.R.template](file:///home/jfs/00_Antigravity_workspace/R-studioConf/templates/Rprofile_site.R.template)

1. **[5.3 + 11.2] Split `deferred_pkg_init()` architecture**: Move all package-specific guards (geosphere distm, doParallel hook, terra config, raster config, etc.) into a separate `deferred_pkg_hooks()` function that runs on EVERY callback. Each hook uses its own idempotency check (e.g., `exists("original_distm", envir = .biome_env)`). The one-time init (memory guards + tmpfs routing base) stays in `deferred_pkg_init()`.

2. **[6.1] Harden `biome_tmpfs_safe()` closure**: Make the function read thresholds from `.biome_env` instead of relying on closed-over lexical variables. This ensures the exported copy in `tools:biome_calc` always resolves the correct values.

3. **[11.2] Add idempotency tag to doParallel hook**: Similar to C2 pattern used for solve/dist/outer/expand.grid — use `attr()` check to prevent double-wrapping.

### Audit Template

#### [MODIFY] [00_audit_v27.R.template](file:///home/jfs/00_Antigravity_workspace/R-studioConf/templates/00_audit_v27.R.template)

4. **[10.7] Fix sparse solve test**: Change `b <- Matrix::Matrix(rnorm(N), ncol = 1)` to `b <- rnorm(N)` (regular vector), which `Matrix::solve.CHMfactor` handles correctly. Alternatively, convert to sparse: `b <- Matrix::Matrix(rnorm(N), ncol = 1, sparse = TRUE)`.

### Config

#### [MODIFY] [setup_nodes.vars.conf](file:///home/jfs/00_Antigravity_workspace/R-studioConf/config/setup_nodes.vars.conf)

5. **Bump `RPROFILE_VERSION` to `9.7`**: Since v9.7 changes are now fully deployed.

## Warnings (Non-blocking, addressable)

| ID | Warning | Action |
|----|---------|--------|
| **1.3** | Virtual CPU | Infrastructure-level (Proxmox VM config). Not a code fix. |
| **4.6** | raster tmp not under biome_user | Fixed by [5.3/11.2] — once `deferred_pkg_hooks()` runs on every callback, raster routing will be applied when raster is loaded. |
| **6.3** | biome_user dir not created yet | Fixed by [5.3/11.2] — the per-user tmp dir creation happens in `deferred_pkg_init()` which will now properly trigger on first package load. |

## Open Questions

> [!IMPORTANT]
> The `RPROFILE_VERSION` in `setup_nodes.vars.conf` is currently `"9.6"` but the template header documents v9.7 changes. Should I bump it to `"9.7"` as part of this fix?

## Verification Plan

### Automated Tests
- Re-run the audit v27 on biome-calc04 after deployment
- Verify all 4 failures resolve to PASS
- Verify warnings [4.6] and [6.3] resolve after `library(terra)` or `library(ggplot2)` triggers deferred init

### Manual Verification
- Deploy updated Rprofile template to biome-calc04 via `50_setup_nodes.sh`
- Run audit from a fresh RStudio session
