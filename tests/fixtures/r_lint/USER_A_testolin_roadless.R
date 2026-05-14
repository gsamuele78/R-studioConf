# tests/fixtures/r_lint/USER_A_testolin_roadless.R
# Anonymized fixture: USER_A — OSM/GEE pipeline anti-patterns.
# Expected findings: R010 (detectCores raw), R023 (install_github), R025 (unbounded retry), R028 (project tmpdir saveRDS)

library(parallel)

# R010: detectCores() ignores cgroup
ncores <- detectCores()

# R023: install_github() in script
devtools::install_github("[ANONYMIZED_REPO_OWNER]/[ANONYMIZED_REPO_NAME]")

# R025: unbounded retry on network call
feat <- NULL
for (i in 1:5) {
    feat <- tryCatch(
        list(timestamp = Sys.time()),
        error = function(e) {
            message("attempt ", i, ": ", conditionMessage(e))
            NULL
        }
    )
    if (!is.null(feat)) break
    Sys.sleep(2^i) # 2, 4, 8, 16, 32 seconds
}
if (is.null(feat)) stop("OSM/GEE unreachable after 5 attempts")

# R028: project-local `_temp/` cache
# Project-local cache directory
saveRDS(feat, file = file.path(Sys.getenv("ANONYMIZED_BIOME_USER_TMP", "/Rtmp"), Sys.getenv("USER", "USER_A"), "cache/cache_001.rds"))
