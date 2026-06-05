# scripts/99_diagnose_rstudio_plot_pane.R
# ==============================================================================
# BIOME-CALC: RSTUDIO PLOT PANE VISUALIZATION DIAGNOSTIC & REPAIR TOOL
# ==============================================================================
# Target: RStudio Server User Session
# Purpose: Diagnoses why plots fail to appear in the RStudio "Plots" pane
#          even when rendering commands execute successfully without errors.
# Usage:   Run in RStudio console:
#          source("/home/jfs/00_Antigravity_workspace/R-studioConf/scripts/99_diagnose_rstudio_plot_pane.R")
# ==============================================================================

message("\n==================================================================")
message("   RSTUDIO PLOT PANE DIAGNOSTIC & REPAIR TOOL")
message("   Start Time: ", format(Sys.time(), "%Y-%m-%d %H:%M:%S"))
message("==================================================================\n")

diag_ok <- TRUE

# ------------------------------------------------------------------------------
# TEST 1: Reset Graphics Devices (Clear Stale / Blocked Devices)
# ------------------------------------------------------------------------------
message("[TEST 1] Checking and resetting graphics device stack...")
open_devs <- dev.list()
if (!is.null(open_devs)) {
  message(sprintf(
    "  [WARN] Found %d active graphics devices: %s",
    length(open_devs), paste(names(open_devs), collapse = ", ")
  ))
  message("  [ACTION] Closing all active graphics devices to clear blocking file writes...")
  graphics.off()
  message("  [OK] Graphics stack reset.")
} else {
  message("  [OK] No active graphics devices found (clean stack).")
}

# ------------------------------------------------------------------------------
# TEST 2: Verify options("device") Configuration
# ------------------------------------------------------------------------------
message("\n[TEST 2] Checking options('device') configuration...")
current_device <- options("device")[[1]]

# Detect whether we are inside an interactive RStudio Server session.
# RStudio sets RSTUDIO=1 and RSTUDIO_USER_IDENTITY in the rsession process.
is_interactive_rstudio <- interactive() &&
  (nzchar(Sys.getenv("RSTUDIO", "")) ||
    nzchar(Sys.getenv("RSTUDIO_USER_IDENTITY", "")))

# Known file-writing devices that silently replace RStudioGD and cause
# the "plots not showing in browser" symptom. ragg::agg_png is the most
# common culprit — it is set by a stale Rprofile_site.d/50_pkg_hooks.R
# fragment that lacks the v12.2 RStudioGD guard.
file_device_patterns <- c(
  "agg_png", "agg_tiff", "agg_jpeg",
  "png", "jpeg", "tiff", "bmp",
  "pdf", "svg", "cairo_pdf", "cairo_ps",
  "postscript", "xfig", "pictex"
)

device_is_file_writer <- function(dev_obj) {
  if (is.function(dev_obj)) {
    dev_text <- paste(deparse(dev_obj), collapse = " ")
    any(vapply(file_device_patterns, function(pat) grepl(pat, dev_text, ignore.case = TRUE), logical(1)))
  } else if (is.character(dev_obj)) {
    tolower(dev_obj) %in% file_device_patterns
  } else {
    FALSE
  }
}

if (is.function(current_device)) {
  dev_text <- paste(deparse(current_device), collapse = " ")
  if (grepl("RStudioGD", dev_text)) {
    message("  [OK] Device function points to RStudioGD (correct for RStudio Server).")
  } else if (is_interactive_rstudio && device_is_file_writer(current_device)) {
    message("  [CRITICAL] options('device') is a FILE-WRITING device, NOT RStudioGD!")
    message("             This is the #1 cause of 'plots not showing' in RStudio Server.")
    message("             Detected device: ", substr(dev_text, 1, 120))
    message("  [ACTION] Restoring options(device = 'RStudioGD') for this session...")
    options(device = "RStudioGD")
    diag_ok <- FALSE
    message("  [ACTION] options(device = 'RStudioGD') applied.")
    message("  [ROOT CAUSE] A stale Rprofile_site.d/50_pkg_hooks.R fragment on this")
    message("              node sets options(device = ragg::agg_png) unconditionally.")
    message("              The v12.2+ template guards this behind is_interactive_rstudio.")
    message("              Ask your sysadmin to run:")
    message("                sudo bash scripts/50_setup_nodes.sh")
    message("                # select option 3 (Config files only)")
    message("                sudo systemctl restart rstudio-server")
  } else {
    message("  [WARN] Device function does not explicitly mention RStudioGD. Content:")
    message("         ", substr(dev_text, 1, 80), "...")
  }
} else if (is.character(current_device)) {
  message("  [INFO] options('device') is character: '", current_device, "'")
  if (is_interactive_rstudio && device_is_file_writer(current_device)) {
    message("  [CRITICAL] options('device') = '", current_device, "' is a file device, NOT RStudioGD!")
    message("  [ACTION] Restoring options(device = 'RStudioGD') for this session...")
    options(device = "RStudioGD")
    diag_ok <- FALSE
    message("  [ACTION] options(device = 'RStudioGD') applied.")
  } else if (current_device != "RStudioGD") {
    message("  [WARN] Default device is NOT 'RStudioGD'. Restoring default...")
    options(device = "RStudioGD")
    message("  [ACTION] options(device = 'RStudioGD') applied.")
  } else {
    message("  [OK] Default device is set to 'RStudioGD'.")
  }
} else {
  message("  [WARN] options('device') is invalid. Restoring RStudioGD...")
  options(device = "RStudioGD")
  diag_ok <- FALSE
}

# ------------------------------------------------------------------------------
# TEST 3: Check Temp Directory & Session tmpfs Routing
# ------------------------------------------------------------------------------
message("\n[TEST 3] Verifying R Temp Directory permissions & capacity...")
r_temp <- tempdir()
message("  * R tempdir() path: ", r_temp)

if (!dir.exists(r_temp)) {
  message("  [CRITICAL] R tempdir() does not exist! This breaks RStudio plotting.")
  diag_ok <- FALSE
} else {
  # Test write access
  test_file <- file.path(r_temp, "plot_pane_write_test.tmp")
  write_ok <- tryCatch(
    {
      writeLines("test", test_file)
      file.remove(test_file)
      TRUE
    },
    error = function(e) FALSE
  )

  if (write_ok) {
    message("  [OK] R tempdir() is writeable.")
  } else {
    message("  [CRITICAL] R tempdir() is NOT writeable! Check permissions or disk quota.")
    diag_ok <- FALSE
  }
}

# ------------------------------------------------------------------------------
# TEST 4: Check RStudio User-Data Directory (NFS Home locks)
# ------------------------------------------------------------------------------
message("\n[TEST 4] Verifying RStudio Local Data Directory (NFS storage status)...")
home_dir <- Sys.getenv("HOME")
rstudio_data_dir <- file.path(home_dir, ".local/share/rstudio")
rstudio_legacy_dir <- file.path(home_dir, ".rstudio")

# Locate active config directory
active_rstudio_dir <- NULL
if (dir.exists(rstudio_data_dir)) {
  active_rstudio_dir <- rstudio_data_dir
} else if (dir.exists(rstudio_legacy_dir)) {
  active_rstudio_dir <- rstudio_legacy_dir
}

if (is.null(active_rstudio_dir)) {
  message("  [WARN] No RStudio local data directory found in home. (Will be created by IDE).")
} else {
  message("  * Active RStudio directory: ", active_rstudio_dir)
  # Test writing in plot history directory
  plot_hist_dir <- file.path(active_rstudio_dir, "plots")
  if (dir.exists(plot_hist_dir)) {
    test_hist_file <- file.path(plot_hist_dir, "write_test.tmp")
    hist_write_ok <- tryCatch(
      {
        writeLines("test", test_hist_file)
        file.remove(test_hist_file)
        TRUE
      },
      error = function(e) FALSE
    )

    if (hist_write_ok) {
      message("  [OK] Plot history folder is writeable.")
    } else {
      message("  [WARN] Plot history folder is NOT writeable! Stale NFS lock or quota full.")
      message("         This causes the Plot pane to silently fail.")
      diag_ok <- FALSE
    }
  } else {
    message("  [INFO] Plot history folder does not exist yet.")
  }
}

# ------------------------------------------------------------------------------
# TEST 5: Interactive Base R Rendering Test
# ------------------------------------------------------------------------------
message("\n[TEST 5] Testing baseline graphics rendering (Base R plot)...")
test_base_ok <- tryCatch(
  {
    # Attempt to open default RStudio graphics device and draw a simple point
    plot(1, 1, main = "RStudio Plot Diagnostics Test")
    TRUE
  },
  error = function(e) {
    message("  [CRITICAL] Base R plotting failed! Error message:")
    message("             ", e$message)
    FALSE
  }
)

if (test_base_ok) {
  message("  [OK] Base R plot command executed without error.")
} else {
  diag_ok <- FALSE
}

# ------------------------------------------------------------------------------
# TEST 6: Interactive ggplot2 Rendering Test
# ------------------------------------------------------------------------------
message("\n[TEST 6] Testing ggplot2 rendering (Vector to RStudioGD)...")
if (requireNamespace("ggplot2", quietly = TRUE)) {
  test_gg_ok <- tryCatch(
    {
      p_test <- ggplot2::ggplot(data.frame(x = 1:5, y = 1:5), ggplot2::aes(x = x, y = y)) +
        ggplot2::geom_point() +
        ggplot2::labs(title = "ggplot2 Diagnostics Test")
      print(p_test)
      TRUE
    },
    error = function(e) {
      message("  [CRITICAL] ggplot2 plotting failed! Error message:")
      message("             ", e$message)
      FALSE
    }
  )

  if (test_gg_ok) {
    message("  [OK] ggplot2 plot print command executed without error.")
  } else {
    diag_ok <- FALSE
  }
} else {
  message("  [WARN] ggplot2 not available. Skipping ggplot2 diagnostic test.")
}

# ------------------------------------------------------------------------------
# DIAGNOSTIC SUMMARY & ACTION PLAN
# ------------------------------------------------------------------------------
cat("\n\n==================================================================\n")
cat("                RSTUDIO PLOT VISUALIZATION SUMMARY\n")
cat("==================================================================\n")
if (diag_ok) {
  cat("  ✅ [DIAGNOSTIC STATUS: healthy]\n")
  cat("     The R session configuration, temp directory, and permissions are normal.\n")
  cat("     If the plot is STILL not visible in the browser, check these frontend issues:\n\n")
  cat("     1. **Pane Layout**: The 'Plots' pane on the bottom-right may be minimized\n")
  cat("        or collapsed. Drag the panel divider up or click the 'Plots' tab.\n")
  cat("     2. **Browser Rendering / Ad-Blocker**: Ad-blockers or privacy extensions\n")
  cat("        can block RStudio WebSocket events. Try disabling ad-blockers for this URL.\n")
  cat("     3. **Zoom / Window State**: RStudio graphics engine will hide plots if the\n")
  cat("        dimensions of the Plot panel are too small (e.g. 0 x 0 pixels).\n")
  cat("        Try clicking the 'Zoom' button in the Plot tab.\n")
  cat("     4. **Browser Cache / Hang**: Resize your browser window or the RStudio pane.\n")
  cat("        This forces a redraw event over the WebSocket.\n")
} else {
  cat("  ❌ [DIAGNOSTIC STATUS: issues detected]\n")
  cat("     The system has settings or permission blocks preventing plotting.\n\n")
  cat("     **ACTION PLAN TO REPAIR:**\n")
  cat("     1. **Clear Graphics Stack**: Run 'graphics.off()' in your console to release\n")
  cat("        stale pdf/png file locks.\n")
  cat("     2. **Fix permissions**: If NFS Home or /Rtmp has full quota or wrong permissions,\n")
  cat("        contact the system administrator to verify write access.\n")
  cat("     3. **Clean RStudio Session Cache**: Stale session lock files can freeze plotting.\n")
  cat("        To reset the state, run these commands in the terminal (outside R):\n")
  cat("          rm -rf ~/.local/share/rstudio/plots/*\n")
  cat("          rm -rf ~/.local/share/rstudio/pcs/*\n")
  cat("          rstudio-server restart-session\n")
}
cat("==================================================================\n\n")
