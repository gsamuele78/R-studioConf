# tests/fixtures/r_lint/testolin_roadless.R
# Anonymized fixture: <user_e> — OSM/GEE pipeline anti-patterns.
# Expected findings: R010 (detectCores raw), R023 (install_github), R025 (unbounded retry), R028 (project tmpdir saveRDS)

library(parallel)

ncores <- detectCores()

devtools::install_github("ropensci/rnaturalearthhires")

feat <- NULL
while (is.null(feat)) {
    try({
        feat <- list(timestamp = Sys.time())
    })
}

# Project-local cache directory
saveRDS(feat, "_temp/cache_001.rds")
