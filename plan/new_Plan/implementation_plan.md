# Rprofile_site.R.template v9.6 → v9.7 — Pessimistic Refactoring Plan

## Background

The current `Rprofile_site.R.template` (1409 lines, 71 KB) is a **single-file system profile** that handles CPU detection, memory guards, tmpfs routing, resource scheduling, package hooks, user tools, and session finalization for an RStudio OSS multi-user environment on QEMU/Proxmox.

It has grown organically through six minor versions (v9.1→v9.6) and accumulated structural debt. While functionally correct (all 40+ audit v27 tests pass), it violates several **pessimistic system engineering invariants** that the project's own `CLAUDE.md` mandates.

> **Paradigm reminder:** *Pessimistic System Engineering — assume failure, bound resources, fail fast on misconfiguration.*

---

## Findings

> [!IMPORTANT]
> All findings are **non-breaking** — they do not change behavior that existing audit tests validate. They harden the profile against failure modes that are currently silent.

---

### CRITICAL — Must Fix

---

#### C1. Single-Point-of-Failure in Task Callback Registration

**File:** [Rprofile_site.R.template](file:///home/jfs/00_Antigravity_workspace/R-studioConf/templates/Rprofile_site.R.template#L1067-L1075)

**Problem:** The entire resource-management and deferred-init system depends on a single `addTaskCallback()`. If this call fails silently (the `tryCatch` swallows the error), no resources are ever updated and no memory guards are ever installed for the session.

```r
# Line 1067-1075 — current code
tryCatch({
  addTaskCallback(function(...) {
    try({
      deferred_pkg_init()
      update_resources(quiet = TRUE)
    }, silent = TRUE)
    TRUE
  }, name = "biome_resource_monitor")
}, error = function(e) NULL)  # ← silent failure = no guards, no updates
```

**Principle violated:** *Fail fast on misconfiguration.*

**Fix:** Log the failure. Add a secondary `setHook("rstudio.sessionInit", ...)` fallback that fires `deferred_pkg_init()` once if the callback was never registered. Verify registration by checking `getTaskCallbackNames()`.

```r
tryCatch({
  addTaskCallback(function(...) {
    try({
      deferred_pkg_init()
      update_resources(quiet = TRUE)
    }, silent = TRUE)
    TRUE
  }, name = "biome_resource_monitor")
  if (!"biome_resource_monitor" %in% getTaskCallbackNames()) {
    sys_log("Callback", "FAIL", "addTaskCallback returned but name not found")
  }
}, error = function(e) {
  sys_log("Callback", "FAIL", paste("addTaskCallback failed:", e$message))
  # FALLBACK: run guards once via sessionInit hook
  setHook("rstudio.sessionInit", function(newSession) {
    if (!.biome_env$shared_env$deferred_done) {
      tryCatch(deferred_pkg_init(), error = function(e) NULL)
      tryCatch(update_resources(quiet = TRUE), error = function(e) NULL)
    }
  }, action = "append")
})
```

---

#### C2. Unguarded `unlockBinding` / `assign` on Base Functions

**File:** [Rprofile_site.R.template](file:///home/jfs/00_Antigravity_workspace/R-studioConf/templates/Rprofile_site.R.template#L678-L682) (solve), [L709-L712](file:///home/jfs/00_Antigravity_workspace/R-studioConf/templates/Rprofile_site.R.template#L709-L712) (dist), [L737-L739](file:///home/jfs/00_Antigravity_workspace/R-studioConf/templates/Rprofile_site.R.template#L737-L739) (outer), [L766-L769](file:///home/jfs/00_Antigravity_workspace/R-studioConf/templates/Rprofile_site.R.template#L766-L769) (expand.grid)

**Problem:** The memory sentinel guards overwrite `base::solve`, `stats::dist`, `base::outer`, and `base::expand.grid` by unlocking their bindings in `baseenv()` / `asNamespace("stats")`. This is **not idempotent** — if `deferred_pkg_init()` is called twice (which the task callback **will** do on the second expression), it:
1. Overwrites `.biome_env$original_solve` with the *already-wrapped* function
2. Creates a **recursion bomb**: `safe_solve` → calls `original_solve` → which is `safe_solve` → infinite loop

The only thing preventing this currently is the `deferred_done` flag at line 587. But if `.biome_env$shared_env` is corrupted (GC, env detach, re-source), the flag is lost and the recursion bomb is armed.

**Principle violated:** *Assume failure — idempotency is mandatory for anything that can fire twice.*

**Fix:** Guard each override with a check that the original is genuinely the base version, not our wrapper:

```r
# Before overriding solve:
if (!identical(base::solve, .biome_env$original_solve %||% NULL)) {
  .biome_env$original_solve <- base::solve
  # ... create safe_solve, assign, lock ...
}
```

Alternatively, tag the wrapper with a class attribute and check for it:

```r
if (!isTRUE(attr(base::solve, "biome_guard"))) {
  # ... install guard ...
  attr(safe_solve, "biome_guard") <- TRUE
}
```

---

### HIGH — Should Fix

---

#### H1. No Re-Source / Re-Load Protection for `.biome_env` in `.GlobalEnv`

**File:** [Rprofile_site.R.template](file:///home/jfs/00_Antigravity_workspace/R-studioConf/templates/Rprofile_site.R.template#L250-L252)

**Problem:** If a user accidentally runs `source("/etc/R/Rprofile.site")` or if RStudio re-sources on workspace restore, the `assign(".biome_env", ...)` at line 252 **replaces** the existing `.biome_env` — erasing all stored originals (`original_solve`, `original_dist`, etc.) and resetting `shared_env`. The `biome.profile.loaded` option guard at line 141 is supposed to prevent this, but `options()` are reset on `R --vanilla` or manual `options(biome.profile.loaded = NULL)`.

**Fix:** Before assigning, check if `.biome_env` already exists and has a valid `VERSION` field:

```r
if (exists(".biome_env", envir = .GlobalEnv)) {
  existing <- get(".biome_env", envir = .GlobalEnv)
  if (is.environment(existing) && !is.null(existing$VERSION)) {
    sys_log("Profile", "SKIP", sprintf("Already loaded (v%s)", existing$VERSION))
    return(invisible(NULL))
  }
}
```

---

#### H2. Race Condition: NFS Fallback Directory Creation

**File:** [Rprofile_site.R.template](file:///home/jfs/00_Antigravity_workspace/R-studioConf/templates/Rprofile_site.R.template#L465-L469)

**Problem:** When multiple R sessions start simultaneously (e.g., user opens 3 tabs), they all race to create `~/.r_tmp_fallback/biome_<user>/`. While `dir.create(..., showWarnings = FALSE)` handles the EEXIST case, the `Sys.setenv(TMP=..., TMDIR=...)` at line 469 **permanently redirects ALL temp I/O to NFS** — and this is **never reverted** (by design: "pessimistic, never reverts"). 

But the race means Session A might see `/tmp` at 74% (safe), while Session B sees it at 76% (unsafe) one millisecond later. Session A keeps using tmpfs, Session B goes to NFS. Now they're routing temp files to **different filesystems**, and if Session A later calls `biome_load_session()` loading Session B's `.RData`, terra objects have dangling tempdir references.

**Fix:** The "never revert" design is correct, but the **split-brain** scenario needs documentation and mitigation:
- Add a session-local marker file in the NFS fallback dir: `.biome_nfs_session_<PID>`
- On session finalize, clean up that marker
- In `biome_load_session()`, warn if the loaded workspace references temp paths on a different filesystem

---

#### H3. `tool_env` Leaks on Re-Attach

**File:** [Rprofile_site.R.template](file:///home/jfs/00_Antigravity_workspace/R-studioConf/templates/Rprofile_site.R.template#L1078-L1080)

**Problem:** The `detach` / `attach` cycle at lines 1078-1080 has a narrow race window where `search()` can change between the check and the detach. More importantly, if any user code has saved a reference to the old `tool_env`, it now points to a detached environment.

```r
tool_env_name <- "tools:biome_calc"
if (tool_env_name %in% search()) detach(tool_env_name, character.only = TRUE)
tool_env <- attach(NULL, name = tool_env_name)
```

**Fix:** Use `tryCatch` around the detach, and instead of detaching + re-attaching, reuse the existing environment if present:

```r
tool_env <- tryCatch({
  pos <- match(tool_env_name, search())
  if (!is.na(pos)) as.environment(pos) else attach(NULL, name = tool_env_name)
}, error = function(e) attach(NULL, name = tool_env_name))
```

---

#### H4. Unbounded `diag_logs` List Growth

**File:** [Rprofile_site.R.template](file:///home/jfs/00_Antigravity_workspace/R-studioConf/templates/Rprofile_site.R.template#L240)

**Problem:** `se$diag_logs <- list()` is a list that grows with every `sys_log()` call. With the 30-second resource update cycle and potential thousands of interactive commands, this can accumulate tens of thousands of entries over a 168-hour session (the `timeout=0` case). There is no pruning.

**Principle violated:** *Bound resources.*

**Fix:** Cap the list at a reasonable size (e.g., 500 entries), evicting oldest:

```r
sys_log <- function(section, status, msg = "") {
  tryCatch({
    logs <- .biome_env$shared_env$diag_logs
    if (length(logs) > 500L) {
      # Keep newest 400
      .biome_env$shared_env$diag_logs <- logs[seq(length(logs) - 399L, length(logs))]
    }
    .biome_env$shared_env$diag_logs[[section]] <- list(status = status, msg = msg, ts = Sys.time())
  }, error = function(e) NULL)
  # ... file logging unchanged ...
}
```

> [!NOTE]
> Actually, the current code uses `section` as the key (i.e., `diag_logs[[section]]`), which means it's a named list that overwrites entries per-section — not truly unbounded. But sections like `"TmpOverflow"` or `"ResMgmt"` still accumulate if the key varies. Recommend adding a fixed cap regardless.

---

### MEDIUM — Recommended

---

#### M1. Duplicated RAM-Read Helper

**File:** [Rprofile_site.R.template](file:///home/jfs/00_Antigravity_workspace/R-studioConf/templates/Rprofile_site.R.template#L356-L372) (`get_system_ram_gb`) and [L597-L604](file:///home/jfs/00_Antigravity_workspace/R-studioConf/templates/Rprofile_site.R.template#L597-L604) (`.biome_get_ram_gb`)

**Problem:** There are **two separate functions** that read `/proc/meminfo` for available RAM:
- `get_system_ram_gb()` (line 356) — used by `update_resources()`, subtracts RAMDISK_GB, respects cgroup
- `.biome_get_ram_gb()` (line 597) — used by memory guards, raw value in GB

They have different semantics (one subtracts RAMDISK, one doesn't; one caps by cgroup, one doesn't). This is a bug waiting to happen.

**Fix:** Unify into a single `get_available_ram_gb(subtract_ramdisk = TRUE, respect_cgroup = TRUE)` function stored in `.biome_env`, with the guards calling `get_available_ram_gb(subtract_ramdisk = FALSE, respect_cgroup = FALSE)`.

---

#### M2. Missing Version Contract Between Rprofile and Audit

**File:** Both [Rprofile_site.R.template](file:///home/jfs/00_Antigravity_workspace/R-studioConf/templates/Rprofile_site.R.template#L148) and [00_audit_v27.R.template](file:///home/jfs/00_Antigravity_workspace/R-studioConf/templates/00_audit_v27.R.template#L720-L726)

**Problem:** The audit at test 8.4 checks `vnum < 9.6` and warns. But there's no formal contract — the audit expects specific fields in `.biome_env` (like `TMP_WARN_PCT`, `TMP_REDIRECT_PCT`, `original_solve`, etc.) but has no way to know what version introduced what. If someone deploys audit v27 against an Rprofile v9.5, they get cryptic failures instead of a clear version mismatch error.

**Fix:** Add a machine-readable compatibility marker:

```r
# In Rprofile:
.biome_env$API_VERSION <- 3L  # Bumped when .biome_env structure changes

# In audit:
api_v <- tryCatch(.biome_env$API_VERSION, error = function(e) 0L)
if (api_v < 3L) stop(sprintf("Audit v27 requires Rprofile API v3+, found v%d", api_v))
```

---

#### M3. `geosphere::distm` Guard Duplicates `.biome_get_ram_gb` Inline

**File:** [Rprofile_site.R.template](file:///home/jfs/00_Antigravity_workspace/R-studioConf/templates/Rprofile_site.R.template#L924-L929)

**Problem:** The `safe_distm` wrapper at line 924 re-implements the entire `/proc/meminfo` read inline instead of calling `.biome_get_ram_gb()`. This is because `safe_distm` is installed inside `deferred_pkg_init()` and `.biome_get_ram_gb` is a local variable within that function scope. If `.biome_get_ram_gb` is later moved or refactored, this inline copy will silently diverge.

**Fix:** Store `.biome_get_ram_gb` in `.biome_env` so all guards can reference it:

```r
.biome_env$.get_ram_gb <- .biome_get_ram_gb
```

Then replace inline `/proc/meminfo` reads in `safe_distm` with `.biome_env$.get_ram_gb()`.

---

#### M4. `Sys.sleep(2)` in `safe_solve` — Blocks Non-Interactive Contexts

**File:** [Rprofile_site.R.template](file:///home/jfs/00_Antigravity_workspace/R-studioConf/templates/Rprofile_site.R.template#L632)

**Problem:** The solve() guard issues `Sys.sleep(2)` to "give user time to Ctrl+C" when OOM risk is high. But this sleep also fires in non-interactive batch scripts (`Rscript`), Shiny backends, and PSOCK workers that somehow bypass the fast path — silently adding 2 seconds latency to every large matrix solve.

**Fix:** Guard with `interactive()`:

```r
if (interactive()) Sys.sleep(2)  # Give user time to Ctrl+C
```

---

### LOW — Nice-to-Have

---

#### L1. Monolith Size: 1409 Lines, 71 KB

**Problem:** A 1400-line R profile is well beyond the maintainability threshold. It cannot be unit-tested in isolation. Contributors (including AI agents) must read the entire file to understand any single feature.

**Fix (future):** Split into modular files loaded by a thin `Rprofile_site.R`:

```
/etc/biome-calc/profile.d/
  00_coretype.R        # Section -2 (OPENBLAS detection)
  01_worker_fastpath.R # Section -1 (PSOCK fast path)
  10_resource_engine.R # Sections 1-4 (cgroups, RAM, threads)
  20_memory_guards.R   # solve/dist/outer/expand.grid
  30_tmpfs_routing.R   # biome_tmpfs_safe, per-user dirs
  40_package_hooks.R   # terra/arrow/ggplot/future/doParallel/TMB
  50_smart_io.R        # read.csv/fread override
  60_user_tools.R      # status(), ask_ai(), biome_make_cluster()
  99_finalize.R        # sessionInit hook, banner
```

Loader pattern:
```r
for (f in sort(list.files("/etc/biome-calc/profile.d", pattern = "^[0-9].*\\.R$", full.names = TRUE))) {
  tryCatch(source(f, local = TRUE), error = function(e) {
    sys_log("ProfileLoader", "FAIL", sprintf("%s: %s", basename(f), e$message))
  })
}
```

> [!WARNING]
> This is a major refactor. It should only be done if the team commits to the new structure. The audit would also need updating to test each module's export contract.

---

#### L2. No File-Level Integrity Check

**Problem:** The template is deployed via `envsubst` or similar. If a placeholder like `%%VM_VCORES%%` is not substituted (e.g., vars.conf is missing a line), the profile will `source()` with a syntax error at line 188 (`VM_VCORES <- %%VM_VCORES%%L`), and the entire profile silently fails.

**Fix:** Add a self-check at the very top of the file:

```r
# Line 1-5: Template integrity check
if (grepl("%%", readLines(sys.frame(sys.nframe())$ofile %||% "", n = 5, warn = FALSE)[4] %||% "")) {
  warning("BIOME-CALC: Rprofile has unsubstituted template placeholders. Skipping.", call. = FALSE)
  return(invisible(NULL))
}
```

Or, more robustly, check a sentinel value:

```r
.BIOME_TEMPLATE_CHECK <- "%%RPROFILE_VERSION%%"
if (grepl("^%%", .BIOME_TEMPLATE_CHECK)) {
  warning("BIOME-CALC: Rprofile_site.R was not rendered from template. Aborting.", immediate. = TRUE)
  return(invisible(NULL))
}
```

---

## Proposed Changes Summary

| ID | Severity | Change | Effort | Lines Affected |
|----|----------|--------|--------|---------------|
| C1 | **CRITICAL** | Callback fallback + verification | Small | 1067-1075 |
| C2 | **CRITICAL** | Idempotent guard installation | Medium | 610-770 |
| H1 | HIGH | Re-source protection for `.biome_env` | Small | 140-143, 250-252 |
| H2 | HIGH | NFS split-brain documentation + marker | Small | 465-469 |
| H3 | HIGH | Reuse `tool_env` instead of detach/attach | Small | 1078-1080 |
| H4 | HIGH | Cap `diag_logs` at 500 entries | Small | 255-264 |
| M1 | MEDIUM | Unify RAM-read helpers | Medium | 356-372, 597-604 |
| M2 | MEDIUM | API version contract | Small | 148, audit |
| M3 | MEDIUM | Store `.biome_get_ram_gb` in `.biome_env` | Small | 597-604, 924-929 |
| M4 | MEDIUM | Guard `Sys.sleep(2)` with `interactive()` | Trivial | 632 |
| L1 | LOW | Modular split (future) | Large | All |
| L2 | LOW | Template integrity self-check | Small | 1-5 (new) |

---

## Verification Plan

### Automated Tests
- Run the existing `00_audit_v27.R.template` after each change — all 40+ tests must pass
- Specifically verify:
  - `5.1-5.6`: Memory sentinel guards still active
  - `9.1`: solve() thread downclock + restore
  - `10.2`: Multi-solve thread consistency
  - `11.2`: doParallel worker isolation

### Manual Verification
- Deploy to sandbox VM (`vagrant up rstudio-host`)
- Test `source("/etc/R/Rprofile.site")` twice in a single session (C2 re-source safety)
- Kill the task callback mid-session and verify C1 fallback fires
- Open 3 RStudio tabs simultaneously and verify no split-brain tmpfs routing (H2)

---

## Open Questions

> [!IMPORTANT]
> **Q1:** Do you want to proceed with all findings, or only the CRITICAL + HIGH tier?

> [!IMPORTANT]
> **Q2:** For L1 (monolith split): is this something you'd like to plan for a future v10.0, or should we keep the single-file approach?

> [!IMPORTANT]
> **Q3:** For M2 (API version contract): should the audit **hard-fail** on version mismatch, or just **warn**?
