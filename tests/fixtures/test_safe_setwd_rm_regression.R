# tests/fixtures/test_safe_setwd_rm_regression.R
# Validates fix: safe_setwd survives rm(list=ls(all.names=TRUE))
# Run via: Rscript tests/fixtures/test_safe_setwd_rm_regression.R
# Tests:
#   T1  — Template parses cleanly
#   T2  — setwd() works normally after fragment loads
#   T3  — setwd() works after rm(list=ls()) non-dot removal
#   T4  — setwd() works after rm(list=ls(all.names=TRUE))  (THE BUG)
#   T5  — Guard still hard-fails on bad path after rm (Martina-gate invariant)
#   T6  — .biome_original_setwd survives in globalenv for 80_tools_ext
#   T7  — Idempotency: re-sourcing fragment is safe
#   T8  — Extreme: rm(list=ls(all.names=TRUE)) + options(biome.strict_setwd=FALSE)
#   T9  — 80_tools_ext fallback pattern works after rm(all.names=TRUE)
#
# ALL test infrastructure is stored via options(), never as globalenv bindings.
# Options live in the base namespace — untouched by user-level rm() on globalenv.
# Each local() block retrieves what it needs via getOption() before any rm().
REQUIRED <- c(3L, 4L, 5L, 6L, 7L, 8L, 9L)

options(biome.test.results = list())
options(biome.test.required = REQUIRED)
options(biome.test.repo_root = getwd())
options(biome.test.tpl_path = file.path(getwd(), "templates/Rprofile_site.d/60_safe_setwd.R.template"))

.add_result_toplevel <- function(name, status, detail = "") {
  if (is.null(detail) || length(detail) == 0L || is.na(detail)) detail <- ""
  r <- getOption("biome.test.results")
  r[[name]] <- list(status = status, detail = detail)
  options(biome.test.results = r)
  cat(sprintf("  %s  %s", if (status == "PASS") "PASS" else "FAIL", name))
  if (nzchar(detail)) cat(sprintf("  (%s)", detail))
  cat("\n")
  invisible()
}
options(biome.test.add_result = .add_result_toplevel)

# ── T1: Template parses cleanly ─────────────────────────────────────────────
t1_ok <- tryCatch({
  exprs <- parse(file = getOption("biome.test.tpl_path"))
  length(exprs) >= 1L
}, error = function(e) FALSE)
.add_result_toplevel("T1", if (t1_ok) "PASS" else "FAIL",
                     if (!t1_ok) sprintf("parse failed: %s", conditionMessage(attr(t1_ok, "condition"))) else "")

# ── Helper: source fragment from template ────────────────────────────────────
# Uses literal relative path (from repo root) — independent of globalenv vars.
# Stored via options() so it survives rm() on globalenv.
options(biome.test.source_frag = function() {
  tpl <- readLines(getOption("biome.test.tpl_path"))
  tpl <- gsub("%%[A-Z0-9_]+%%", "1", tpl)
  f <- tempfile(fileext = ".R")
  on.exit(unlink(f), add = TRUE)
  writeLines(tpl, f)
  source(f, local = FALSE)
  invisible()
})

options(biome.test.mk_dir = function(prefix) {
  d <- tempfile(prefix)
  dir.create(d)
  normalizePath(d)
})

# Stub for sys_log (used inside tryCatch in fragment — safe to no-op)
sys_log <- function(...) invisible(NULL)

# Initial load
getOption("biome.test.source_frag")()
cat("  INFO  Fragment 60 sourced with stubs\n")

# ── T2: setwd() works normally ──────────────────────────────────────────────
local({
  ar <- getOption("biome.test.add_result")
  d <- getOption("biome.test.mk_dir")("t2_")
  ok <- tryCatch({
    setwd(d)
    identical(getwd(), d)
  }, error = function(e) FALSE)
  unlink(d, recursive = TRUE)
  ar("T2", if (ok) "PASS" else "FAIL",
     if (!ok) "setwd to valid dir failed after load" else "")
})

# ── T3: setwd() works after rm(list=ls()) (non-dot, in globalenv) ───────────
local({
  ar <- getOption("biome.test.add_result")
  mk <- getOption("biome.test.mk_dir")
  d <- mk("t3_")
  rm(list = ls(envir = globalenv(), all.names = FALSE), envir = globalenv())
  sys_log <- function(...) invisible(NULL)
  ok <- tryCatch({
    setwd(d)
    identical(getwd(), d)
  }, error = function(e) FALSE)
  unlink(d, recursive = TRUE)
  ar("T3", if (ok) "PASS" else "FAIL",
     if (!ok) sprintf("setwd failed after rm(): %s", conditionMessage(attr(ok, "condition"))) else "")
})

# ── T4: setwd() works after rm(list=ls(all.names=TRUE))  (THE BUG) ──────────
local({
  ar <- getOption("biome.test.add_result")
  mk <- getOption("biome.test.mk_dir")
  d <- mk("t4_")
  rm(list = ls(envir = globalenv(), all.names = TRUE), envir = globalenv())
  sys_log <- function(...) invisible(NULL)
  ok <- tryCatch({
    setwd(d)
    identical(getwd(), d)
  }, error = function(e) FALSE)
  unlink(d, recursive = TRUE)
  ar("T4", if (ok) "PASS" else "FAIL",
     if (!ok) sprintf("setwd failed after rm(all.names=TRUE): %s", conditionMessage(attr(ok, "condition"))) else "")
})

# ── T5: Guard still hard-fails on bad path after rm (Martina-gate) ──────────
local({
  ar <- getOption("biome.test.add_result")
  rm(list = ls(envir = globalenv(), all.names = TRUE), envir = globalenv())
  sys_log <- function(...) invisible(NULL)
  ok <- tryCatch({
    setwd("/definitely/does/not/exist/biome_test_XXXXXXXX")
    FALSE
  }, error = function(e) {
    grepl("BIOME-CALC safe_setwd", conditionMessage(e))
  })
  ar("T5", if (isTRUE(ok)) "PASS" else "FAIL",
     if (!isTRUE(ok)) "guard did not hard-fail on missing path in batch mode" else "")
})

# ── T6: .biome_original_setwd in globalenv for 80_tools_ext ─────────────────
local({
  ar <- getOption("biome.test.add_result")
  src <- getOption("biome.test.source_frag")
  src()
  ok <- tryCatch({
    exists(".biome_original_setwd", envir = globalenv(), inherits = FALSE) &&
      is.function(get(".biome_original_setwd", envir = globalenv(), inherits = FALSE))
  }, error = function(e) FALSE)
  ar("T6", if (ok) "PASS" else "FAIL",
     if (!ok) ".biome_original_setwd not found or not a function in globalenv" else "")
})

# ── T7: Idempotency — re-sourcing fragment is safe ──────────────────────────
local({
  ar <- getOption("biome.test.add_result")
  src <- getOption("biome.test.source_frag")
  ok <- tryCatch({
    capture.output(src())
    TRUE
  }, error = function(e) FALSE)
  ar("T7", if (ok) "PASS" else "FAIL",
     if (!ok) sprintf("re-source threw: %s", conditionMessage(attr(ok, "condition"))) else "")
})

# ── T8: Extreme — opt-out after rm(all.names=TRUE) ──────────────────────────
local({
  ar <- getOption("biome.test.add_result")
  src <- getOption("biome.test.source_frag")
  rm(list = ls(envir = globalenv(), all.names = TRUE), envir = globalenv())
  sys_log <- function(...) invisible(NULL)
  src()
  ok <- tryCatch({
    options(biome.strict_setwd = FALSE)
    result <- tryCatch(setwd("/definitely/does/not/exist/biome_test_XXXXXXXX"),
                        error = function(e) "errored",
                        warning = function(w) "warned")
    !grepl("BIOME-CALC", paste(result, collapse = " "))
  }, error = function(e) FALSE)
  options(biome.strict_setwd = TRUE)
  ar("T8", if (isTRUE(ok)) "PASS" else "FAIL",
     if (!isTRUE(ok)) "opt-out mode still raised BIOME-CALC error" else "")
})

# ── T9: 80_tools_ext fallback after rm(all.names=TRUE) ──────────────────────
local({
  ar <- getOption("biome.test.add_result")
  src <- getOption("biome.test.source_frag")
  mk <- getOption("biome.test.mk_dir")
  rm(list = ls(envir = globalenv(), all.names = TRUE), envir = globalenv())
  sys_log <- function(...) invisible(NULL)
  src()
  d <- mk("t9_")
  ok <- tryCatch({
    if (exists(".biome_original_setwd", envir = globalenv(), inherits = FALSE)) {
      get(".biome_original_setwd", envir = globalenv())(d)
    } else {
      setwd(d)
    }
    identical(getwd(), d)
  }, error = function(e) FALSE)
  unlink(d, recursive = TRUE)
  ar("T9", if (ok) "PASS" else "FAIL",
     if (!ok) "80_tools_ext fallback pattern failed after rm(all.names=TRUE)" else "")
})

# ── Summary ─────────────────────────────────────────────────────────────────
r <- getOption("biome.test.results")
req <- getOption("biome.test.required")
passed <- sum(vapply(r, function(x) identical(x$status, "PASS"), logical(1)))
failed <- sum(vapply(r, function(x) identical(x$status, "FAIL"), logical(1)))
cat(sprintf("\n  %d/%d passed, %d failed\n", passed, length(r), failed))

for (req_id in req) {
  nm <- sprintf("T%d", req_id)
  if (!identical(r[[nm]]$status, "PASS")) {
    cat(sprintf("  CRITICAL: Required test %s FAILED — fix regression\n", nm))
    quit(status = 1, save = "no")
  }
}

if (failed > 0) quit(status = 2, save = "no")
quit(status = 0, save = "no")
