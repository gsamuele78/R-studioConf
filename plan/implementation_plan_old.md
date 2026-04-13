# Rprofile v9.6 — Pessimistic Hardening for Big-Data Visualization & Resilience

Upgrade Rprofile_site.R.template from v9.5 to v9.6 with pessimistic-engineering hardening for ggplot2/plotly big-data workloads, automatic tmpfs overflow protection, additional resilience fixes, and system dependency updates.

## User Review Required

> [!IMPORTANT]
> **Auto-redirect vs. user-prompt for NFS fallback**: The plan implements a **hybrid approach** — automatic NFS redirect when tmpfs reaches 80% capacity (pessimistic threshold), with a user-visible warning message. Users do NOT need to set `BIOME_FORCE_NFS_TMP` manually — the system does it proactively. The tutorial/help text is updated to reflect this. The 80% threshold is conservative (current is 85%) to leave headroom before the "hard wall."

> [!WARNING]
> **System dependency addition**: `ragg` requires system packages (`libfreetype-dev`, `libharfbuzz-dev`, `libfribidi-dev`, `libtiff-dev`, `libpng-dev`). These will be added to the apt-get install block in Step 1 of `50_setup_nodes.sh`. This is an apt package install — review before approving.

> [!IMPORTANT]
> **Smart I/O `read.csv` override safety**: The current profile replaces `utils::read.csv` with a custom function via `unlockBinding`. This is brittle and causes `R CMD check` warnings. The plan tightens this by adding a guard that falls through to the original function on any error, but does NOT remove the feature (it's a core BIOME-CALC selling point).

---

## Proposed Changes

### Configuration

#### [MODIFY] [setup_nodes.vars.conf](file:///home/jfs/00_Antigravity_workspace/R-studioConf/config/setup_nodes.vars.conf)

- Add `ragg`, `svglite`, `systemfonts` to `R_PACKAGES` array
- Bump `RPROFILE_VERSION` from `"9.3"` to `"9.6"`

---

### System Dependencies

#### [MODIFY] [50_setup_nodes.sh](file:///home/jfs/00_Antigravity_workspace/R-studioConf/scripts/50_setup_nodes.sh)

**Step 1 (`setup_nodes_dependencies`)**: Add `ragg` system dependencies to the apt-get install block:
```diff
   run_cmd apt-get install -y -qq \
     ca-certificates lsb-release wget apt-transport-https gnupg curl \
     libgdal-dev libgeos-dev libproj-dev \
     libpython3-dev python3-venv python3-pip \
     libudunits2-dev cmake build-essential \
     libopenblas-dev libomp-dev gfortran \
+    libfreetype-dev libharfbuzz-dev libfribidi-dev libtiff-dev libpng-dev \
     libgoogle-perftools-dev sendemail dnsutils \
     samba-common-bin winbind rsync tree
```

These are build-time dependencies for `ragg` (Anti-Grain Geometry renderer) and `svglite`.

---

### Rprofile Template (main work)

#### [MODIFY] [Rprofile_site.R.template](file:///home/jfs/00_Antigravity_workspace/R-studioConf/templates/Rprofile_site.R.template)

**Version bump**: v9.5 → v9.6 in header comments and changelog.

##### Change 1: New feature flag `ENABLE_GGPLOT_OPT` (line ~161)

```r
  ENABLE_GGPLOT_OPT    <- TRUE
```

##### Change 2: Pessimistic tmpfs monitor — pure-R `/proc/mounts` + `statvfs` replacement (in `deferred_pkg_init`)

Replace the `system2("df", ...)` approach for `get_tmp_use_pct()` with a pure-R implementation that reads `/proc/mounts` + uses `file.info()` — no fork, no system2 call. This is more resilient in cgroup-constrained environments where `fork()` can fail.

```r
    get_tmp_use_pct <- function() {
      tryCatch({
        # Pure-R: parse /proc/mounts for tmpfs on /tmp, read size from mount options
        mounts <- readLines("/proc/mounts", warn = FALSE)
        tmp_line <- grep("tmpfs /tmp ", mounts, value = TRUE, fixed = FALSE)[1]
        if (is.na(tmp_line)) return(0)
        # Extract size= from mount options (4th field)
        opts <- strsplit(strsplit(tmp_line, " ")[[1]][4], ",")[[1]]
        size_opt <- grep("^size=", opts, value = TRUE)
        if (length(size_opt) == 0) return(0)
        size_str <- sub("^size=", "", size_opt[1])
        # Parse size (e.g., "100g", "102400m", "104857600k", "107374182400")
        multiplier <- 1
        if (grepl("[gG]$", size_str)) { multiplier <- 1024^3; size_str <- sub("[gG]$", "", size_str) }
        else if (grepl("[mM]$", size_str)) { multiplier <- 1024^2; size_str <- sub("[mM]$", "", size_str) }
        else if (grepl("[kK]$", size_str)) { multiplier <- 1024; size_str <- sub("[kK]$", "", size_str) }
        total_bytes <- as.numeric(size_str) * multiplier
        if (is.na(total_bytes) || total_bytes <= 0) return(0)
        # Get actual usage via file listing (pessimistic: includes all users)
        tmp_files <- list.files("/tmp", all.files = TRUE, full.names = TRUE, recursive = FALSE)
        used_bytes <- sum(file.info(tmp_files, extra_cols = FALSE)$size, na.rm = TRUE)
        as.numeric(used_bytes / total_bytes * 100)
      }, error = function(e) 0)
    }
```

> [!NOTE]
> Actually, the `list.files` approach underestimates usage because it doesn't recurse into subdirectories. A more accurate approach uses `system2("stat", args=c("-f", "-c", "%b %f %S", "/tmp"))` for filesystem-level stats. But `system2` forks. The **pessimistic** choice: use `system2("df")` as the profile already does — it's a fast, cached kernel stat call — but wrap it with a fallback to the `/proc/mounts` approach if `system2` fails (e.g., cgroup fork limit).

##### Change 3: Automatic NFS redirect when tmpfs ≥ 80% (pessimistic, in `deferred_pkg_init`)

The current logic checks only once during `deferred_pkg_init()`. The new design:

1. **Initial check** in `deferred_pkg_init()` — same as now but at 80% (down from 85%)
2. **Periodic re-check** in `update_resources()` callback — if tmpfs crosses 80%, auto-set `BIOME_FORCE_NFS_TMP=true`, create the fallback dir, redirect `TMP`/`TEMP`/`TMPDIR`, and warn the user
3. **Never auto-redirect back** to tmpfs within the same session (pessimistic: once you overflow, stay on NFS)

```r
    # In update_resources(), after thread management:
    if (ENABLE_SMART_ROUTING) tryCatch({
      tmp_pct <- get_tmp_use_pct()
      if (tmp_pct >= 80 && Sys.getenv("BIOME_FORCE_NFS_TMP") != "true") {
        fallback <- file.path(Sys.getenv("HOME"), ".r_tmp_fallback")
        if (!dir.exists(fallback)) dir.create(fallback, recursive = TRUE, showWarnings = FALSE)
        Sys.setenv(BIOME_FORCE_NFS_TMP = "true", TMP = fallback, TEMP = fallback, TMPDIR = fallback)
        sys_log("TmpOverflow", "WARN", sprintf("tmpfs at %d%%, auto-redirected to NFS: %s", as.integer(tmp_pct), fallback))
        if (interactive()) {
          warning(sprintf(
            paste0("BIOME-CALC: /tmp RAMDisk at %d%% capacity! Temp files auto-redirected to NFS (%s).\n",
                   "  This is slower but prevents OOM. To manually control: Sys.setenv(BIOME_FORCE_NFS_TMP = \"true\")"),
            as.integer(tmp_pct), fallback
          ), call. = FALSE, immediate. = TRUE)
        }
      }
    }, error = function(e) NULL)
```

##### Change 4: ggplot2/plotly engine in `deferred_pkg_init()` — expanded (lines 464–468)

Replace the existing 5-line ggplot2 block with a comprehensive engine:

```r
    if (ENABLE_GGPLOT_OPT && (isNamespaceLoaded("ggplot2") || isNamespaceLoaded("plotly"))) tryCatch({
      # 1. Redirect plot temp to smart_tmp_base (existing logic)
      gt <- file.path(smart_tmp_base, paste0("plot_cache_", curr_user))
      if (!dir.exists(gt)) dir.create(gt, recursive = TRUE, showWarnings = FALSE)
      Sys.setenv(TMP = gt, TEMP = gt)
      
      # 2. Prefer ragg backend if available (2-4x faster than cairo)
      has_ragg <- requireNamespace("ragg", quietly = TRUE)
      if (has_ragg) {
        options(device = ragg::agg_png)
      }
      options(bitmapType = "cairo")  # Explicit fallback, never X11
      
      # 3. Scientific color defaults (colorblind-safe)
      options(
        ggplot2.continuous.colour = "viridis",
        ggplot2.continuous.fill   = "viridis"
      )
      
      # 4. Font cache warm-up (prevents first-plot latency on NFS homes)
      Sys.setenv(FONTCONFIG_PATH = "/etc/fonts")
      if (requireNamespace("systemfonts", quietly = TRUE)) {
        tryCatch(systemfonts::system_fonts(), error = function(e) NULL)
      }
      
      backend_label <- if (has_ragg) "ragg" else "cairo"
      tmp_label <- if (smart_tmp_base == "/tmp") "RAMDisk" else "NFS-Fallback"
      msg_parts <- c(msg_parts, sprintf("Ggplot [%s/%s]", backend_label, tmp_label))
    }, error = function(e) NULL)
```

##### Change 5: Worker TMP/TEMP propagation in `.biome_make_cluster_impl()`

Add `TMP` and `TEMP` to the worker environment so parallel `ggsave()` uses the same routing:

```r
    parallelly::makeClusterPSOCK(
      workers,
      revtunnel = FALSE,
      homogeneous = TRUE,
      rscript_envs = c(
        BIOME_WORKER_MODE    = "1",
        BIOME_WORKER_THREADS = as.character(worker_threads),
        OMP_NUM_THREADS      = as.character(worker_threads),
        OPENBLAS_NUM_THREADS = as.character(worker_threads),
        MKL_NUM_THREADS      = as.character(worker_threads),
        TMP                  = Sys.getenv("TMP", "/tmp"),
        TEMP                 = Sys.getenv("TEMP", "/tmp"),
        TMPDIR               = Sys.getenv("TMPDIR", "/tmp"),
        BIOME_FORCE_NFS_TMP  = Sys.getenv("BIOME_FORCE_NFS_TMP", ""),
        if (nchar(coretype) > 0) c(OPENBLAS_CORETYPE = coretype) else NULL
      )
    )
```

##### Change 6: `biome_plot_budget()` diagnostic tool

Add to `tools:biome_calc` environment — allows users to check their tmpfs budget before starting a big render:

```r
  assign("biome_plot_budget", function() {
    cat(paste0("\n", .C_CYAN, "=== BIOME-CALC Plot Budget ===", .C_RESET, "\n"))
    tmp_info <- tryCatch(
      system2("df", args = c("-P", "-BG", "/tmp"), stdout = TRUE, stderr = FALSE),
      error = function(e) NULL
    )
    if (!is.null(tmp_info) && length(tmp_info) >= 2) {
      p <- strsplit(trimws(tmp_info[2]), "\\s+")[[1]]
      cat(sprintf("  tmpfs Total: %s | Used: %s | Free: %s (%s)\n", p[2], p[3], p[4], p[5]))
    }
    backend <- if (requireNamespace("ragg", quietly = TRUE)) "ragg (fast)" else "cairo (default)"
    cat(sprintf("  Render backend: %s\n", backend))
    routing <- if (Sys.getenv("BIOME_FORCE_NFS_TMP") == "true") "NFS (safe for big data)" else "RAMDisk (fast, 100GB cap)"
    cat(sprintf("  Tmp routing:    %s\n", routing))
    cat(sprintf("  R tempdir:      %s\n", tempdir()))
    # User-specific tmp usage
    plot_dir <- file.path("/tmp", paste0("plot_cache_", Sys.info()[["user"]]))
    if (dir.exists(plot_dir)) {
      sz <- sum(file.info(list.files(plot_dir, full.names = TRUE, recursive = TRUE, all.files = TRUE))$size, na.rm = TRUE)
      cat(sprintf("  Your plot cache: ~%.1f MB\n", sz / 1024^2))
    }
    cat(paste0("  ", .C_GRAY, "Tip: Large renders (>50 GB temp) auto-redirect to NFS at 80%% tmpfs usage.", .C_RESET, "\n\n"))
    invisible(NULL)
  }, envir = tool_env)
```

##### Change 7: Resilience fixes (deep-inspection findings)

**7a. Smart I/O `read.csv` override — add safety guard**

The current code (line 513) does `unlockBinding → assign → lockBinding` but the conditional is inverted: it only overrides when the binding IS locked (`if (lk)`). This is correct behavior but fragile. Add a tryCatch around the entire sequence:

```r
    if (requireNamespace("utils", quietly=TRUE)) tryCatch({
      ue <- as.environment("package:utils")
      if (exists("read.csv", envir=ue)) {
        .biome_env$original_read_csv <- get("read.csv", envir = ue)  # Save original
        lk <- tryCatch(bindingIsLocked("read.csv",ue), error=function(e)TRUE)
        if (lk) {
          unlockBinding("read.csv",ue)
          assign("read.csv",.biome_smart_io,envir=ue)
          lockBinding("read.csv",ue)
        }
      }
    }, error=function(e) NULL)
```

And update `.biome_smart_io` to call the saved original on fallback instead of hardcoded `utils::read.csv`:

```r
    .biome_smart_io <- function(file, ...) {
      if (is.character(file) && length(file)==1) {
        pq <- paste0(file, ".parquet")
        if (file.exists(pq) && interactive() && requireNamespace("arrow", quietly=TRUE)) {
          message("BIOME-IO: Using .parquet accelerator!")
          return(arrow::read_parquet(pq))
        }
      }
      mc <- as.character(sys.call()[1])
      if (grepl("fread", mc) && requireNamespace("data.table", quietly=TRUE)) return(data.table::fread(file, ...))
      # Use saved original to avoid infinite recursion if another package also overrides
      orig <- tryCatch(get("original_read_csv", envir = .biome_env), error = function(e) NULL)
      if (!is.null(orig)) return(orig(file, ...))
      return(utils::read.csv(file, ...))
    }
```

**7b. `get_active_users()` — add timeout guard**

The `/proc` scan iterates ALL PIDs. On a busy system with thousands of processes, this can take seconds. Add a limit:

```r
  get_active_users <- function() {
    tryCatch({
      pids <- list.dirs("/proc", full.names = FALSE, recursive = FALSE)
      pids <- pids[grepl("^[0-9]+$", pids)]
      count <- 0L
      scanned <- 0L
      for (p in pids) {
        scanned <- scanned + 1L
        if (scanned > 2000L) break  # Pessimistic: cap scan at 2000 PIDs
        cmdline_file <- file.path("/proc", p, "cmdline")
        if (file.exists(cmdline_file)) {
          cmd <- tryCatch(readLines(cmdline_file, n = 1, warn = FALSE), error = function(e) "")
          if (length(cmd) > 0 && grepl("rsession", cmd[1], fixed = TRUE)) count <- count + 1L
        }
      }
      if (count < 1L) 1L else count
    }, error = function(e) 1L)
  }
```

**7c. `save.image()` in `biome_save_session` — add size check**

Users can accidentally try to save a 200 GB workspace to NFS. Add a warning:

```r
  assign("biome_save_session", function(file_name = "biome_session_backup.RData") {
    target <- file.path(Sys.getenv("HOME"), file_name)
    # Pessimistic: estimate workspace size before saving
    ws_size <- tryCatch(sum(sapply(ls(envir = .GlobalEnv), function(x) 
      object.size(get(x, envir = .GlobalEnv))), na.rm = TRUE), error = function(e) 0)
    ws_gb <- ws_size / 1024^3
    if (ws_gb > 50) {
      message(sprintf(paste0(.C_YELLOW, 
        "\n⚠️  WARNING: Your workspace is ~%.1f GB. Saving may take a long time on NFS.\n",
        "   Consider saving selectively: save(obj1, obj2, file = 'my_data.RData')", .C_RESET), ws_gb))
    }
    message(paste0("\n💾 Saving your workspace to: ", target, " ..."))
    save.image(file = target)
    message(paste0(.C_GREEN, "\n✅ Workspace safely preserved on disk! You may now safely log out.", .C_RESET, "\n"))
  }, envir = tool_env)
```

**7d. `update_resources()` — stale cgroup detection**

If a cgroup memory limit changes mid-session (e.g., admin adjusts container limits), the profile uses the stale value from session start. Fix: re-read cgroup limits during `update_resources()` at a lower frequency (every 5 minutes):

```r
  # Add a second timestamp for cgroup refresh
  se$last_cgroup_check <- 0
```

Then in `update_resources()`:
```r
      # Re-check cgroups every 5 minutes (container limits can change)
      if (ENABLE_CGROUP_AWARE && (now - .biome_env$shared_env$last_cgroup_check) > 300) {
        .biome_env$shared_env$last_cgroup_check <- now
        tryCatch({
          cg2_mem <- "/sys/fs/cgroup/memory.max"
          if (file.exists(cg2_mem)) {
            v <- trimws(readLines(cg2_mem, n=1, warn=FALSE))
            if (v != "max") .biome_env$shared_env$cgroup_ram_gb <- as.numeric(v)/(1024^3)
          }
        }, error = function(e) NULL)
      }
```

##### Change 8: Update `biome_tutorial()` and `biome_help()` 

- Add `biome_plot_budget()` to the tools listing
- Update the "Massive Data / Tmpfs Bypass" section to explain the automatic redirect
- Add a new section on ggplot optimization

---

## Open Questions

> [!IMPORTANT]
> **Q1: NFS performance for plot temp files.** When the system auto-redirects to NFS, ggplot temp file I/O will be significantly slower (10-50x vs. tmpfs). Should we add a `message()` telling the user to consider reducing plot complexity, or just silently redirect? **Current plan: emit a warning once, then stay silent.**

> [!IMPORTANT]
> **Q2: `ragg` vs `cairo` as default.** Should `ragg::agg_png` be the default device for ALL users (via `options(device = ...)`) or only when ggplot2 is loaded? Setting it globally could break some users who expect `png()` behavior exactly. **Current plan: set it only inside the ggplot2 deferred init block, so it only applies when ggplot2 is actually loaded.**

---

## Verification Plan

### Automated Tests

1. **R syntax validation**: `Rscript --vanilla -e "tryCatch({parse(file='Rprofile_site.R.template');cat('PARSE_OK')}, error=function(e) cat(sprintf('PARSE_FAIL: %s',e\$message)))"`
2. **Template placeholder check**: `grep -oP '%%\w+%%' Rprofile_site.R.template | sort -u` — verify all placeholders have matching vars in `setup_nodes.vars.conf`
3. **Feature flag isolation**: Verify that setting `ENABLE_GGPLOT_OPT <- FALSE` disables all new ggplot code paths
4. **Worker fast-path verification**: Confirm PSOCK workers still exit early on line 110 without loading the ggplot engine

### Manual Verification

1. Deploy to sandbox VM via `50_setup_nodes.sh` (menu option 3)
2. In RStudio: `library(ggplot2); status()` → verify `Ggplot [ragg/RAMDisk]` appears
3. `biome_plot_budget()` → verify output
4. Simulate tmpfs exhaustion: verify auto-redirect triggers
