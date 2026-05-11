# tests/fixtures/r_lint/luana_sdm_funcs.R
# Anonymized fixture: <user_c> — silent tryCatch swallowing pattern.
# Expected findings: R016 (relative readRDS), R019 (silent tryCatch x5)

library(terra)

load_safely <- function(path) {
    tryCatch(readRDS(path), error = function(e) NULL)
}

calc_safely <- function(r) {
    tryCatch(terra::global(r, "mean"), error = function(e) NA)
}

write_safely <- function(r, path) {
    tryCatch(terra::writeRaster(r, path, overwrite = TRUE), error = function(e) {})
}

merge_safely <- function(rs) {
    tryCatch(do.call(c, rs), error = function(e) NULL)
}

project_safely <- function(r, crs) {
    tryCatch(terra::project(r, crs), error = function(e) NULL)
}

# Relative path
data <- readRDS("data/chelsaVariables/downscaled/bio_historic.rds")
