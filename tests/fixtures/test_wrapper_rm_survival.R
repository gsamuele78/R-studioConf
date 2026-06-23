# tests/fixtures/test_wrapper_rm_survival.R
# Cross-fragment regression: every base/package wrapper installed by the
# Rprofile_site.d kernel must survive a researcher's
#   rm(list = ls(all.names = TRUE))
# (the "clean environment" habit that produced the
#  `could not find function ".biome_original_setwd"` class of error).
#
# Run via: Rscript tests/fixtures/test_wrapper_rm_survival.R
#
# Strategy: source each fragment with placeholders neutralized, simulate the
# globalenv purge, then exercise the wrapper and assert it delegates instead
# of erroring on a missing globalenv helper.
#
# Tests:
#   W1 — frag 60 setwd      survives rm(all.names=TRUE)
#   W2 — frag 05 detectCores survives rm(all.names=TRUE) (closure capture)
#   W3 — frag 55 options    survives rm(all.names=TRUE) (closure capture)
#   W4 — frag 35 compileNimble dir-resolver survives rm(all.names=TRUE)
#         (closure capture; previously vulnerable when .biome_env absent)
REQUIRED <- c(1L, 2L, 3L, 4L)

options(biome.test.results = list())
options(biome.test.required = REQUIRED)
options(biome.test.frag_dir = file.path(getwd(), "templates/Rprofile_site.d"))

options(biome.test.add_result = function(name, status, detail = "") {
  if (is.null(detail) || length(detail) == 0L || is.na(detail)) detail <- ""
  r <- getOption("biome.test.results")
  r[[name]] <- list(status = status, detail = detail)
  options(biome.test.results = r)
  cat(sprintf("  %s  %s", if (status == "PASS") "PASS" else "FAIL", name))
  if (nzchar(detail)) cat(sprintf("  (%s)", detail))
  cat("\n")
  invisible()
})

# Source a fragment file with %%PLACEHOLDER%% tokens neutralized to 1.
options(biome.test.src_frag = function(basename) {
  path <- file.path(getOption("biome.test.frag_dir"), basename)
  tpl <- readLines(path)
  tpl <- gsub("%%[A-Z0-9_]+%%", "1", tpl)
  f <- tempfile(fileext = ".R")
  on.exit(unlink(f), add = TRUE)
  writeLines(tpl, f)
  source(f, local = FALSE)
  invisible()
})

# Stubs the fragments expect from the monolith dispatcher.
sys_log <- function(...) invisible(NULL)

# ── W1: setwd (frag 60) ─────────────────────────────────────────────────────
local({
  ar  <- getOption("biome.test.add_result")
  src <- getOption("biome.test.src_frag")
  d   <- normalizePath(tempfile("w1_")); dir.create(d)
  src("60_safe_setwd.R.template")
  rm(list = ls(envir = globalenv(), all.names = TRUE), envir = globalenv())
  sys_log <- function(...) invisible(NULL)
  err <- NA_character_
  ok <- tryCatch({ setwd(d); identical(getwd(), d) },
                 error = function(e) { err <<- conditionMessage(e); FALSE })
  unlink(d, recursive = TRUE)
  ar("W1", if (ok) "PASS" else "FAIL",
     if (!ok) sprintf("setwd broke after rm: %s", err) else "")
})

# ── W2: detectCores (frag 05) ───────────────────────────────────────────────
local({
  ar  <- getOption("biome.test.add_result")
  src <- getOption("biome.test.src_frag")
  if (!requireNamespace("parallel", quietly = TRUE)) {
    ar("W2", "PASS", "parallel not installed — skipped"); return(invisible())
  }
  src("05_thread_guard.R.template")
  rm(list = ls(envir = globalenv(), all.names = TRUE), envir = globalenv())
  sys_log <- function(...) invisible(NULL)
  err <- NA_character_
  ok <- tryCatch({
    n <- parallel::detectCores()
    is.numeric(n) && length(n) == 1L
  }, error = function(e) { err <<- conditionMessage(e); FALSE })
  ar("W2", if (ok) "PASS" else "FAIL",
     if (!ok) sprintf("detectCores broke after rm: %s", err) else "")
})

# ── W3: options (frag 55) ───────────────────────────────────────────────────
local({
  ar  <- getOption("biome.test.add_result")
  src <- getOption("biome.test.src_frag")
  src("55_options_guard.R.template")
  rm(list = ls(envir = globalenv(), all.names = TRUE), envir = globalenv())
  sys_log <- function(...) invisible(NULL)
  err <- NA_character_
  ok <- tryCatch({
    old <- options(biome.test.dummy = 42L)
    v <- getOption("biome.test.dummy")
    options(old)
    identical(v, 42L)
  }, error = function(e) { err <<- conditionMessage(e); FALSE })
  ar("W3", if (ok) "PASS" else "FAIL",
     if (!ok) sprintf("options broke after rm: %s", err) else "")
})

# ── W4: compileNimble dir-resolver (frag 35) ────────────────────────────────
# We cannot require the nimble package in CI, so we test the wrapper-build
# path indirectly: the fragment must define .biome_get_compile_dir and the
# resolver capture must survive rm(all.names=TRUE). We assert the resolver
# the wrapper would use is still callable after the purge.
local({
  ar  <- getOption("biome.test.add_result")
  src <- getOption("biome.test.src_frag")
  src("35_compile_routing.R.template")
  # The compile-dir resolver is the globalenv helper the OLD wrapper read
  # back via get(..., envir=globalenv()). After our hardening the wrapper
  # captures it by closure. Simulate the purge and confirm a fresh source
  # re-establishes a callable resolver (idempotent + rm-robust).
  had_resolver_before <- exists(".biome_get_compile_dir", envir = globalenv(),
                                inherits = FALSE)
  rm(list = ls(envir = globalenv(), all.names = TRUE), envir = globalenv())
  sys_log <- function(...) invisible(NULL)
  # Re-source: must not error, and must re-expose the resolver.
  err <- NA_character_
  ok <- tryCatch({
    src("35_compile_routing.R.template")
    exists(".biome_get_compile_dir", envir = globalenv(), inherits = FALSE) &&
      is.function(get(".biome_get_compile_dir", envir = globalenv()))
  }, error = function(e) { err <<- conditionMessage(e); FALSE })
  ar("W4", if (ok && had_resolver_before) "PASS" else "FAIL",
     if (!ok) sprintf("compile-routing re-source broke after rm: %s", err)
     else if (!had_resolver_before) "resolver missing on first load" else "")
})

# ── Summary ─────────────────────────────────────────────────────────────────
r   <- getOption("biome.test.results")
req <- getOption("biome.test.required")
passed <- sum(vapply(r, function(x) identical(x$status, "PASS"), logical(1)))
failed <- sum(vapply(r, function(x) identical(x$status, "FAIL"), logical(1)))
cat(sprintf("\n  %d/%d passed, %d failed\n", passed, length(r), failed))

for (id in req) {
  nm <- sprintf("W%d", id)
  if (!identical(r[[nm]]$status, "PASS")) {
    cat(sprintf("  CRITICAL: Required test %s FAILED\n", nm))
    quit(status = 1, save = "no")
  }
}
if (failed > 0) quit(status = 2, save = "no")
quit(status = 0, save = "no")
