# tests/fixtures/r_lint/USER_G_martina_test2.R
# Anonymized fixture: USER_A — GOOD-EXAMPLE reference (CLEAN).
# Expected findings: NONE (canonical good-pattern, used by docs as the
# "this is what your script should look like" example).
#
# Demonstrates: chunked MCMC with /Rtmp scratch, gc() per chunk, saveRDS+unlink
# cleanup, no setwd, no cross-user paths, no compileNimble crossing PSOCK.

library(nimble)

# 1. Local SSD scratch dir (NOT /tmp, NOT NFS, NOT project-local _temp)
chunk_dir <- file.path(
    Sys.getenv("ANONYMIZED_BIOME_USER_TMP", "/Rtmp"),
    Sys.getenv("USER", "USER_A"),
    "mcmc_chunks"
)
dir.create(chunk_dir, showWarnings = FALSE, recursive = TRUE)

# 2. Smoke knob — small workload when harness sets BIOME_SMOKE=1
n_chunks <- as.integer(Sys.getenv("BIOME_SMOKE_N_CHUNKS", "10"))
chunk_iters <- as.integer(Sys.getenv("BIOME_SMOKE_CHUNK_SIZE", "300"))

# 3. Compile in master only — never serialize across PSOCK
# (single-threaded chunked run, so no parLapply at all)
chunk_files <- character(n_chunks)
for (i in seq_len(n_chunks)) {
    gc(verbose = FALSE)
    samples <- rnorm(chunk_iters) # placeholder for runMCMC(...)
    chunk_files[i] <- file.path(chunk_dir, sprintf("chunk_%03d.rds", i))
    saveRDS(samples, chunk_files[i])
    rm(samples)
}

# 4. Merge from disk and clean up scratch
merged <- do.call(c, lapply(chunk_files, readRDS))
unlink(chunk_files)

cat(sprintf("Done: %d samples merged, scratch cleaned\n", length(merged)))
