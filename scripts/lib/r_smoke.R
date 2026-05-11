#!/usr/bin/env Rscript
# scripts/lib/r_smoke.R — HC-13-compliant smoke runner for user R scripts.
#
# Sources the user's .R file UNMODIFIED inside a tightly bounded sandbox:
#   * wall-clock timeout (default 300s, override via BIOME_DIAG_SMOKE_TIMEOUT_S)
#   * forces niter/nsamples/n_chunks to small values via masking globals
#     in a helper env that the user script's calls *may* pick up if they
#     reference Sys.getenv(); we DO NOT rewrite the user file.
#   * captures every error with conditionMessage and a 30-line traceback
#     digest so the operator can read it without re-running.
#
# This runner is OPT-IN: the harness only invokes it when the operator
# exports BIOME_DIAG_SMOKE=1. Default behaviour is "lint only".
#
# Usage:
#   BIOME_DIAG_SMOKE=1 Rscript r_smoke.R <user_script.R> [args...]
#
# Output:
#   - prints "[r_smoke] PASS" or "[r_smoke] FAIL: <message>"
#   - prints a "BIOME_SMOKE_DIGEST" block the harness greps for in stdout
#
# Exit codes:
#   0 — script sourced cleanly within the timeout
#   1 — script raised an error
#   2 — script hit the smoke timeout (likely needs real run, not a smoke)
#   3 — invocation error
#
# This script must remain dependency-free (base R only).

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 1L) {
    cat("Usage: BIOME_DIAG_SMOKE=1 Rscript r_smoke.R <user_script.R> [args...]\n",
        file = stderr()
    )
    quit(status = 3L, save = "no")
}
user_file <- args[[1L]]
user_args <- if (length(args) > 1L) args[-1L] else character(0L)

if (!file.exists(user_file)) {
    cat(sprintf("r_smoke.R: file not found: %s\n", user_file), file = stderr())
    quit(status = 3L, save = "no")
}

# Hard wall-clock cap. The harness still wraps us in `timeout(1)`; this is a
# defence-in-depth in-process limit so we can produce a structured digest
# even when the outer kill is about to fire.
smoke_timeout <- as.integer(Sys.getenv("BIOME_DIAG_SMOKE_TIMEOUT_S", "300"))
if (is.na(smoke_timeout) || smoke_timeout <= 0L) smoke_timeout <- 300L

# Smoke knobs: when the user script reads Sys.getenv("BIOME_SMOKE_*") they
# can shrink their workload. We ALSO export common knob names typed by the
# audited scripts (n_chains, niter, nburn) so docs can teach researchers to
# read them. We DO NOT mutate the user file — these are env hints only.
Sys.setenv(
    BIOME_DIAG_SMOKE = "1",
    BIOME_SMOKE_NITER = "200",
    BIOME_SMOKE_NBURN = "100",
    BIOME_SMOKE_N_CHAINS = "1",
    BIOME_SMOKE_N_CHUNKS = "2",
    BIOME_SMOKE_CHUNK_SIZE = "20"
)

# Set up a setTimeLimit hook in case the script enters an R-level long loop.
# Note: setTimeLimit only catches at top-level interpreter checkpoints; it
# does NOT interrupt blocked C calls. The outer `timeout(1)` from the bash
# harness is the real safety net.
on.exit(setTimeLimit(cpu = Inf, elapsed = Inf, transient = FALSE), add = TRUE)
setTimeLimit(elapsed = smoke_timeout, transient = FALSE)

# Make user's commandArgs() see the args they passed.
# Hack: redefine commandArgs in globalenv so user code sees [user_args]
# without ever modifying the .R file on disk.
.orig_cmdargs <- commandArgs
commandArgs <- function(trailingOnly = FALSE) {
    if (trailingOnly) {
        return(user_args)
    }
    c(.orig_cmdargs(trailingOnly = FALSE), user_args)
}

cat(sprintf("[r_smoke] sourcing UNMODIFIED %s (HC-13)\n", user_file))
cat(sprintf(
    "[r_smoke] timeout %ds; smoke knobs exported (BIOME_SMOKE_*)\n",
    smoke_timeout
))

t0 <- proc.time()[["elapsed"]]
result_status <- "FAIL"
result_msg <- ""
result_digest <- character(0L)

err <- tryCatch(
    {
        sys.source(user_file,
            envir = globalenv(), keep.source = TRUE,
            keep.parse.data = TRUE, chdir = TRUE
        )
        result_status <- "PASS"
        NULL
    },
    error = function(e) e
)

t1 <- proc.time()[["elapsed"]]
elapsed <- round(t1 - t0, 1)

if (!is.null(err)) {
    result_msg <- conditionMessage(err)
    is_timeout <- grepl("reached elapsed time limit|reached CPU time limit",
        result_msg,
        perl = TRUE
    )
    if (is_timeout) {
        result_status <- "TIMEOUT"
    }
    # Build a digest from the call stack
    tb <- tryCatch(sys.calls(), error = function(e) NULL)
    if (length(tb)) {
        result_digest <- vapply(
            utils::tail(tb, 30L),
            function(c) {
                s <- tryCatch(deparse(c, nlines = 1L),
                    error = function(e) "<undeparsable>"
                )
                s[[1L]]
            }, character(1L)
        )
    }
}

# ---- emit digest block (greppable by harness) ----
cat("\n=== BIOME_SMOKE_DIGEST_BEGIN ===\n")
cat(sprintf("status=%s\n", result_status))
cat(sprintf("elapsed_s=%s\n", elapsed))
cat(sprintf("file=%s\n", user_file))
if (nzchar(result_msg)) {
    cat("message<<<\n")
    cat(result_msg, "\n", sep = "")
    cat(">>>\n")
}
if (length(result_digest)) {
    cat("traceback<<<\n")
    for (line in result_digest) cat(line, "\n", sep = "")
    cat(">>>\n")
}
cat("=== BIOME_SMOKE_DIGEST_END ===\n")

if (result_status == "PASS") {
    cat("[r_smoke] PASS\n")
    quit(status = 0L, save = "no")
} else if (result_status == "TIMEOUT") {
    cat(sprintf(
        "[r_smoke] TIMEOUT after %ss — script needs a real run, not a smoke.\n",
        elapsed
    ))
    quit(status = 2L, save = "no")
} else {
    cat(sprintf("[r_smoke] FAIL: %s\n", result_msg))
    quit(status = 1L, save = "no")
}
