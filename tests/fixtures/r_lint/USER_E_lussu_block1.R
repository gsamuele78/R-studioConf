# tests/fixtures/r_lint/USER_E_lussu_block1.R
# Anonymized fixture: USER_A — synthetic Lussu-style block.
# Expected findings: R001 (makeCluster + no clusterExport), R006 (terra::values in loop)

library(terra)
library(parallel)

raster_files <- list.files("[ANONYMIZED_RASTERS_SUBDIR]", pattern = "\\.tif$", full.names = TRUE)

process_chunk <- function(rf) {
    r <- terra::rast(rf)
    sum(terra::values(r), na.rm = TRUE)
}

cl <- makeCluster(4, type = "PSOCK")
# NOTE: NO clusterExport — process_chunk will not be visible in workers
results <- parLapply(cl, raster_files, process_chunk)
stopCluster(cl)

# Anti-pattern: terra::values inside a for loop
totals <- numeric(length(raster_files))
for (i in seq_along(raster_files)) {
    r <- terra::rast(raster_files[i])
    totals[i] <- mean(terra::values(r), na.rm = TRUE)
}
