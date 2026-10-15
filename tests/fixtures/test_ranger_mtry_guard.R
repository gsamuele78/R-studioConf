# tests/fixtures/test_ranger_mtry_guard.R
# Validates the v12.11-fix2 ranger mtry guard in the Rprofile dispatcher.
# Run via: Rscript --vanilla tests/fixtures/test_ranger_mtry_guard.R  (from repo root)
# Tests:
#   G1 — mtry == predictors (dependent.variable.name)  -> trains
#   G2 — mtry  > predictors (dependent.variable.name)  -> clear BIOME-CALC error (THE BUG)
#   G3 — formula interface, valid mtry                  -> trains (not checked)
#   G4 — x/y interface, mtry > predictors               -> clear error
#   G5 — default mtry                                   -> trains
#   G6 — recorded call unchanged (trace keeps sys.call) -> model$call is the user's call
#   G7 — options(biome.ranger_mtry_guard = FALSE)       -> guard not installed
#   G8 — PSOCK worker (no profile, block sourced)        -> clear error crosses the worker
#   G9 — mlr3 shape: 9 predictors + target, mtry 11      -> clear error naming 11 and 9
if (!requireNamespace("ranger", quietly = TRUE)) {
  cat("  FAIL  G0  package 'ranger' not installed (CI installs it; install it locally)\n")
  quit(status = 2)
}
tpl <- "templates/Rprofile_site.R.template"
src <- readLines(tpl)
a <- grep("# >>> biome_ranger_mtry_guard", src, fixed = TRUE)
b <- grep("# <<< biome_ranger_mtry_guard", src, fixed = TRUE)
if (length(a) != 1L || length(b) != 1L || b <= a) {
  cat("  FAIL  G0  guard markers not found in", tpl, "\n"); quit(status = 1)
}
block <- src[(a + 1L):(b - 1L)]
guard_file <- tempfile(fileext = ".R"); writeLines(block, guard_file)

fails <- 0L
check <- function(id, ok, detail = "") {
  cat(sprintf("  %s  %s %s\n", if (isTRUE(ok)) "PASS" else "FAIL", id, detail))
  if (!isTRUE(ok)) fails <<- fails + 1L
}
run <- function(expr) tryCatch({ force(expr); "OK" }, error = function(e) conditionMessage(e))
is_guard_err <- function(msg) grepl("^BIOME-CALC: ranger mtry", msg)

# G7 first: opt-out must leave ranger untouched
op <- options(biome.ranger_mtry_guard = FALSE)
source(guard_file)
check("G7", !inherits(get("ranger", asNamespace("ranger")), "functionWithTrace"), "(opt-out)")
options(op)
source(guard_file)   # namespace already loaded -> installs immediately
check("G0", inherits(get("ranger", asNamespace("ranger")), "functionWithTrace"), "(guard installed)")

set.seed(1); n <- 200
d <- data.frame(y = rnorm(n), a = rnorm(n), b = rnorm(n),
                f = factor(sample(letters[1:3], n, TRUE)))
check("G1", run(ranger::ranger(dependent.variable.name = "y", data = d, mtry = 3, num.trees = 10)) == "OK")
check("G2", is_guard_err(run(ranger::ranger(dependent.variable.name = "y", data = d, mtry = 4, num.trees = 10))))
check("G3", run(ranger::ranger(y ~ ., d, mtry = 2, num.trees = 10)) == "OK")
check("G4", is_guard_err(run(ranger::ranger(x = d[, -1], y = d$y, mtry = 5, num.trees = 10))))
check("G5", run(ranger::ranger(y ~ ., d, num.trees = 10)) == "OK")
m <- ranger::ranger(y ~ ., d, num.trees = 10)
check("G6", identical(deparse(m$call), "ranger::ranger(y ~ ., d, num.trees = 10)"))

cl <- parallel::makeCluster(1L)
w <- tryCatch({
  parallel::clusterCall(cl, function(p) { source(p); invisible() }, guard_file)
  parallel::clusterCall(cl, function(d) tryCatch({
    ranger::ranger(dependent.variable.name = "y", data = d, mtry = 11, num.trees = 10); "OK"
  }, error = function(e) conditionMessage(e)), d)[[1]]
}, finally = parallel::stopCluster(cl))
check("G8", is_guard_err(w), "(PSOCK worker)")

d9 <- data.frame(medianRarity = rnorm(n), matrix(rnorm(n * 9), n, 9))
msg <- run(ranger::ranger(dependent.variable.name = "medianRarity", data = d9,
                          mtry = 11, num.trees = 10, importance = "permutation"))
check("G9", is_guard_err(msg) && grepl("mtry = 11", msg) && grepl("only 9 predictor", msg))

unlink(guard_file)
if (fails > 0L) { cat(sprintf("  %d test(s) FAILED\n", fails)); quit(status = 1) }
cat("  ALL RANGER GUARD TESTS PASSED\n")
