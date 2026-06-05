# scripts/99_botanical_plot_stress_test.R
# ==============================================================================
# BIOME-CALC: BOTANICAL PLOT STRESS TEST & GRAPHICS SYSTEM DIAGNOSTIC
# ==============================================================================
# Target: RStudio Server / R 4.6.0 environment (X11 = FALSE, Cairo = TRUE)
# Purpose: Simulates a realistic GBIF plant occurrence dataset in Italy,
#          generates three ecological maps (occurrences, elevation covariate,
#          and the merged spatial niche map), and stress-tests the server's
#          resource boundaries (RAM, cgroups, /Rtmp I/O, and thread explosion).
#
# Interactive Display:
#   When run via Rscript (terminal), it benchmarks and outputs files under /Rtmp.
#   When run inside RStudio, it tests the interactive "Plots" pane (RStudioGD).
# ==============================================================================

message("\n==================================================================")
message("   BIOME-CALC BOTANICAL PLOT STRESS TEST & SYSTEM DIAGNOSTIC")
message("   Start Time: ", format(Sys.time(), "%Y-%m-%d %H:%M:%S"))
message("   R version: ", rlang::str_sub(R.version$version.string, 1, 15) %||% R.version$version.string)
message("   System User: ", Sys.info()[["user"]])
message("==================================================================\n")

# ------------------------------------------------------------------------------
# 1. PESSIMISTIC SYSTEM PRE-FLIGHT DIAGNOSTICS & RESOURCE GUARDS
# ------------------------------------------------------------------------------
message("[STEP 1/6] Running System Diagnostics & Resource Guards...")

# 1.1 Force Headless-Safe Graphics Device (X11 = FALSE, Cairo = TRUE)
# Since the server has capabilities("X11") == FALSE, we must enforce cairo.
# Otherwise, R's default bitmap device can fallback to X11 and throw a connection error.
options(bitmapType = "cairo")
message("  [OK] Enforced options(bitmapType = 'cairo') for headless compatibility.")

# Check capabilities
caps <- capabilities()
if (!caps["cairo"]) {
  message("  [CRITICAL] Cairo rendering is NOT available in this R environment!")
}
if (caps["X11"]) {
  message("  [WARN] X11 is available. Ensuring we ignore it to prevent display lockups.")
} else {
  message("  [OK] Verified X11 is disabled (standard for headless cluster nodes).")
}

# 1.2 Thread Capping & BLAS Check
# Multi-threaded OpenBLAS-pthread is known to cause deadlocks/SIGSEGV in RStudio Server.
# We explicitly check and cap thread concurrency to a safe default of 1.
safe_threads <- 1L
Sys.setenv(OMP_NUM_THREADS = safe_threads, OPENBLAS_NUM_THREADS = safe_threads, MKL_NUM_THREADS = safe_threads)

if (requireNamespace("RhpcBLASctl", quietly = TRUE)) {
  RhpcBLASctl::blas_set_num_threads(safe_threads)
  RhpcBLASctl::omp_set_num_threads(safe_threads)
  message("  [OK] Capped BLAS/OpenMP threads to ", safe_threads, " via RhpcBLASctl.")
} else {
  message("  [WARN] RhpcBLASctl not installed. Capped threads via environment variables only.")
}

# Check if OpenBLAS-pthread is loaded in sessionInfo
si_info <- utils::sessionInfo()
blas_lib <- si_info$BLAS
if (!is.null(blas_lib) && grepl("openblas-pthread", blas_lib, ignore.case = TRUE)) {
  message("  [CRITICAL WARNING] Session uses 'openblas-pthread' (", basename(blas_lib), ").")
  message("                     This is highly unstable in multi-process R workloads!")
} else {
  message("  [OK] BLAS configuration: ", if (is.null(blas_lib)) "Default R BLAS" else basename(blas_lib))
}

# 1.3 Memory & Cgroup Budgeting
# Read cgroup or system memory limits to scale the simulation grid safely.
get_available_ram_mb <- function() {
  cgroup_limit <- tryCatch({
    if (file.exists("/sys/fs/cgroup/memory.max")) {
      txt <- trimws(readLines("/sys/fs/cgroup/memory.max", n = 1, warn = FALSE))
      if (txt != "max") as.numeric(txt) / (1024^2) else Inf
    } else if (file.exists("/sys/fs/cgroup/memory/memory.limit_in_bytes")) {
      as.numeric(readLines("/sys/fs/cgroup/memory/memory.limit_in_bytes", n = 1, warn = FALSE)) / (1024^2)
    } else {
      Inf
    }
  }, error = function(e) Inf)
  
  sys_avail <- tryCatch({
    meminfo <- readLines("/proc/meminfo", warn = FALSE)
    avail_line <- grep("^MemAvailable:", meminfo, value = TRUE)
    if (length(avail_line) > 0) {
      as.numeric(gsub("[^0-9]", "", avail_line)) / 1024
    } else {
      free <- as.numeric(gsub("[^0-9]", "", grep("^MemFree:", meminfo, value = TRUE)))
      cached <- as.numeric(gsub("[^0-9]", "", grep("^Cached:", meminfo, value = TRUE)))
      (free + cached) / 1024
    }
  }, error = function(e) 2048) # 2GB fallback
  
  min(cgroup_limit, sys_avail)
}

avail_ram_mb <- get_available_ram_mb()
message(sprintf("  [OK] Available RAM: %.1f MB (Cgroup/procfs combined)", avail_ram_mb))

# Dynamically scale raster grid resolution based on available RAM to prevent OOM
if (avail_ram_mb < 500) {
  grid_resolution <- 80 # Minimal low-res
  message("  [GUARD] Severe RAM restriction (<500MB). Using low-res grid (80x80).")
} else if (avail_ram_mb < 2000) {
  grid_resolution <- 150 # Medium-res
  message("  [GUARD] Moderate RAM limit (<2GB). Scaling grid to 150x150.")
} else {
  grid_resolution <- 300 # High-res (highly realistic but safe)
  message("  [OK] Ample RAM available. Scaling grid to ", grid_resolution, "x", grid_resolution, ".")
}

# 1.4 Local /Rtmp Temp Storage Validation
# R and GDAL/terra write large temp files. We must route them to the local SSD /Rtmp mount
# rather than memory-limited tmpfs /tmp or slow NFS home mounts.
user <- Sys.info()[["user"]]
system_rtmp_base <- "/Rtmp"
user_rtmp_dir <- file.path(system_rtmp_base, paste0("biome_", user))

if (dir.exists(user_rtmp_dir) && file.access(user_rtmp_dir, 2) == 0) {
  temp_dir_target <- user_rtmp_dir
  message("  [OK] Verified custom user-isolated path: ", temp_dir_target)
} else if (dir.exists(system_rtmp_base) && file.access(system_rtmp_base, 2) == 0) {
  temp_dir_target <- file.path(system_rtmp_base, paste0("biome_", user, "_plot_stress"))
  dir.create(temp_dir_target, showWarnings = FALSE, recursive = TRUE)
  message("  [OK] Created plot temp directory: ", temp_dir_target)
} else {
  temp_dir_target <- file.path("/tmp", paste0("biome_", user, "_plot_stress"))
  dir.create(temp_dir_target, showWarnings = FALSE, recursive = TRUE)
  message("  [WARN] /Rtmp directory not writeable. Falling back to local /tmp: ", temp_dir_target)
}

# Set environment temp vars for the session and configure terra options
Sys.setenv(TMPDIR = temp_dir_target, TMP = temp_dir_target, TEMP = temp_dir_target)
if (requireNamespace("terra", quietly = TRUE)) {
  terra::terraOptions(tempdir = temp_dir_target)
  message("  [OK] terra package tmpdir routed to: ", terra::terraOptions()$tempdir)
}

# 1.5 Rendering Engine Selection
# Benchmark ragg vs cairo vs standard png
has_ragg <- requireNamespace("ragg", quietly = TRUE)
has_ggplot2 <- requireNamespace("ggplot2", quietly = TRUE)

if (!has_ggplot2) {
  stop("CRITICAL: 'ggplot2' is required but not installed. Auditing failed.")
}

if (has_ragg) {
  message("  [OK] 'ragg' rendering engine is available (highly optimized AGG pipeline).")
  render_dev <- "ragg"
} else {
  message("  [WARN] 'ragg' is missing. Falling back to standard cairo/png (may be 2-4x slower).")
  render_dev = "standard"
}

# ------------------------------------------------------------------------------
# 2. RSTUDIO INTERACTIVE GRAPHICS PORT AUDITS
# ------------------------------------------------------------------------------
message("\n[STEP 2/6] Auditing RStudio Graphics Device Status...")

is_rstudio <- (Sys.getenv("RSTUDIO") == "1") || (.Platform$OS.type == "unix" && .Platform$GUI == "RStudio")

if (is_rstudio) {
  message("  [ACTIVE] Running inside interactive RStudio Session.")
  # Query active graphic device
  active_dev <- dev.cur()
  message("  --> Current Active Graphics Device: ", names(active_dev), " (Code: ", active_dev, ")")
  
  # Audit the RStudio plotting backend configuration
  # If ragg is selected in RStudio's options, the rendering of plot tab will be fast.
  rstudio_backend <- tryCatch({
    # RStudio options list is stored inside tools:rstudio
    get("rstudio.graphics.backend", envir = as.environment("tools:rstudio"))
  }, error = function(e) "unknown/default")
  message("  --> RStudio Options Graphics Backend: ", rstudio_backend)
} else {
  message("  [HEADLESS] Running outside RStudio IDE (non-interactive). Plot tab tests will write files to disk.")
}

# ------------------------------------------------------------------------------
# 3. REALISTIC BOTANICAL DATA SIMULATION (Italy Occurrence Template)
# ------------------------------------------------------------------------------
message("\n[STEP 3/6] Simulating Realistic Botanical & Spatial Covariate Data...")

# 3.1 Italy Spatial Bounding Box
# Longitude: 6.0 to 19.0 (West to East)
# Latitude: 35.0 to 48.0 (South to North)
lon_seq <- seq(6.0, 19.0, length.out = grid_resolution)
lat_seq <- seq(35.0, 48.0, length.out = grid_resolution)
grid <- expand.grid(lon = lon_seq, lat = lat_seq)

# 3.2 Mathematical Model of Italy's Geography & Topography
# We simulate a realistic elevation model:
# - High Alps in the North (Latitude > 44) curving from West to East
# - Apennines mountain range running down the center of the peninsula
# - Low coastal plains
# - Sea level (0) for coordinates outside the peninsula map skeleton
is_in_italy <- function(lon, lat) {
  # Approximate polygon skeleton of the Italian peninsula + Sicily + Sardinia
  # Peninsula body
  peninsula <- lat >= 38 & lat <= 47.5 & lon >= 7.5 & lon <= 18.5 & 
               (lon >= (8.0 + (lat - 38) * 0.4) & lon <= (16.5 + (lat - 38) * 0.1))
  # Alps extension in the north
  alps_zone <- lat > 45 & lon >= 6.5 & lon <= 14
  # Sicily
  sicily <- lat >= 36.5 & lat < 38.3 & lon >= 12.0 & lon <= 15.8
  # Sardinia
  sardinia <- lat >= 38.8 & lat < 41.5 & lon >= 8.0 & lon <= 10.0
  
  peninsula | alps_zone | sicily | sardinia
}

# Generate elevation (meters above sea level)
calc_elevation <- function(lon, lat) {
  elev <- rep(0, length(lon))
  italy_idx <- is_in_italy(lon, lat)
  
  # Base terrain for landmass
  elev[italy_idx] <- 120 # low plains base
  
  # Alps contribution (North)
  alps_idx <- italy_idx & lat > 45
  if (any(alps_idx)) {
    # Peak Alps around lat=46, lon=10
    dist_alps <- sqrt((lon[alps_idx] - 9.5)^2 + (lat[alps_idx] - 46.2)^2)
    elev[alps_idx] <- elev[alps_idx] + pmax(0, 3800 - dist_alps * 1200)
  }
  
  # Apennines contribution (Spine down the center)
  # Dynamic ridge center line: lon = 12.5 - (lat - 42) * 0.35
  spine_idx <- italy_idx & lat >= 38 & lat <= 45
  if (any(spine_idx)) {
    ridge_lon <- 12.5 - (lat[spine_idx] - 42) * 0.35
    dist_spine <- abs(lon[spine_idx] - ridge_lon)
    elev[spine_idx] <- elev[spine_idx] + pmax(0, 2200 - dist_spine * 900)
  }
  
  # Sicily Mountains (Etna)
  etna_idx <- italy_idx & lat >= 37.2 & lat <= 37.8 & lon >= 14.8 & lon <= 15.2
  if (any(etna_idx)) {
    dist_etna <- sqrt((lon[etna_idx] - 15.0)^2 + (lat[etna_idx] - 37.75)^2)
    elev[etna_idx] <- elev[etna_idx] + pmax(0, 3300 - dist_etna * 6000)
  }
  
  # Add moderate topography noise to look like a real DEM
  noise <- rnorm(length(lon), mean = 0, sd = 40)
  elev[italy_idx] <- pmax(5, elev[italy_idx] + noise[italy_idx])
  
  elev
}

# Compute elevation and temperature (standard lapse rate: -6.5°C per 1000m elevation)
grid$elevation <- calc_elevation(grid$lon, grid$lat)
grid$is_land <- is_in_italy(grid$lon, grid$lat)

# Mean Annual Temperature: base decreases with latitude, and drops with elevation
grid$temperature <- ifelse(grid$is_land,
                           24 - 0.75 * (grid$lat - 35) - 0.0065 * grid$elevation,
                           NA)

# Filter out sea points for land plotting (or keep as NA)
grid$elevation_land <- ifelse(grid$is_land, grid$elevation, NA)

# 3.3 Simulating GBIF Occurrences for a Plant Species: Olea europaea (Olive tree)
# Olive trees prefer Mediterranean climates: warm temperatures (14 to 22°C) and low-to-medium elevations (< 700m).
# We simulate occurrences with sampling bias (high density near coastal areas and roads, typical of GBIF).
set.seed(42)
num_samples <- 15000
sim_points <- data.frame(
  lon = runif(num_samples, 6.5, 18.5),
  lat = runif(num_samples, 35.5, 47.0)
)
sim_points$is_land <- is_in_italy(sim_points$lon, sim_points$lat)
sim_points <- sim_points[sim_points$is_land, ]

# Extract environmental values for points
sim_points$elevation <- calc_elevation(sim_points$lon, sim_points$lat)
sim_points$temperature <- 24 - 0.75 * (sim_points$lat - 35) - 0.0065 * sim_points$elevation

# Niche suitability probability function
suitability <- exp(-0.5 * ((sim_points$temperature - 16.5) / 2.5)^2) * # temp preference around 16.5°C
               exp(-0.5 * (pmax(0, sim_points$elevation - 200) / 300)^2) # prefers lowlands/hills

# Add GBIF sampling bias: higher recording rate in northern regions & coastal lowlands
sampling_bias <- ifelse(sim_points$lat > 42, 1.0, 0.6) * 
                 ifelse(sim_points$elevation < 150, 1.0, 0.4)

occurrence_prob <- suitability * sampling_bias
keep_idx <- runif(length(occurrence_prob)) < occurrence_prob
occurrences <- sim_points[keep_idx, ]

# Populate realistic GBIF attributes
n_occurrences <- nrow(occurrences)
occurrences$gbifID <- 4000000000 + seq_len(n_occurrences)
occurrences$species <- "Olea europaea L."
occurrences$coordinateUncertaintyInMeters <- sample(c(5, 10, 30, 100, 500, 1000, 5000), 
                                                    n_occurrences, replace = TRUE, 
                                                    prob = c(0.3, 0.2, 0.2, 0.15, 0.08, 0.05, 0.02))
occurrences$eventDate <- as.Date("2020-01-01") + sample(0:2000, n_occurrences, replace = TRUE)

message("  [OK] Generated simulated land covariate grid (", grid_resolution, "x", grid_resolution, ").")
message("  [OK] Generated ", n_occurrences, " realistic GBIF occurrences for 'Olea europaea L.'.")

# ------------------------------------------------------------------------------
# 4. BUILDING MAPS
# ------------------------------------------------------------------------------
message("\n[STEP 4/6] Building ggplot Maps...")

# Define a cohesive theme with clean layout fallback
map_theme <- ggplot2::theme_minimal() + 
  ggplot2::theme(
    text = ggplot2::element_text(color = "#2d2d2d"),
    plot.title = ggplot2::element_text(face = "bold", size = 13, color = "#111111"),
    plot.subtitle = ggplot2::element_text(size = 10, color = "#555555"),
    plot.caption = ggplot2::element_text(size = 7, color = "#888888", face = "italic"),
    panel.background = ggplot2::element_rect(fill = "#f0f5fa", color = NA),
    panel.grid.major = ggplot2::element_line(color = "#e1e8f0", size = 0.3),
    panel.grid.minor = ggplot2::element_blank(),
    legend.position = "right",
    legend.title = ggplot2::element_text(size = 9, face = "bold"),
    legend.text = ggplot2::element_text(size = 8)
  )

# --- PLOT 1: Botanical Occurrences ---
message("  Building Plot 1: GBIF Occurrence Points...")
t0_p1 <- Sys.time()

p1 <- ggplot2::ggplot() +
  # Draw a grey landmass underlay
  ggplot2::geom_tile(data = subset(grid, is_land), ggplot2::aes(x = lon, y = lat), fill = "#e2e8f0") +
  # Draw the plant occurrence points
  ggplot2::geom_point(data = occurrences, ggplot2::aes(x = lon, y = lat, color = coordinateUncertaintyInMeters),
                      alpha = 0.5, size = 1.0) +
  ggplot2::scale_color_gradientn(
    name = "Uncertainty (m)",
    colors = c("#059669", "#d97706", "#dc2626"),
    trans = "log10",
    labels = scales::label_comma()
  ) +
  ggplot2::coord_quickmap(xlim = c(6.5, 19.0), ylim = c(35.5, 47.0)) +
  ggplot2::labs(
    title = "Olea europaea L. Occurrences (GBIF Italy)",
    subtitle = paste0("Spatial distribution of ", n_occurrences, " records with coordinate uncertainty"),
    x = "Longitude", y = "Latitude",
    caption = "Source: Simulated GBIF dataset - Biome-Calc Diagnostics"
  ) +
  map_theme

t1_p1 <- Sys.time()
message("  --> Plot 1 built in: ", round(as.numeric(difftime(t1_p1, t0_p1, units = "secs")), 3), " s")


# --- PLOT 2: Environmental Covariate (Elevation DEM) ---
message("  Building Plot 2: Topographical & Climatic Covariates...")
t0_p2 <- Sys.time()

p2 <- ggplot2::ggplot() +
  # Elevation raster
  ggplot2::geom_raster(data = grid, ggplot2::aes(x = lon, y = lat, fill = elevation_land)) +
  ggplot2::scale_fill_gradientn(
    name = "Elevation (m)",
    colors = c("#1e3a8a", "#3b82f6", "#10b981", "#f59e0b", "#78350f", "#ffffff"),
    values = c(0, 0.05, 0.2, 0.5, 0.8, 1.0),
    na.value = "#dbebfa" # Sea color
  ) +
  ggplot2::coord_quickmap(xlim = c(6.5, 19.0), ylim = c(35.5, 47.0)) +
  ggplot2::labs(
    title = "Topographical Terrain Profile (Italy DEM)",
    subtitle = paste0("Simulated digital elevation model at resolution: ", grid_resolution, "x", grid_resolution),
    x = "Longitude", y = "Latitude",
    caption = "Terrain models Alps, Apennines spine, and Etna volcano structures."
  ) +
  map_theme

t1_p2 <- Sys.time()
message("  --> Plot 2 built in: ", round(as.numeric(difftime(t1_p2, t0_p2, units = "secs")), 3), " s")


# --- PLOT 3: Merged Map (Eco-spatial Niche Overlay) ---
message("  Building Plot 3: Merged Spatial Niche Map...")
t0_p3 <- Sys.time()

p3 <- ggplot2::ggplot() +
  # Base temperature map
  ggplot2::geom_raster(data = grid, ggplot2::aes(x = lon, y = lat, fill = temperature)) +
  ggplot2::scale_fill_gradientn(
    name = "Temp (°C)",
    colors = c("#0571b0", "#92c5de", "#f7f7f7", "#f4a582", "#ca0020"),
    na.value = "#dbebfa"
  ) +
  # Contour lines of point density (Niche density)
  ggplot2::geom_density_2d(data = occurrences, ggplot2::aes(x = lon, y = lat), 
                           color = "#111111", alpha = 0.6, bins = 6, size = 0.4) +
  # Overlay actual points
  ggplot2::geom_point(data = occurrences, ggplot2::aes(x = lon, y = lat), 
                      color = "#ff7f00", alpha = 0.25, size = 0.6) +
  ggplot2::coord_quickmap(xlim = c(6.5, 19.0), ylim = c(35.5, 47.0)) +
  ggplot2::labs(
    title = "Ecological Niche: Olea europaea vs Mean Temperature",
    subtitle = "Plant occurrences overlaid on climatic gradient with spatial density contours",
    x = "Longitude", y = "Latitude",
    caption = "Orange markers indicate individual occurrences. Contours show spatial density peaks."
  ) +
  map_theme

t1_p3 <- Sys.time()
message("  --> Plot 3 built in: ", round(as.numeric(difftime(t1_p3, t0_p3, units = "secs")), 3), " s")

# ------------------------------------------------------------------------------
# 5. HARD RESOURCE STRESS TESTING & WRITING BUDGET CHECKS
# ------------------------------------------------------------------------------
message("\n[STEP 5/6] Running Graphics Device Stress Test (Disk I/O & Render Benchmarking)...")

test_render <- function(plot_obj, filename, label, dev_type) {
  dest_path <- file.path(temp_dir_target, filename)
  t0 <- Sys.time()
  
  if (dev_type == "ragg") {
    ragg::agg_png(dest_path, width = 2400, height = 2400, res = 300)
    print(plot_obj)
    dev.off()
  } else {
    png(dest_path, width = 2400, height = 2400, res = 300, type = "cairo")
    print(plot_obj)
    dev.off()
  }
  
  t1 <- Sys.time()
  elapsed <- as.numeric(difftime(t1, t0, units = "secs"))
  file_size_mb <- file.info(dest_path)$size / (1024^2)
  
  message(sprintf("  [%s] Rendered to: %s", dev_type, basename(dest_path)))
  message(sprintf("        Time: %.3f seconds | File Size: %.2f MB", elapsed, file_size_mb))
  
  list(elapsed = elapsed, size = file_size_mb, path = dest_path)
}

# Run stress tests to disk
message("Rendering Plot 1 (Occurrences)...")
res_p1 <- test_render(p1, "italy_occurrences.png", "Plot 1", render_dev)

message("Rendering Plot 2 (Elevation DEM)...")
res_p2 <- test_render(p2, "italy_elevation.png", "Plot 2", render_dev)

message("Rendering Plot 3 (Merged Niche Map)...")
res_p3 <- test_render(p3, "italy_niche_merged.png", "Plot 3", render_dev)

# Clean up temp rendering files from local /Rtmp to comply with "smallest blast radius" and storage cleanup
cleanup_temp_files <- function() {
  tryCatch({
    file.remove(res_p1$path)
    file.remove(res_p2$path)
    file.remove(res_p3$path)
    message("  [OK] Cleaned up intermediate stress test images from temp disk.")
  }, error = function(e) {
    message("  [WARN] Failed to delete some temporary plots: ", e$message)
  })
}
# Keep files for RStudio webconsole viewing temporarily, but schedule them for deletion
on.exit(cleanup_temp_files(), add = TRUE)

# ------------------------------------------------------------------------------
# 6. RSTUDIO PLOT PANE DISPLAY AUDIT
# ------------------------------------------------------------------------------
message("\n[STEP 6/6] Compiling System Diagnostics & Plot Pane Guide...")

total_render_time <- res_p1$elapsed + res_p2$elapsed + res_p3$elapsed
memory_delta_mb <- gc(verbose = FALSE)[2, 6] # R current heap size

# Check if network home directory is affected by rendering activities
nfs_home_check <- tryCatch({
  home_dir <- Sys.getenv("HOME")
  nfs_path <- file.path(home_dir, ".biome_plot_nfs_test")
  t0_nfs <- Sys.time()
  writeLines("NFS Latency Test", nfs_path)
  file.remove(nfs_path)
  t1_nfs <- Sys.time()
  as.numeric(difftime(t1_nfs, t0_nfs, units = "secs"))
}, error = function(e) -1)

# Compile results in Markdown format for the RStudio Web Console
cat("\n\n==================================================================\n")
cat("                BIOME-CALC GRAPHICS DIAGNOSTIC REPORT\n")
cat("==================================================================\n")
cat(sprintf("  * Active Render Engine  : %s\n", render_dev))
cat(sprintf("  * Grid Resolution       : %d x %d cells\n", grid_resolution, grid_resolution))
cat(sprintf("  * Plot 1 Rendering Time : %.3f sec (File: %.2f MB)\n", res_p1$elapsed, res_p1$size))
cat(sprintf("  * Plot 2 Rendering Time : %.3f sec (File: %.2f MB)\n", res_p2$elapsed, res_p2$size))
cat(sprintf("  * Plot 3 Rendering Time : %.3f sec (File: %.2f MB)\n", res_p3$elapsed, res_p3$size))
cat(sprintf("  * Total Rendering Time  : %.3f sec\n", total_render_time))
cat(sprintf("  * Active Heap Memory    : %.1f MB\n", memory_delta_mb))
cat(sprintf("  * Target Plot Directory : %s\n", temp_dir_target))
if (nfs_home_check > 0) {
  cat(sprintf("  * NFS Home Write Latency: %.4f sec (%s)\n", 
              nfs_home_check, 
              if (nfs_home_check < 0.05) "Excellent" else if (nfs_home_check < 0.2) "Acceptable" else "SEVERE LATENCY WARNING"))
} else {
  cat("  * NFS Home Write Latency: Failed or Unreadable\n")
}
cat("==================================================================\n")

if (total_render_time > 8.0) {
  cat("\n⚠️  [PERFORMANCE ALERT] Total rendering time exceeded 8 seconds.\n")
  cat("   - Recommend installing 'ragg' package for 2-4x speedups.\n")
  cat("   - Verify that OpenBLAS is using the 'serial' library and not 'pthread'.\n")
} else {
  cat("\n✅ [STATUS] Graphics rendering performance is within healthy production bounds.\n")
}

# 6.2 Plot Pane Display Logic
if (is_rstudio) {
  message("\n[PLOT PANE DISPLAY ACTION]")
  message("  Printing the final merged niche plot (Plot 3) to the RStudio Plot viewer...")
  
  # Set up a timing trap for the WebSocket transmission to the user's browser
  t0_display <- Sys.time()
  print(p3)
  t1_display <- Sys.time()
  
  display_elapsed <- as.numeric(difftime(t1_display, t0_display, units = "secs"))
  message(sprintf("  --> Plot print call completed in %.3f seconds.", display_elapsed))
  
  # Diagnostic evaluation of RStudio plot pane problems
  if (display_elapsed > 4.0) {
    message("\n⚠️  [PLOT VISUALIZATION LAG DETECTED]")
    message("   The RStudio Plot viewer took more than 4 seconds to accept the plot.")
    message("   This usually indicates a bottleneck in one of these components:")
    message("     1. RStudio WebSocket Buffer: Rendering complex vectors over the websocket is slow.")
    message("        FIX: Install 'ragg' and go to RStudio: Tools -> Global Options -> General")
    message("             -> Graphics -> Graphic Device Backend -> Select 'AGG'.")
    message("     2. Large point layers: Downsample your occurrences data or use stat_density_2d.")
    message("     3. Slow /tmp mount: RStudio caches active plots in the user session temp directory.")
    message("        Verify that R_SESSION_TMPDIR is routed to local SSD (/Rtmp) and not NFS.")
  } else {
    message("\n✅ [STATUS] Interactive plot pane submission was fast (%.3f s).", display_elapsed)
  }
} else {
  cat("\n💡 [RSTUDIO GRAPHICS TROUBLESHOOTING GUIDE]\n")
  cat("   To test RStudio's interactive Plot viewer and diagnose visualization issues:\n")
  cat("     1. Log in to the RStudio Server web interface.\n")
  cat("     2. Run: source(\"/home/jfs/00_Antigravity_workspace/R-studioConf/scripts/99_botanical_plot_stress_test.R\")\n")
  cat("     3. Verify if the plot appears in the 'Plots' tab on the bottom right.\n")
  cat("     4. If it hangs, throws a display error, or takes >5 seconds, check:\n")
  cat("        - RStudio Options: Tools -> Global Options -> General -> Graphics -> Backend.\n")
  cat("          Set backend to 'AGG' (ragg package) or 'Cairo' instead of 'Default'.\n")
  cat("        - Ensure you have options(bitmapType = 'cairo') active in Renviron/Rprofile.\n")
  cat("        - Verify `/Rtmp/biome_<user>` is writeable and has free space.\n")
}

message("\n=== SYSTEM DIAGNOSTIC COMPLETED ===")
