# Rprofile v9.6 — Final Consolidated Implementation Plan

Upgrade Rprofile_site.R.template from v9.5 to v9.6 with multi-signal tmpfs heuristic, automatic NFS fallback, per-user tmp isolation, ragg backend, hardened save/load session, and resilience fixes.

> [!NOTE]
> **This plan consolidates three prior documents:**
> - `implementation_plan.md` (current, multi-signal heuristic design)
> - `implementation_plan_old.md` (original v9.6 draft, ggplot/ragg/resilience)
> - `implementation_plan_v9.6_updated_audit.md` (pessimistic PRD audit, terra size-routing, save_session SpatRaster bug)
>
> Conflicts are resolved in-place with rationale. Items marked `[FROM AUDIT]` originate from the PRD audit.

---

## Cross-Audit Summary: What Was Merged

| Feature | Current Plan | Old Plan | Audit | Final Verdict |
|---------|-------------|----------|-------|---------------|
| **Tmpfs threshold** | 70% single redirect | 80% single redirect | 60% warn / 75% redirect (dual) | ✅ **Dual: 60% warn + 75% redirect** (audit is correct — 70% has no warning path) |
| **Multi-signal heuristic** | 4-signal (df + MemAvail + cgroup + per-user) | Single df | Single df (correct per audit) | ✅ **Keep multi-signal but with correct df-primary** (audit validated df is correct, pure-R is flawed) |
| **Per-user tmp root** | `/tmp/biome_<user>/` consolidated | `/tmp/terra_<user>` scattered | Per-user monitor function | ✅ **Consolidated `/tmp/biome_<user>/` + per-user monitor** |
| **Terra size-aware routing** | Not present | Not present | ✅ BIG_DATA_THRESHOLD_GB=5 | ✅ **Add** (critical for ecology workloads) |
| **Smart I/O read.csv safety** | Save original + tryCatch | Save original + use saved fallback | Unchanged, correct | ✅ **Keep both improvements** (save original + use in `.biome_smart_io` fallback) |
| **biome_save_session size check** | `object.size()` on all objects | Same approach, 50GB threshold | ✅ **Exclude SpatRaster/stars/ff** (fatal flaw: forces file-backed objects into RAM) | ✅ **Audit version** (with `EXCLUDE_CLASSES` + 20GB threshold) |
| **biome_load_session audit** | No changes | No changes | Not covered | ✅ **NEW: Add disk space check + file size warning + integrity tryCatch** |
| **ragg deployment** | `50_setup_nodes.sh` + `vars.conf` | Same | Same | ✅ **Confirmed correct** — NOT `r_env_manager.sh` |
| **Worker TMP propagation** | Yes | Yes | Unchanged, correct | ✅ **Keep** |
| **biome_plot_budget()** | With safety check | Without safety check | Tip improvement | ✅ **Merged: safety check + improved tip text** |
| **Cgroup refresh** | 5-min in update_resources() | Same | Unchanged, correct | ✅ **Keep** |
| **get_active_users PID cap** | 2000 | 2000 | Unchanged, correct | ✅ **Keep** |
| **tmpfs noatime** | Not present | Not present | ✅ `noatime,nodiratime` in fstab | ✅ **Add** (zero risk, ~15% write amplification reduction) |
| **NFS fallback cleanup** | Cleanup `/tmp` only | Same | ✅ Also clean `~/.r_tmp_fallback` | ✅ **Add** (critical gap) |
| **Configurable thresholds** | Hardcoded | Hardcoded | ✅ Template placeholders from vars.conf | ✅ **Add** (operator-configurable via vars.conf) |
| **ENABLE_NFS_BIG_DATA flag** | Not present | Not present | ✅ New feature flag | ✅ **Add** |
| **zram** | Not discussed | Not discussed | ✅ **Explicitly rejected** | ✅ **Do NOT add zram** (quota isolation, not RAM capacity is the problem) |
| **xfsprogs apt dep** | Not present | Not present | ✅ For future quota enforcement | ❌ **Skip** — speculative, not needed now |

---

## User Review Required

> [!IMPORTANT]
> **Dual-threshold auto-redirect**: 60% = warn once, 75% = auto-redirect to NFS. Once redirected, session stays on NFS. User can force tmpfs: `Sys.setenv(BIOME_FORCE_TMPFS = "true")`. `[FROM AUDIT]`

> [!WARNING]
> **System dependency addition**: `ragg` requires `libfreetype-dev`, `libharfbuzz-dev`, `libfribidi-dev`, `libtiff-dev`, `libpng-dev` in `50_setup_nodes.sh` Step 1. Already present from `r_env_manager.sh::install_r_build_deps()` on bootstrapped systems.

> [!IMPORTANT]
> **biome_save_session fix**: The current `object.size()` scan will crash on large `SpatRaster`/`stars` objects that are file-backed — calling `object.size()` forces them into RAM. The plan adds an `EXCLUDE_CLASSES` list. `[FROM AUDIT]`

> [!IMPORTANT]  
> **biome_load_session gaps**: The current implementation has NO disk space check, NO file size warning for large loads, and NO error handling around `load()`. If a 200GB .RData file is loaded with 5GB free RAM, R OOM kills silently. The plan adds safety guards.

---

## Proposed Changes

### Configuration

#### [MODIFY] [setup_nodes.vars.conf](file:///home/jfs/00_Antigravity_workspace/R-studioConf/config/setup_nodes.vars.conf)

- Add `"ragg"`, `"svglite"`, `"systemfonts"` to `R_PACKAGES` array
- Bump `RPROFILE_VERSION` from `"9.3"` to `"9.6"`
- Add new tmpfs routing thresholds:

```bash
# Tmp routing thresholds (read by Rprofile template via %%PLACEHOLDER%%)
TMP_WARN_THRESHOLD_PCT=60       # Warn user at this global tmpfs fill %
TMP_REDIRECT_THRESHOLD_PCT=75   # Auto-redirect new allocations at this %
BIG_DATA_THRESHOLD_GB=5         # Operations > this always go to NFS
```

---

### System Dependencies

#### [MODIFY] [50_setup_nodes.sh](file:///home/jfs/00_Antigravity_workspace/R-studioConf/scripts/50_setup_nodes.sh)

**Step 1 (`setup_nodes_dependencies`)**: Add ragg system deps:
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

**Step 5 (`setup_nodes_ramdisk`)**: Add noatime `[FROM AUDIT]`:
```diff
- local fstab_entry="tmpfs /tmp tmpfs rw,nosuid,nodev,size=${RAMDISK_SIZE},mode=1777 0 0"
+ local fstab_entry="tmpfs /tmp tmpfs rw,nosuid,nodev,noatime,nodiratime,size=${RAMDISK_SIZE},mode=1777 0 0"
```
```diff
- run_cmd mount -o "remount,size=${RAMDISK_SIZE}" /tmp 2>/dev/null || mount /tmp 2>/dev/null || true
+ run_cmd mount -o "remount,size=${RAMDISK_SIZE},noatime,nodiratime" /tmp 2>/dev/null || mount /tmp 2>/dev/null || true
```

**Step 8 (`setup_nodes_config_files`)**: Add new template placeholders to the `process_template` call:
```diff
  process_template "${RPROFILE_TEMPLATE}" generated_profile \
    BIOME_HOST="${BIOME_HOST}" \
    RPROFILE_VERSION="${RPROFILE_VERSION}" \
    VM_VCORES="${VM_VCORES}" \
    VM_RAM_GB="${VM_RAM_GB}" \
    BIOME_CONTACT="${BIOME_CONTACT}" \
    MAX_BLAS_THREADS="${MAX_BLAS_THREADS}" \
    BIOME_CONF="${BIOME_CONF}" \
    LOG_FILE="${LOG_FILE}" \
    RAMDISK_GB="${RAMDISK_GB}" \
-   RSESSION_CONF_PATH="${RSESSION_CONF_PATH}"
+   RSESSION_CONF_PATH="${RSESSION_CONF_PATH}" \
+   TMP_WARN_THRESHOLD_PCT="${TMP_WARN_THRESHOLD_PCT:-60}" \
+   TMP_REDIRECT_THRESHOLD_PCT="${TMP_REDIRECT_THRESHOLD_PCT:-75}" \
+   BIG_DATA_THRESHOLD_GB="${BIG_DATA_THRESHOLD_GB:-5}"
```

**Step 9 (`setup_nodes_migrate_users`)**: Add `.r_tmp_fallback` to skel `[FROM AUDIT]`:
```bash
mkdir -p /etc/skel/.r_tmp_fallback
chmod 750 /etc/skel/.r_tmp_fallback
```

---

### Rprofile Template (main work)

#### [MODIFY] [Rprofile_site.R.template](file:///home/jfs/00_Antigravity_workspace/R-studioConf/templates/Rprofile_site.R.template)

**Version bump**: v9.5 → v9.6 in header comments.

---

##### Change 1: Feature flags (lines ~147–161)

```r
  ENABLE_GGPLOT_OPT    <- TRUE    # NEW: ragg backend + viridis defaults
  ENABLE_NFS_BIG_DATA  <- TRUE    # NEW [FROM AUDIT]: force NFS for ops > threshold

  # Tmpfs routing thresholds (configurable via vars.conf)
  TMP_WARN_PCT     <- %%TMP_WARN_THRESHOLD_PCT%%L    # Warn at this %
  TMP_REDIRECT_PCT <- %%TMP_REDIRECT_THRESHOLD_PCT%%L  # Hard redirect at this %
  BIG_DATA_THRESHOLD_GB <- %%BIG_DATA_THRESHOLD_GB%%L  # Ops > this always NFS
```

Add to shared_env initialization:
```r
  se$last_cgroup_check <- 0   # For periodic cgroup refresh
```

---

##### Change 2: `get_tmp_use_pct()` — keep `df` primary, add `/proc/mounts` fallback

> [!NOTE]
> **Audit resolved the `list.files` vs `df` debate**: `df` is correct (1ms fork cost is irrelevant at 30-second callback interval). Pure-R `list.files` **underestimates dramatically** for nested dirs. Keep `df` primary with `/proc/mounts` fallback for cgroup-constrained forks.

```r
    get_tmp_use_pct <- function() {
      tryCatch({
        df_out <- system2("df", args = c("-P", "-BG", "/tmp"),
                          stdout = TRUE, stderr = FALSE)
        if (length(df_out) >= 2) {
          parts <- strsplit(trimws(df_out[2]), "[[:space:]]+")[[1]]
          pct_str <- gsub("[^0-9]", "", parts[5])
          if (nchar(pct_str) > 0) return(as.numeric(pct_str))
        }
        0
      }, error = function(e) 0)
    }
```

---

##### Change 3: `biome_tmpfs_safe()` — multi-signal heuristic + configurable thresholds

```r
    biome_tmpfs_safe <- function() {
      tryCatch({
        # S1: tmpfs usage via df
        s1_pct <- get_tmp_use_pct()

        # S2: MemAvailable (kernel OOM proximity)
        s2_mem_avail_gb <- tryCatch({
          mi <- readLines("/proc/meminfo", warn = FALSE)
          al <- grep("^MemAvailable:", mi, value = TRUE)
          if (length(al) > 0) as.numeric(sub(".*:\\s+(\\d+).*", "\\1", al[1])) / 1024 / 1024
          else Inf
        }, error = function(e) Inf)

        # S3: cgroup headroom
        s3_cgroup_headroom_gb <- tryCatch({
          cg_ram <- .biome_env$shared_env$cgroup_ram_gb
          if (is.finite(cg_ram)) cg_ram - (RAMDISK_GB + 4) else Inf
        }, error = function(e) Inf)

        # S4: Per-user contribution
        s4_user_pct <- tryCatch({
          user_root <- file.path("/tmp", paste0("biome_", curr_user))
          if (!dir.exists(user_root)) return(0)
          user_bytes <- sum(file.info(
            list.files(user_root, all.files = TRUE, full.names = TRUE, recursive = TRUE)
          )$size, na.rm = TRUE)
          as.numeric(user_bytes / (RAMDISK_GB * 1024^3) * 100)
        }, error = function(e) 0)

        # Decision (pessimistic: ANY signal trips → unsafe)
        reasons <- c()
        if (s1_pct >= TMP_REDIRECT_PCT) reasons <- c(reasons, sprintf("tmpfs at %d%%", as.integer(s1_pct)))
        if (s2_mem_avail_gb < (RAMDISK_GB * 2)) reasons <- c(reasons, sprintf("MemAvail=%.0fGB", s2_mem_avail_gb))
        if (s3_cgroup_headroom_gb < 0) reasons <- c(reasons, "cgroup limit near")
        if (s4_user_pct > 30) reasons <- c(reasons, sprintf("user at %d%% of tmpfs", as.integer(s4_user_pct)))

        warn_reasons <- c()
        if (s1_pct >= TMP_WARN_PCT && s1_pct < TMP_REDIRECT_PCT) {
          warn_reasons <- c(warn_reasons, sprintf("tmpfs at %d%%", as.integer(s1_pct)))
        }

        list(
          safe = length(reasons) == 0,
          warn = length(warn_reasons) > 0,
          reason = paste(c(reasons, warn_reasons), collapse = "; "),
          pct = s1_pct
        )
      }, error = function(e) list(safe = TRUE, warn = FALSE, reason = "", pct = 0))
    }
```

---

##### Change 4: Per-user tmp root + NFS redirect in `deferred_pkg_init()`

Replace the current `smart_tmp_base` logic:

```r
    force_nfs <- Sys.getenv("BIOME_FORCE_NFS_TMP") == "true"
    force_tmpfs <- Sys.getenv("BIOME_FORCE_TMPFS") == "true"

    safety <- biome_tmpfs_safe()
    smart_tmp_base <- if (!ENABLE_SMART_ROUTING) "/tmp"
                      else if (force_tmpfs) "/tmp"
                      else if (force_nfs || !safety$safe) file.path(Sys.getenv("HOME"), ".r_tmp_fallback")
                      else "/tmp"
    if (!dir.exists(smart_tmp_base)) dir.create(smart_tmp_base, recursive = TRUE, showWarnings = FALSE)

    # Per-user tmp root (consolidates all per-package subdirs)
    user_tmp_root <- file.path(smart_tmp_base, paste0("biome_", curr_user))
    if (!dir.exists(user_tmp_root)) dir.create(user_tmp_root, recursive = TRUE, showWarnings = FALSE)

    # Redirect warning
    if (!safety$safe && !force_tmpfs && interactive()) {
      sys_log("TmpOverflow", "WARN", sprintf("Redirected to NFS: %s", safety$reason))
      warning(sprintf(
        paste0("BIOME-CALC: tmpfs unsafe (%s). Temp files redirected to NFS (%s).\n",
               "  This is slower but prevents OOM. Override: Sys.setenv(BIOME_FORCE_TMPFS = \"true\")"),
        safety$reason, smart_tmp_base
      ), call. = FALSE, immediate. = TRUE)
    } else if (safety$warn && !force_tmpfs && interactive()) {
      # Advisory warning at 60% — show once per session [FROM AUDIT]
      if (!isTRUE(getOption("biome_tmp_warn_shown"))) {
        options(biome_tmp_warn_shown = TRUE)
        message(sprintf(paste0(.C_YELLOW,
          "\n💡 BIOME-CALC: /tmp at %d%% capacity.",
          "\n   For large computations (>%d GB temp), consider:",
          "\n   Sys.setenv(BIOME_FORCE_NFS_TMP = 'true') before starting.",
          .C_RESET), as.integer(safety$pct), BIG_DATA_THRESHOLD_GB))
      }
    }
```

Update all per-package dirs to use `user_tmp_root`:

```r
    # terra → user_tmp_root/terra
    td <- file.path(user_tmp_root, "terra")

    # raster → user_tmp_root/raster
    rt <- file.path(user_tmp_root, "raster")

    # keras → user_tmp_root/keras_cache
    kt <- file.path(user_tmp_root, "keras_cache")

    # ggplot → user_tmp_root/plot_cache
    gt <- file.path(user_tmp_root, "plot_cache")
```

---

##### Change 5: Terra size-aware routing `[FROM AUDIT]`

Replace the terra init block with size-aware routing:

```r
    if (ENABLE_TERRA_OPT && isNamespaceLoaded("terra")) tryCatch({
      tt <- min(fc, 8L); gc_mb <- as.integer(floor(qr * 0.2 * 1024))
      Sys.setenv(GDAL_NUM_THREADS = as.character(tt),
                 GDAL_CACHEMAX   = as.character(gc_mb))

      # Size-aware routing [FROM AUDIT]: terra ops > BIG_DATA_THRESHOLD_GB always go to NFS
      if (isTRUE(ENABLE_NFS_BIG_DATA) && smart_tmp_base == "/tmp") {
        terra_use_gb <- tryCatch({
          td_chk <- file.path(user_tmp_root, "terra")
          if (!dir.exists(td_chk)) 0
          else {
            files <- list.files(td_chk, full.names = TRUE, recursive = TRUE, all.files = TRUE)
            if (length(files) == 0) 0
            else sum(file.info(files, extra_cols = FALSE)$size, na.rm = TRUE) / 1024^3
          }
        }, error = function(e) 0)

        if (terra_use_gb >= BIG_DATA_THRESHOLD_GB || safety$pct >= TMP_WARN_PCT) {
          terra_fallback <- file.path(Sys.getenv("HOME"), ".r_tmp_fallback",
                                      paste0("biome_", curr_user), "terra")
          if (!dir.exists(terra_fallback)) dir.create(terra_fallback, recursive = TRUE, showWarnings = FALSE)
          td <- terra_fallback
          routing_label <- "NFS-Safe"
        } else {
          td <- file.path(user_tmp_root, "terra")
          routing_label <- "RAMDisk"
        }
      } else {
        td <- file.path(user_tmp_root, "terra")
        routing_label <- if (smart_tmp_base == "/tmp") "RAMDisk" else "NFS-Fallback"
      }

      if (!dir.exists(td)) dir.create(td, recursive = TRUE, showWarnings = FALSE)
      terra::terraOptions(memfrac = 0.6, tempdir = td, verbose = FALSE)
      .biome_env$shared_env$terra_threads <- tt
      msg_parts <- c(msg_parts, sprintf("Terra [%s]", routing_label))
    }, error = function(e) NULL)
```

---

##### Change 6: ggplot2/plotly engine with ragg backend

```r
    if (ENABLE_GGPLOT_OPT && (isNamespaceLoaded("ggplot2") || isNamespaceLoaded("plotly"))) tryCatch({
      gt <- file.path(user_tmp_root, "plot_cache")
      if (!dir.exists(gt)) dir.create(gt, recursive = TRUE, showWarnings = FALSE)
      Sys.setenv(TMP = gt, TEMP = gt)

      has_ragg <- requireNamespace("ragg", quietly = TRUE)
      if (has_ragg) options(device = ragg::agg_png)
      options(bitmapType = "cairo")

      options(ggplot2.continuous.colour = "viridis", ggplot2.continuous.fill = "viridis")

      Sys.setenv(FONTCONFIG_PATH = "/etc/fonts")
      if (requireNamespace("systemfonts", quietly = TRUE)) {
        tryCatch(systemfonts::system_fonts(), error = function(e) NULL)
      }

      backend_label <- if (has_ragg) "ragg" else "cairo"
      tmp_label <- if (smart_tmp_base == "/tmp") "RAMDisk" else "NFS-Fallback"
      msg_parts <- c(msg_parts, sprintf("Ggplot [%s/%s]", backend_label, tmp_label))
    }, error = function(e) NULL)
```

---

##### Change 7: Dual-threshold re-check in `update_resources()` `[FROM AUDIT]`

```r
    # Dual-threshold tmpfs monitoring [FROM AUDIT]
    if (ENABLE_SMART_ROUTING) tryCatch({
      already_on_nfs <- (Sys.getenv("BIOME_FORCE_NFS_TMP") == "true")
      force_tmpfs <- (Sys.getenv("BIOME_FORCE_TMPFS") == "true")

      if (!already_on_nfs && !force_tmpfs) {
        safety <- biome_tmpfs_safe()
        if (!safety$safe) {
          # Hard redirect
          fallback <- file.path(Sys.getenv("HOME"), ".r_tmp_fallback")
          if (!dir.exists(fallback)) dir.create(fallback, recursive = TRUE, showWarnings = FALSE)
          user_fb <- file.path(fallback, paste0("biome_", curr_user))
          if (!dir.exists(user_fb)) dir.create(user_fb, recursive = TRUE, showWarnings = FALSE)
          Sys.setenv(BIOME_FORCE_NFS_TMP = "true", TMP = user_fb, TEMP = user_fb, TMPDIR = user_fb)
          sys_log("TmpOverflow", "WARN", sprintf("Mid-session redirect: %s", safety$reason))
          if (interactive()) message(sprintf(paste0(.C_YELLOW,
            "\n⚠️  BIOME-CALC: /tmp at %d%% — auto-redirected to NFS (%s).",
            "\n   This session will NOT revert to tmpfs (pessimistic).", .C_RESET),
            as.integer(safety$pct), user_fb))
        } else if (safety$warn) {
          # Advisory warn once [FROM AUDIT]
          if (!isTRUE(getOption("biome_tmp_warn_shown"))) {
            options(biome_tmp_warn_shown = TRUE)
            if (interactive()) message(sprintf(paste0(.C_YELLOW,
              "\n💡 BIOME-CALC: /tmp at %d%% capacity.",
              "\n   For large computations: Sys.setenv(BIOME_FORCE_NFS_TMP = 'true')", .C_RESET),
              as.integer(safety$pct)))
          }
        }
      }

      # Per-user quota monitor (always, even on NFS) [FROM AUDIT]
      if (!already_on_nfs) {
        tryCatch({
          user_root <- file.path("/tmp", paste0("biome_", curr_user))
          if (dir.exists(user_root)) {
            files <- list.files(user_root, full.names = TRUE, recursive = TRUE, all.files = TRUE)
            if (length(files) > 0) {
              user_gb <- sum(file.info(files, extra_cols = FALSE)$size, na.rm = TRUE) / 1024^3
              if (user_gb > 10 && interactive() && !isTRUE(getOption("biome_user_quota_warned"))) {
                options(biome_user_quota_warned = TRUE)
                warning(sprintf(
                  "BIOME-CALC: Your temp files in /tmp are using %.1f GB. Consider Sys.setenv(BIOME_FORCE_NFS_TMP='true').",
                  user_gb), call. = FALSE, immediate. = TRUE)
              }
            }
          }
        }, error = function(e) NULL)
      }
    }, error = function(e) NULL)

    # Periodic cgroup refresh (every 5 minutes)
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

---

##### Change 8: Worker TMP/TEMP/TMPDIR propagation

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

---

##### Change 9: `biome_save_session()` — HARDENED `[FROM AUDIT]`

> [!CAUTION]
> **Critical bug in current code**: `object.size()` on `SpatRaster`/`stars` objects forces file-backed data into RAM, potentially causing OOM during the *size estimate*, before the save even starts. The audit correctly identifies this.

```r
  assign("biome_save_session", function(file_name = "biome_session_backup.RData") {
    target <- file.path(Sys.getenv("HOME"), file_name)

    # [FROM AUDIT] Exclude file-backed spatial classes from size estimate
    EXCLUDE_CLASSES <- c("SpatRaster", "SpatVector", "stars", "RasterStack",
                          "RasterBrick", "ff", "bigmemory")
    ws_objects <- ls(envir = .GlobalEnv)
    ws_size <- 0
    excluded_count <- 0L
    for (obj_name in ws_objects) {
      obj <- tryCatch(get(obj_name, envir = .GlobalEnv, inherits = FALSE), error = function(e) NULL)
      if (!is.null(obj)) {
        if (inherits(obj, EXCLUDE_CLASSES)) {
          excluded_count <- excluded_count + 1L
        } else {
          ws_size <- ws_size + tryCatch(as.numeric(object.size(obj)), error = function(e) 0)
        }
      }
    }
    ws_gb <- ws_size / 1024^3

    if (ws_gb > 20) {
      message(sprintf(paste0(.C_YELLOW,
        "\n⚠️  WARNING: Non-spatial workspace is ~%.1f GB.",
        "\n   %d large spatial objects excluded from estimate (they are file-backed).",
        "\n   Consider: save(obj1, obj2, file='my_data.RData') to save selectively.",
        .C_RESET), ws_gb, excluded_count))
    } else if (excluded_count > 0) {
      message(sprintf(paste0(.C_GRAY,
        "   ℹ %d spatial object(s) will be included but may be large on disk.", .C_RESET),
        excluded_count))
    }

    # Check disk space on HOME before writing
    tryCatch({
      df_home <- system2("df", args = c("-P", "-BG", Sys.getenv("HOME")),
                          stdout = TRUE, stderr = FALSE)
      if (length(df_home) >= 2) {
        free_gb <- as.numeric(gsub("[^0-9]", "", strsplit(trimws(df_home[2]), "\\s+")[[1]][4]))
        if (!is.na(free_gb) && free_gb < max(ws_gb * 2, 5)) {
          warning(sprintf(paste0(.C_RED,
            "\n⚠️  LOW DISK: Only ~%d GB free on HOME. Save may fail or fill quota!", .C_RESET),
            as.integer(free_gb)), call. = FALSE, immediate. = TRUE)
        }
      }
    }, error = function(e) NULL)

    message(paste0("\n💾 Saving to: ", target, " ..."))
    tryCatch({
      save.image(file = target)
      final_size <- tryCatch(file.info(target)$size / 1024^2, error = function(e) NA)
      if (!is.na(final_size)) {
        message(sprintf(paste0(.C_GREEN, "✅ Done (%.1f MB). You may now safely log out.", .C_RESET), final_size))
      } else {
        message(paste0(.C_GREEN, "✅ Done. You may now safely log out.", .C_RESET))
      }
    }, error = function(e) {
      message(sprintf(paste0(.C_RED, "\n❌ SAVE FAILED: %s", .C_RESET), e$message))
    })
  }, envir = tool_env)
```

---

##### Change 10: `biome_load_session()` — HARDENED (NEW)

> [!WARNING]
> **Current code has zero safety guards**: no file size check, no disk/RAM check, no tryCatch around `load()`, no feedback on what was loaded. If a user loads a 200GB .RData into a session with 5GB free RAM, R silently OOM kills.

```r
  assign("biome_load_session", function(file_name = "biome_session_backup.RData") {
    target <- file.path(Sys.getenv("HOME"), file_name)
    if (!file.exists(target)) {
      warning(paste0(.C_RED, "⚠️ No backup found at ", target, ". Have you saved it yet?", .C_RESET, "\n"),
              call. = FALSE, immediate. = TRUE)
      return(invisible(NULL))
    }

    # Safety: check file size vs available RAM
    file_mb <- tryCatch(file.info(target)$size / 1024^2, error = function(e) NA)
    if (!is.na(file_mb)) {
      ram_avail_mb <- tryCatch({
        mi <- readLines("/proc/meminfo", warn = FALSE)
        al <- grep("^MemAvailable:", mi, value = TRUE)
        if (length(al) > 0) as.numeric(sub(".*:\\s+(\\d+).*", "\\1", al[1])) / 1024
        else Inf
      }, error = function(e) Inf)

      if (file_mb > 5000) {
        message(sprintf(paste0(.C_YELLOW,
          "\n⚠️  Large file: %.1f GB. Loading may take a while.", .C_RESET),
          file_mb / 1024))
      }
      if (is.finite(ram_avail_mb) && file_mb > ram_avail_mb * 0.5) {
        warning(sprintf(paste0(.C_RED,
          "\n⚠️  DANGER: File is %.1f GB but only %.1f GB RAM available.",
          "\n   Loading may cause OOM. Consider loading selectively:",
          "\n   env <- new.env(); load('%s', envir=env); ls(env)", .C_RESET),
          file_mb / 1024, ram_avail_mb / 1024, target),
          call. = FALSE, immediate. = TRUE)
      }
    }

    message(paste0("\n🔄 Loading workspace from: ", target, " ..."))
    tryCatch({
      before_objs <- ls(envir = .GlobalEnv)
      load(file = target, envir = .GlobalEnv)
      after_objs <- ls(envir = .GlobalEnv)
      new_objs <- setdiff(after_objs, before_objs)
      message(sprintf(paste0(.C_GREEN, "✅ Workspace restored! %d objects loaded.",
        if (length(new_objs) > 0 && length(new_objs) <= 10) " New: %s" else "", .C_RESET),
        length(after_objs),
        if (length(new_objs) > 0 && length(new_objs) <= 10) paste(new_objs, collapse = ", ") else ""))
    }, error = function(e) {
      message(sprintf(paste0(.C_RED, "\n❌ LOAD FAILED: %s",
        "\n   The file may be corrupted or too large for available RAM.", .C_RESET), e$message))
    })
  }, envir = tool_env)
```

---

##### Change 11: `biome_plot_budget()` diagnostic tool (merged)

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
    routing <- if (Sys.getenv("BIOME_FORCE_NFS_TMP") == "true") "NFS (safe for big data)" else "RAMDisk (fast)"
    cat(sprintf("  Tmp routing:    %s\n", routing))
    cat(sprintf("  R tempdir:      %s\n", tempdir()))
    user_root <- file.path("/tmp", paste0("biome_", Sys.info()[["user"]]))
    if (dir.exists(user_root)) {
      sz <- sum(file.info(list.files(user_root, full.names = TRUE, recursive = TRUE, all.files = TRUE))$size, na.rm = TRUE)
      cat(sprintf("  Your tmp usage: ~%.1f MB\n", sz / 1024^2))
    }
    safety <- tryCatch(biome_tmpfs_safe(), error = function(e) list(safe = TRUE, warn = FALSE, reason = ""))
    if (safety$safe && !safety$warn) {
      cat(paste0("  Safety:         ", .C_GREEN, "OK — tmpfs is safe for heavy renders", .C_RESET, "\n"))
    } else if (safety$warn) {
      cat(paste0("  Safety:         ", .C_YELLOW, "ADVISORY — ", safety$reason, .C_RESET, "\n"))
    } else {
      cat(paste0("  Safety:         ", .C_RED, "REDIRECT ACTIVE — ", safety$reason, .C_RESET, "\n"))
    }
    # [FROM AUDIT] improved tip
    cat(paste0("  ", .C_GRAY,
      "Tip: ggsave(width=20, height=15, dpi=300) ≈ 80 MB. At dpi=600 ≈ 320 MB.",
      "\n       Override: Sys.setenv(BIOME_FORCE_TMPFS = \"true\")", .C_RESET, "\n\n"))
    invisible(NULL)
  }, envir = tool_env)
```

---

##### Change 12: Smart I/O `read.csv` — save original + safer fallback

```r
  if (ENABLE_SMART_IO) {
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
      # Use saved original to avoid infinite recursion [FROM OLD PLAN]
      orig <- tryCatch(get("original_read_csv", envir = .biome_env), error = function(e) NULL)
      if (!is.null(orig)) return(orig(file, ...))
      return(utils::read.csv(file, ...))
    }
    if (requireNamespace("utils", quietly=TRUE)) tryCatch({
      ue <- as.environment("package:utils")
      if (exists("read.csv", envir=ue)) {
        .biome_env$original_read_csv <- get("read.csv", envir = ue)  # Save original
        lk <- tryCatch(bindingIsLocked("read.csv",ue), error=function(e)TRUE)
        if (lk) { unlockBinding("read.csv",ue); assign("read.csv",.biome_smart_io,envir=ue); lockBinding("read.csv",ue) }
      }
    }, error=function(e) NULL)
    # ... fread hook unchanged ...
  }
```

---

##### Change 13: `get_active_users()` — PID cap at 2000

```r
  get_active_users <- function() {
    tryCatch({
      pids <- list.dirs("/proc", full.names = FALSE, recursive = FALSE)
      pids <- pids[grepl("^[0-9]+$", pids)]
      count <- 0L; scanned <- 0L
      for (p in pids) {
        scanned <- scanned + 1L
        if (scanned > 2000L) break
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

---

##### Change 14: Tmp cleanup — clean both `/tmp` and `~/.r_tmp_fallback` `[FROM AUDIT]`

```r
  if (ENABLE_TMP_CLEANUP && MY_UID >= 0) {
    tryCatch({
      # Clean /tmp: old-style scattered dirs + new consolidated biome_ dirs
      all_tmp <- list.files("/tmp",
        pattern=paste0("^Rtmp|^terra_|^sf_|^arrow_|^rgee_|^gdalwarp_|^biome_", curr_user),
        full.names=TRUE)
      if (length(all_tmp) > 0) {
        info <- file.info(all_tmp)
        age_h <- as.numeric(difftime(Sys.time(), info$mtime, units="hours"))
        limit_h <- .biome_env$shared_env$timeout_hours
        to_del <- all_tmp[!is.na(info$uid) & info$uid == MY_UID & age_h > limit_h]
        if (length(to_del) > 0) {
           unlink(to_del, recursive=TRUE, force=FALSE)
           sys_log("Cleanup", "OK", sprintf("Removed %d /tmp items older than %dh", length(to_del), limit_h))
        }
      }
    }, error = function(e) NULL)

    # [FROM AUDIT] Also clean NFS fallback dir
    tryCatch({
      nfs_fallback <- file.path(Sys.getenv("HOME"), ".r_tmp_fallback")
      if (dir.exists(nfs_fallback)) {
        all_nfs_tmp <- list.files(nfs_fallback, full.names = TRUE, recursive = FALSE)
        if (length(all_nfs_tmp) > 0) {
          info <- file.info(all_nfs_tmp)
          age_h <- as.numeric(difftime(Sys.time(), info$mtime, units="hours"))
          limit_h <- .biome_env$shared_env$timeout_hours
          to_del <- all_nfs_tmp[!is.na(info$uid) & info$uid == MY_UID & age_h > limit_h]
          if (length(to_del) > 0) {
            bytes_freed <- sum(info$size[match(to_del, rownames(info))], na.rm = TRUE)
            unlink(to_del, recursive = TRUE, force = FALSE)
            sys_log("NfsTmpCleanup", "OK", sprintf("Removed %d NFS fallback items (%.1f GB)",
                    length(to_del), bytes_freed / 1024^3))
          }
        }
      }
    }, error = function(e) NULL)
  }
```

---

##### Change 15: Update `biome_tutorial()` and `biome_help()`

- Add `biome_plot_budget()` to tools listing in both functions
- Update the "Massive Data / Tmpfs Bypass" tutorial section to explain automatic dual-threshold redirect
- Add ggplot optimization section mentioning ragg
- Update save/load description with safety info

---

## Open Questions — RESOLVED

| Question | Resolution | Source |
|----------|-----------|--------|
| Q1: NFS perf for plot temps | Emit warning once, then silent. Plots are typically <500MB; ragg 2-4x speedup offsets NFS latency | Audit §6 |
| Q2: ragg global vs ggplot-only | ggplot deferred init only. Global breaks knitr backends | Audit §6 |
| Q3: Threshold 85→70 vs 85→75 | **Dual: 60% warn + 75% redirect** (configurable via vars.conf) | Audit §4.1 |
| Q4: Session persistence of NFS redirect | Once NFS, always NFS for session. terra file handles break on re-route | Audit §6 |
| Q5: NFS fallback cleanup | Added — clean `~/.r_tmp_fallback` with same age threshold as `/tmp` | Audit §6 |
| Q6: save_session SpatRaster crash | Exclude `EXCLUDE_CLASSES` from `object.size()` scan | Audit §4.9 |
| Q7: load_session safety | NEW — add RAM check, file size warning, tryCatch, object count feedback | This plan |
| Q8: zram | **Do NOT add**. Problem is quota isolation, not RAM capacity | Audit §1.2 |

---

## Verification Plan

### Automated Tests

1. **R syntax**: `Rscript --vanilla -e "tryCatch({parse(file='Rprofile_site.R.template');cat('PARSE_OK')}, error=function(e) cat(sprintf('PARSE_FAIL: %s',e$message)))"`
2. **Placeholders**: `grep -oP '%%\w+%%' Rprofile_site.R.template | sort -u` → verify all have matching vars
3. **Feature flags**: `ENABLE_GGPLOT_OPT <- FALSE` disables all ggplot code paths
4. **Worker fast-path**: PSOCK workers exit at line 110 without loading ggplot/tmpfs engine
5. **Save session safety**: `SpatRaster` object present → no OOM during size estimate
6. **Load session safety**: 200GB .RData with 5GB MemAvail → warning emitted, not silent OOM

### Manual Verification (Sandbox via `50_setup_nodes.sh` option 3)

| Step | Test | Expected |
|------|------|----------|
| 1 | `library(ggplot2); status()` | Shows `Ggplot [ragg/RAMDisk]` |
| 2 | `biome_plot_budget()` | Shows tmpfs status + safety |
| 3 | `dd if=/dev/zero of=/tmp/fill bs=1G count=65` | Warning at 60% (advisory) |
| 4 | `dd if=/dev/zero of=/tmp/fill2 bs=1G count=10` | Hard redirect at 75% |
| 5 | `Sys.getenv("BIOME_FORCE_NFS_TMP")` | Returns `"true"` |
| 6 | `library(terra); terra::terraOptions()$tempdir` | Shows NFS path |
| 7 | `biome_save_session()` with SpatRaster in env | No crash, warning about excluded objects |
| 8 | `biome_load_session()` | Shows object count, warns if large |
| 9 | `/tmp/biome_<user>/terra` exists | Consolidated structure |
| 10 | `~/.r_tmp_fallback` cleaned after timeout | Stale files removed |
