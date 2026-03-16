# ==============================================================================
# check_installed_R_Package.R
# Enhanced BIOME-CALC R Environment & Ecosystem Diagnostics
# ==============================================================================

options(warn = -1)

# --- 1. Environment Header ---
cat("============================================================\n")
cat("  BIOME-CALC: R Environment Report\n")
cat("============================================================\n")
cat(sprintf("%-25s: %s\n", "R Version", R.version$version.string))
cat(sprintf("%-25s: %s\n", "Platform", R.version$platform))
cat(sprintf("%-25s: %s\n", "Default UI", Sys.getenv("RSTUDIO_SESSION_PORT", unset = "Terminal (non-RStudio)")))

# --- 2. Critical Performance Vars ---
cat("\n--- Performance & Library Context ---\n")
critical_vars <- c("OPENBLAS_CORETYPE", "MKL_DEBUG_CPU_TYPE", "LD_LIBRARY_PATH", "R_LIBS_USER", "R_LIBS_SITE")
for (v in critical_vars) {
  val <- Sys.getenv(v, unset = "N/A")
  # Truncate long paths for readability
  if (nchar(val) > 60) val <- paste0(substr(val, 1, 57), "...")
  cat(sprintf("%-25s: %s\n", v, val))
}

# --- 3. Ecosystem Summary ---
cat("\n--- Ecosystem Check (BIOME Packages) ---\n")
pkgs <- installed.packages()[, "Package"]

check_ecosystem <- function(name, members) {
  found <- members[members %in% pkgs]
  status <- if (length(found) == length(members)) {
    "[OK] All present"
  } else if (length(found) > 0) {
    sprintf("[PARTIAL] %d/%d present", length(found), length(members))
  } else {
    "[MISSING]"
  }
  cat(sprintf("%-20s: %s\n", name, status))
  if (length(found) > 0 && length(found) < length(members)) {
    cat(sprintf("  Missing: %s\n", paste(members[!members %in% pkgs], collapse = ", ")))
  }
}

check_ecosystem("Tidyverse", c("dplyr", "ggplot2", "tidyr", "readr", "purrr", "stringr", "forcats"))
check_ecosystem("Geospatial", c("sf", "terra", "stars", "rgee", "gdalcubes"))
check_ecosystem("Parallel/HPC", c("future", "snow", "BiocParallel", "batchtools", "clustermq"))
check_ecosystem("Machine Learning", c("torch", "keras", "reticulate", "randomForest", "xgboost"))
check_ecosystem("BIOME Core", c("R-studioConf", "audit")) # Placeholder if they exist as R pkgs

# --- 4. Package Info (Audit File) ---
cat("\nGenerating CSV audit: installed_packages.csv ...\n")
package_info <- as.data.frame(installed.packages()[, c("Package", "Version", "Built", "LibPath")])
write.csv(package_info, file = "installed_packages.csv", row.names = FALSE)
cat("Done.\n")
cat("============================================================\n")
