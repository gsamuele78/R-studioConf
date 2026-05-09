# Rprofile v9.6 — Pessimistic Hardening: Deep Analysis & Updated Plan

Upgrade Rprofile_site.R.template from v9.5 to v9.6 with accurate tmpfs overflow heuristic, automatic NFS fallback, per-user tmp isolation, ragg backend, and resilience fixes.

---

## Deep Analysis: Tmpfs Overflow Heuristic & OOM Prevention

### Problem Statement

The current v9.5 heuristic uses `system2("df", ...)` to read `/tmp` usage as a single percentage. This is dangerously simplistic for several reasons:

1. **`df` only measures disk-level usage** — it knows how much of the tmpfs *allocation* is consumed by files, but has NO visibility into whether those files are backed by RAM or were swapped by zram/zswap
2. **It ignores memory pressure** — a user could have 5% tmpfs used but 95% system RAM consumed by R objects, making any further tmpfs write trigger an OOM
3. **It doesn't account for in-flight allocations** — R's `ggplot()` + `ggsave()` can spike tmpfs usage by 10+ GB in a single render call, *after* the heuristic check
4. **It treats all users equally** — if User A fills 40% of tmpfs, User B gets a falsely reassuring "60% free" signal but may trigger OOM when they try to use the remaining 40%

### Solution: Multi-Signal Heuristic (Pessimistic Estimation)

The improved heuristic combines **4 independent signals** to estimate whether a tmpfs operation is safe:

| Signal | Source | What it tells us | Weight |
|--------|--------|-------------------|--------|
| **S1: tmpfs usage %** | `df -P /tmp` | Filesystem-level file usage | Primary gate |
| **S2: MemAvailable** | `/proc/meminfo` | Kernel's own estimate of available memory | Critical OOM signal |
| **S3: cgroup memory** | `/sys/fs/cgroup/memory.max` | Container/VM hard limit remaining | Hard wall |
| **S4: Per-user tmp usage** | `du` on user's tmp dirs | User's personal contribution to tmpfs | Per-user fairness |

The decision logic is pessimistic:

```
IF any_signal_hot:
    redirect_to_nfs()
    NEVER redirect_back_in_session()
```

Specifically:
- **S1 ≥ 70%** → redirect (lowered from 85% to account for burst writes)
- **S2 < 2× RAMDISK_GB** → redirect (if available RAM can't absorb a full tmpfs flush)
- **S3 < RAMDISK_GB + 4GB headroom** → redirect (container hard limit too close)
- **S4 > 30% of tmpfs per user** → redirect that user (fairness: no single user should consume >30% of shared tmpfs)

> [!WARNING]
> **Why 70% instead of 80%?** A single `ggplot2::ggsave()` of a large plot with `ragg::agg_png()` at 300 DPI can write 500MB-2GB to tmpfs in one call. With `terra` raster processing running in parallel, burst spikes of 10-20GB are possible. 70% on a 100GB tmpfs = 30GB headroom, which is safe for most burst scenarios. The *previous* 85% threshold left only 15GB headroom — dangerously thin for multiuser heavy visualization.

### Why One `/tmp` Per User Makes Sense (But NOT Separate tmpfs Mounts)

> [!IMPORTANT]
> **Verdict: Use per-user subdirectories under shared `/tmp`, NOT separate tmpfs mounts.**

**Separate tmpfs mounts per user** (e.g., `/tmp/user_alice` as a distinct tmpfs) would require:
- systemd or PAM mount units per user → complex provisioning
- Pre-allocating RAM per user → wastes memory on idle users
- Breaking the kernel's ability to balance tmpfs globally under memory pressure

**Per-user subdirectories** under the shared `/tmp` (which is already how the Rprofile works) gives the benefits:
- User-isolated cleanup (only delete your own old files)
- Per-user usage tracking via `du` (for the S4 fairness signal)  
- Kernel manages overall tmpfs memory pressure globally
- No provisioning changes needed

The current code already does this pattern:
- `file.path("/tmp", paste0("terra_", curr_user))` 
- `file.path("/tmp", paste0("plot_cache_", curr_user))`
- `file.path("/tmp", paste0("keras_cache_", curr_user))`

The plan **consolidates** these into a single user root: `/tmp/biome_<user>/{terra,plot_cache,keras_cache,...}` — one `du` call covers the full user footprint.

---

## Where to Deploy `ragg`: `50_setup_nodes.sh` (NOT `r_env_manager.sh`)

> [!IMPORTANT]
> **`ragg` system dependencies and R package go into `50_setup_nodes.sh` and `setup_nodes.vars.conf`, NOT into `r_env_manager.sh`.**

### Architecture Analysis

The two scripts serve completely different layers:

| Aspect | `50_setup_nodes.sh` | `r_env_manager.sh` |
|--------|--------------------|--------------------|
| **Purpose** | Production node hardening & optimization | Initial R environment bootstrap (fresh install) |
| **When run** | On every deployment / update | Once (first-time setup) |
| **R packages** | Performance/infrastructure R pkgs from `R_PACKAGES` array in `setup_nodes.vars.conf` | User-facing R pkgs from `R_USER_PACKAGES_CRAN` in `r_env_manager.conf` |
| **Dependencies** | System libs for BIOME-CALC infra pkgs | System libs for R build toolchain |
| **Idempotent** | Yes, runs repeatedly safely | Yes, but designed for one-shot |
| **Who manages** | `50_setup_nodes.sh` Step 1 (apt deps) + Step 7 (R pkgs) | `install_r_build_deps()` + `install_r_pkg_list()` |

**`ragg` is an infrastructure package** (rendering backend for the Rprofile engine), NOT a user-requested package. It belongs with `data.table`, `arrow`, `parallelly`, `terra`, `sf`, `RhpcBLASctl` and the other performance infrastructure packages in `setup_nodes.vars.conf::R_PACKAGES`.

**Evidence from codebase:**
- `R_PACKAGES` in [setup_nodes.vars.conf](file:///home/jfs/00_Antigravity_workspace/R-studioConf/config/setup_nodes.vars.conf#L144-L163) contains ALL infrastructure R packages
- `R_USER_PACKAGES_CRAN` in [r_env_manager.conf](file:///home/jfs/00_Antigravity_workspace/R-studioConf/config/r_env_manager.conf#L22-L28) contains user/research packages (`ggplot2`, `lme4`, `DHARMa`, etc.)
- `r_env_manager.sh` already installs `libharfbuzz-dev`, `libfribidi-dev`, `libfreetype6-dev`, `libpng-dev`, `libtiff5-dev` in its `install_r_build_deps()` function ([line 800](file:///home/jfs/00_Antigravity_workspace/R-studioConf/r_env_manager.sh#L800-L801)) — meaning the system deps for ragg are **already there** on systems bootstrapped with `r_env_manager.sh`, but the R package itself is missing.

### Decision

1. **`setup_nodes.vars.conf`**: Add `ragg`, `svglite`, `systemfonts` to `R_PACKAGES` array
2. **`50_setup_nodes.sh` Step 1**: Add `libfreetype-dev` to apt deps (aliases to `libfreetype6-dev` on newer Ubuntu)
3. **`r_env_manager.sh`**: **NO CHANGES** — it already has the system dev libraries from `install_r_build_deps()`

---

## User Review Required

> [!IMPORTANT]
> **Auto-redirect vs. user-prompt for NFS fallback**: The plan implements a **proactive multi-signal redirect** — automatic NFS redirect when ANY of the 4 signals indicates danger. Users do NOT need to set `BIOME_FORCE_NFS_TMP` manually. Once redirected, the session stays on NFS (pessimistic, no flip-back).

> [!WARNING]
> **System dependency addition**: `ragg` requires system packages (`libfreetype-dev`, `libharfbuzz-dev`, `libfribidi-dev`, `libtiff-dev`, `libpng-dev`). Most are already installed by `r_env_manager.sh::install_r_build_deps()`. The addition to `50_setup_nodes.sh` ensures they're present on standalone deployments. This is an apt package install — review before approving.

> [!IMPORTANT]
> **Heuristic threshold change: 85% → 70%**. This is a **significant** change that will cause more frequent NFS fallback. The tradeoff is: slower I/O on NFS vs. zero-risk of OOM kills during heavy visualization. Users who know they're safe can override: `Sys.setenv(BIOME_FORCE_TMPFS = "true")`.

---

## Proposed Changes

### Configuration

#### [MODIFY] [setup_nodes.vars.conf](file:///home/jfs/00_Antigravity_workspace/R-studioConf/config/setup_nodes.vars.conf)

- Add `"ragg"`, `"svglite"`, `"systemfonts"` to `R_PACKAGES` array
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

---

### Rprofile Template (main work)

#### [MODIFY] [Rprofile_site.R.template](file:///home/jfs/00_Antigravity_workspace/R-studioConf/templates/Rprofile_site.R.template)

**Version bump**: v9.5 → v9.6 in header comments and changelog.

##### Change 1: New feature flag `ENABLE_GGPLOT_OPT` (after line ~161)

```r
  ENABLE_GGPLOT_OPT    <- TRUE
```

##### Change 2: Per-user tmp root consolidation + multi-signal heuristic

Replace the current single `get_tmp_use_pct()` with a comprehensive `biome_tmpfs_safe()` function:

```r
    # Multi-signal tmpfs safety heuristic (pessimistic)
    # Returns: list(safe = TRUE/FALSE, reason = "...", pct = numeric)
    biome_tmpfs_safe <- function() {
      tryCatch({
        # Signal 1: tmpfs usage via df (fast, cached kernel stat)
        s1_pct <- tryCatch({
          df <- system2("df", args = c("-P", "/tmp"), stdout = TRUE, stderr = FALSE)
          if (length(df) >= 2) as.numeric(sub("%", "", strsplit(trimws(df[2]), "\\s+")[[1]][5]))
          else 0
        }, error = function(e) {
          # Fallback: parse /proc/mounts for tmpfs size + file.info for usage
          tryCatch({
            mounts <- readLines("/proc/mounts", warn = FALSE)
            tmp_line <- grep("tmpfs /tmp ", mounts, value = TRUE, fixed = FALSE)[1]
            if (is.na(tmp_line)) return(0)
            opts <- strsplit(strsplit(tmp_line, " ")[[1]][4], ",")[[1]]
            size_opt <- grep("^size=", opts, value = TRUE)
            if (length(size_opt) == 0) return(0)
            size_str <- sub("^size=", "", size_opt[1])
            multiplier <- 1
            if (grepl("[gG]$", size_str)) { multiplier <- 1024^3; size_str <- sub("[gG]$", "", size_str) }
            else if (grepl("[mM]$", size_str)) { multiplier <- 1024^2; size_str <- sub("[mM]$", "", size_str) }
            else if (grepl("[kK]$", size_str)) { multiplier <- 1024; size_str <- sub("[kK]$", "", size_str) }
            total_bytes <- as.numeric(size_str) * multiplier
            if (is.na(total_bytes) || total_bytes <= 0) return(0)
            # Pessimistic: quick non-recursive scan
            tmp_files <- list.files("/tmp", all.files = TRUE, full.names = TRUE, recursive = FALSE)
            used_bytes <- sum(file.info(tmp_files, extra_cols = FALSE)$size, na.rm = TRUE)
            as.numeric(used_bytes / total_bytes * 100)
          }, error = function(e) 0)
        })

        # Signal 2: MemAvailable (kernel's own OOM proximity estimate)
        s2_mem_avail_gb <- tryCatch({
          mi <- readLines("/proc/meminfo", warn = FALSE)
          al <- grep("^MemAvailable:", mi, value = TRUE)
          if (length(al) > 0) as.numeric(sub(".*:\\s+(\\d+).*", "\\1", al[1])) / 1024 / 1024
          else Inf
        }, error = function(e) Inf)

        # Signal 3: cgroup headroom
        s3_cgroup_headroom_gb <- tryCatch({
          cg_ram <- .biome_env$shared_env$cgroup_ram_gb
          if (is.finite(cg_ram)) cg_ram - (RAMDISK_GB + 4) else Inf
        }, error = function(e) Inf)

        # Signal 4: Per-user contribution (only if UID available)
        s4_user_pct <- tryCatch({
          user_root <- file.path("/tmp", paste0("biome_", curr_user))
          if (!dir.exists(user_root)) return(0)
          user_bytes <- sum(file.info(
            list.files(user_root, all.files = TRUE, full.names = TRUE, recursive = TRUE)
          )$size, na.rm = TRUE)
          ramdisk_bytes <- RAMDISK_GB * 1024^3
          as.numeric(user_bytes / ramdisk_bytes * 100)
        }, error = function(e) 0)

        # Decision (pessimistic: ANY signal trips → unsafe)
        reasons <- c()
        if (s1_pct >= 70) reasons <- c(reasons, sprintf("tmpfs at %d%%", as.integer(s1_pct)))
        if (s2_mem_avail_gb < (RAMDISK_GB * 2)) reasons <- c(reasons, sprintf("MemAvail=%.0fGB", s2_mem_avail_gb))
        if (s3_cgroup_headroom_gb < 0) reasons <- c(reasons, "cgroup limit near")
        if (s4_user_pct > 30) reasons <- c(reasons, sprintf("user at %d%% of tmpfs", as.integer(s4_user_pct)))

        list(safe = length(reasons) == 0, reason = paste(reasons, collapse="; "), pct = s1_pct)
      }, error = function(e) list(safe = TRUE, reason = "", pct = 0))  # fail-open on error
    }
```

##### Change 3: Per-user tmp root + automatic NFS redirect in `deferred_pkg_init()`

Replace the current `smart_tmp_base` logic with:

```r
    force_nfs <- Sys.getenv("BIOME_FORCE_NFS_TMP") == "true"
    force_tmpfs <- Sys.getenv("BIOME_FORCE_TMPFS") == "true"  # User override: "I know what I'm doing"

    safety <- biome_tmpfs_safe()
    smart_tmp_base <- if (!ENABLE_SMART_ROUTING) "/tmp"
                      else if (force_tmpfs) "/tmp"   # User override, at their own risk
                      else if (force_nfs || !safety$safe) file.path(Sys.getenv("HOME"), ".r_tmp_fallback")
                      else "/tmp"
    if (!dir.exists(smart_tmp_base)) dir.create(smart_tmp_base, recursive = TRUE, showWarnings = FALSE)

    # Per-user tmp root (consolidates all per-package subdirs)
    user_tmp_root <- if (smart_tmp_base == "/tmp") file.path("/tmp", paste0("biome_", curr_user))
                     else file.path(smart_tmp_base, paste0("biome_", curr_user))
    if (!dir.exists(user_tmp_root)) dir.create(user_tmp_root, recursive = TRUE, showWarnings = FALSE)

    if (!safety$safe && !force_tmpfs && interactive()) {
      sys_log("TmpOverflow", "WARN", sprintf("Redirected to NFS: %s", safety$reason))
      warning(sprintf(
        paste0("BIOME-CALC: tmpfs unsafe (%s). Temp files redirected to NFS (%s).\n",
               "  This is slower but prevents OOM. Override: Sys.setenv(BIOME_FORCE_TMPFS = \"true\")"),
        safety$reason, smart_tmp_base
      ), call. = FALSE, immediate. = TRUE)
    }
```

Then update all per-package dirs to use `user_tmp_root`:

```r
    # terra
    td <- file.path(user_tmp_root, "terra")

    # raster
    rt <- file.path(user_tmp_root, "raster")

    # keras
    kt <- file.path(user_tmp_root, "keras_cache")

    # ggplot/plotly
    gt <- file.path(user_tmp_root, "plot_cache")
```

##### Change 4: Periodic re-check in `update_resources()` (auto-redirect mid-session)

Add tmpfs re-check after thread management in `update_resources()`:

```r
    # Re-check tmpfs safety every update cycle (catches mid-session growth)
    if (ENABLE_SMART_ROUTING) tryCatch({
      if (Sys.getenv("BIOME_FORCE_NFS_TMP") != "true" && Sys.getenv("BIOME_FORCE_TMPFS") != "true") {
        safety <- biome_tmpfs_safe()
        if (!safety$safe) {
          fallback <- file.path(Sys.getenv("HOME"), ".r_tmp_fallback")
          if (!dir.exists(fallback)) dir.create(fallback, recursive = TRUE, showWarnings = FALSE)
          user_fb <- file.path(fallback, paste0("biome_", curr_user))
          if (!dir.exists(user_fb)) dir.create(user_fb, recursive = TRUE, showWarnings = FALSE)
          Sys.setenv(BIOME_FORCE_NFS_TMP = "true", TMP = user_fb, TEMP = user_fb, TMPDIR = user_fb)
          sys_log("TmpOverflow", "WARN", sprintf("Mid-session redirect: %s", safety$reason))
          if (interactive()) {
            warning(sprintf(
              "BIOME-CALC: /tmp unsafe (%s). Auto-redirected to NFS: %s",
              safety$reason, user_fb
            ), call. = FALSE, immediate. = TRUE)
          }
        }
      }
    }, error = function(e) NULL)
```

##### Change 5: ggplot2/plotly engine with ragg backend (expanded)

Replace the existing ggplot2 block:

```r
    if (ENABLE_GGPLOT_OPT && (isNamespaceLoaded("ggplot2") || isNamespaceLoaded("plotly"))) tryCatch({
      gt <- file.path(user_tmp_root, "plot_cache")
      if (!dir.exists(gt)) dir.create(gt, recursive = TRUE, showWarnings = FALSE)
      Sys.setenv(TMP = gt, TEMP = gt)

      # Prefer ragg backend if available (2-4x faster than cairo)
      has_ragg <- requireNamespace("ragg", quietly = TRUE)
      if (has_ragg) options(device = ragg::agg_png)
      options(bitmapType = "cairo")  # Explicit fallback, never X11

      # Scientific color defaults (colorblind-safe)
      options(ggplot2.continuous.colour = "viridis", ggplot2.continuous.fill = "viridis")

      # Font cache warm-up (prevents first-plot latency on NFS homes)
      Sys.setenv(FONTCONFIG_PATH = "/etc/fonts")
      if (requireNamespace("systemfonts", quietly = TRUE)) {
        tryCatch(systemfonts::system_fonts(), error = function(e) NULL)
      }

      backend_label <- if (has_ragg) "ragg" else "cairo"
      tmp_label <- if (smart_tmp_base == "/tmp") "RAMDisk" else "NFS-Fallback"
      msg_parts <- c(msg_parts, sprintf("Ggplot [%s/%s]", backend_label, tmp_label))
    }, error = function(e) NULL)
```

##### Change 6: Worker TMP/TEMP propagation in `.biome_make_cluster_impl()`

Add `TMP`, `TEMP`, `TMPDIR`, `BIOME_FORCE_NFS_TMP` to worker env:

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

##### Change 7: `biome_plot_budget()` diagnostic tool

New tool in `tools:biome_calc` environment:

```r
  assign("biome_plot_budget", function() {
    cat(paste0("\n", .C_CYAN, "=== BIOME-CALC Plot Budget ===", .C_RESET, "\n"))
    # tmpfs info
    tmp_info <- tryCatch(
      system2("df", args = c("-P", "-BG", "/tmp"), stdout = TRUE, stderr = FALSE),
      error = function(e) NULL
    )
    if (!is.null(tmp_info) && length(tmp_info) >= 2) {
      p <- strsplit(trimws(tmp_info[2]), "\\s+")[[1]]
      cat(sprintf("  tmpfs Total: %s | Used: %s | Free: %s (%s)\n", p[2], p[3], p[4], p[5]))
    }
    # Render backend
    backend <- if (requireNamespace("ragg", quietly = TRUE)) "ragg (fast)" else "cairo (default)"
    cat(sprintf("  Render backend: %s\n", backend))
    # Tmp routing
    routing <- if (Sys.getenv("BIOME_FORCE_NFS_TMP") == "true") "NFS (safe for big data)" else "RAMDisk (fast)"
    cat(sprintf("  Tmp routing:    %s\n", routing))
    cat(sprintf("  R tempdir:      %s\n", tempdir()))
    # Per-user usage
    user_root <- file.path("/tmp", paste0("biome_", Sys.info()[["user"]]))
    if (dir.exists(user_root)) {
      sz <- sum(file.info(list.files(user_root, full.names = TRUE, recursive = TRUE, all.files = TRUE))$size, na.rm = TRUE)
      cat(sprintf("  Your tmp usage: ~%.1f MB\n", sz / 1024^2))
    }
    # Safety check
    safety <- tryCatch(biome_tmpfs_safe(), error = function(e) list(safe = TRUE, reason = ""))
    if (safety$safe) {
      cat(paste0("  Safety:         ", .C_GREEN, "OK — tmpfs is safe for heavy renders", .C_RESET, "\n"))
    } else {
      cat(paste0("  Safety:         ", .C_YELLOW, "WARNING — ", safety$reason, .C_RESET, "\n"))
    }
    cat(paste0("  ", .C_GRAY, "Tip: Override with Sys.setenv(BIOME_FORCE_TMPFS = \"true\") if you know your data fits.", .C_RESET, "\n\n"))
    invisible(NULL)
  }, envir = tool_env)
```

##### Change 8: Resilience fixes (from deep inspection)

**8a. Smart I/O `read.csv` override — save original for safe fallback**

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

**8b. `get_active_users()` — cap PID scan at 2000**

```r
  get_active_users <- function() {
    tryCatch({
      pids <- list.dirs("/proc", full.names = FALSE, recursive = FALSE)
      pids <- pids[grepl("^[0-9]+$", pids)]
      count <- 0L; scanned <- 0L
      for (p in pids) {
        scanned <- scanned + 1L
        if (scanned > 2000L) break  # Pessimistic: cap scan
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

**8c. `biome_save_session()` — workspace size warning**

```r
  assign("biome_save_session", function(file_name = "biome_session_backup.RData") {
    target <- file.path(Sys.getenv("HOME"), file_name)
    # Estimate workspace size
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
    message(paste0(.C_GREEN, "\n✅ Workspace safely preserved on disk!", .C_RESET, "\n"))
  }, envir = tool_env)
```

**8d. Cgroup refresh in `update_resources()`**

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

##### Change 9: Update tmp cleanup to use new per-user tmp root

```r
  if (ENABLE_TMP_CLEANUP && MY_UID >= 0) {
    tryCatch({
      # Clean both old-style and new-style user dirs
      all_tmp <- list.files("/tmp", pattern=paste0("^Rtmp|^terra_|^sf_|^arrow_|^rgee_|^gdalwarp_|^biome_", curr_user),
                           full.names=TRUE)
      if (length(all_tmp) > 0) {
        info <- file.info(all_tmp)
        age_h <- as.numeric(difftime(Sys.time(), info$mtime, units="hours"))
        limit_h <- .biome_env$shared_env$timeout_hours
        to_del <- all_tmp[!is.na(info$uid) & info$uid == MY_UID & age_h > limit_h]
        if (length(to_del) > 0) {
           unlink(to_del, recursive=TRUE, force=FALSE)
           sys_log("Cleanup", "OK", sprintf("Removed %d files older than %dh", length(to_del), limit_h))
        }
      }
    }, error = function(e) NULL)
  }
```

##### Change 10: Update `biome_tutorial()` and `biome_help()`

- Add `biome_plot_budget()` to the tools listing
- Update the "Massive Data / Tmpfs Bypass" section to explain the automatic redirect
- Add a new section on ggplot optimization

---

## Open Questions

> [!IMPORTANT]
> **Q1: NFS performance for plot temp files.** When the system auto-redirects to NFS, ggplot temp file I/O will be significantly slower (10-50x vs. tmpfs). Should we add a `message()` telling the user to consider reducing plot complexity, or just silently redirect? **Current plan: emit a warning once, then stay silent.**

> [!IMPORTANT]
> **Q2: `ragg` vs `cairo` as default.** Should `ragg::agg_png` be the default device for ALL users (via `options(device = ...)`) or only when ggplot2 is loaded? Setting it globally could break some users who expect `png()` behavior exactly. **Current plan: set it only inside the ggplot2 deferred init block, so it only applies when ggplot2 is actually loaded.**

> [!IMPORTANT]
> **Q3: Threshold lowering (85% → 70%).** This is the most impactful change. The 70% threshold is conservative — it will trigger NFS fallback earlier. Do you want a configurable threshold via `setup_nodes.vars.conf` (e.g., `TMPFS_OVERFLOW_PCT=70`)? **Current plan: hardcode 70% in the Rprofile template (pessimistic, not user-configurable).**

---

## Verification Plan

### Automated Tests

1. **R syntax validation**: `Rscript --vanilla -e "tryCatch({parse(file='Rprofile_site.R.template');cat('PARSE_OK')}, error=function(e) cat(sprintf('PARSE_FAIL: %s',e$message)))"`
2. **Template placeholder check**: `grep -oP '%%\w+%%' Rprofile_site.R.template | sort -u` — verify all placeholders have matching vars in `setup_nodes.vars.conf`
3. **Feature flag isolation**: Verify that setting `ENABLE_GGPLOT_OPT <- FALSE` disables all new ggplot code paths
4. **Worker fast-path verification**: Confirm PSOCK workers still exit early on line 110 without loading the ggplot/tmpfs engine
5. **`biome_tmpfs_safe()` unit test**: Mock `/proc/meminfo` with low MemAvailable and verify redirect triggers

### Manual Verification

1. Deploy to sandbox VM via `50_setup_nodes.sh` (menu option 3)
2. In RStudio: `library(ggplot2); status()` → verify `Ggplot [ragg/RAMDisk]` appears
3. `biome_plot_budget()` → verify output shows tmpfs status and safety check
4. Simulate tmpfs exhaustion: `dd if=/dev/zero of=/tmp/bigfile bs=1G count=75` → verify auto-redirect triggers
5. Verify user tmp consolidation: check `/tmp/biome_<user>/terra`, `/tmp/biome_<user>/plot_cache` exist
