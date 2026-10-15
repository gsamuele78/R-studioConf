# tests/fixtures/test_parquet_sidecar_gate.R
# Validates the v12.11-fix2 parquet sidecar gate in fragment 50 (Smart I/O).
# Run via: Rscript tests/fixtures/test_parquet_sidecar_gate.R  (from repo root)
# Tests:
#   P1 — no sidecar                         -> CSV path (NULL)
#   P2 — fresh sidecar, no extra args        -> sidecar used
#   P3 — sidecar older than CSV (THE BUG)    -> CSV path + "stale" message
#   P4 — extra reader args (sep=";")          -> CSV path
#   P5 — options(biome.parquet_sidecar=FALSE) -> CSV path
#   P6 — non-interactive (Rscript, workers)  -> CSV path
#   P7 — bad path types (NA, vector, "")     -> CSV path, no error
#   P8 — write.csv after read restores CSV   -> researcher scenario end to end
tpl <- "templates/Rprofile_site.d/50_pkg_hooks.R.template"
src <- readLines(tpl)
a <- grep("# >>> biome_parquet_sidecar", src, fixed = TRUE)
b <- grep("# <<< biome_parquet_sidecar", src, fixed = TRUE)
if (length(a) != 1L || length(b) != 1L || b <= a) {
  cat("  FAIL  P0  sidecar gate markers not found in", tpl, "\n"); quit(status = 1)
}
eval(parse(text = src[(a + 1L):(b - 1L)]))
stopifnot(is.function(.biome_parquet_sidecar))

fails <- 0L
check <- function(id, ok, detail = "") {
  cat(sprintf("  %s  %s %s\n", if (isTRUE(ok)) "PASS" else "FAIL", id, detail))
  if (!isTRUE(ok)) fails <<- fails + 1L
}
gate <- function(...) .biome_parquet_sidecar(..., is_interactive = TRUE)
d <- tempfile("pq_gate"); dir.create(d)
csv <- file.path(d, "occ.csv"); pq <- paste0(csv, ".parquet")
writeLines("a,b\n1,2", csv)
now <- Sys.time()
Sys.setFileTime(csv, now - 60)

check("P1", is.null(gate(csv)), "(no sidecar)")

writeLines("stub", pq); Sys.setFileTime(pq, now)
check("P2", identical(gate(csv), pq), "(fresh sidecar)")

Sys.setFileTime(csv, now + 60)   # researcher rewrote the CSV after the sidecar
msg <- NULL
r3 <- withCallingHandlers(gate(csv), message = function(m) {
  msg <<- conditionMessage(m); invokeRestart("muffleMessage") })
check("P3", is.null(r3) && !is.null(msg) && grepl("stale", msg), "(stale sidecar ignored)")
Sys.setFileTime(csv, now - 60)

check("P4", is.null(gate(csv, n_extra_args = 1L)), "(extra args)")

op <- options(biome.parquet_sidecar = FALSE)
check("P5", is.null(gate(csv)), "(opt-out)")
options(op)

check("P6", is.null(.biome_parquet_sidecar(csv, is_interactive = FALSE)), "(non-interactive)")

check("P7", is.null(gate(NA_character_)) && is.null(gate(c(csv, csv))) &&
            is.null(gate("")) && is.null(gate(42)), "(bad path types)")

# P8: the reported sequence — read (sidecar fresh), write.csv, read again.
Sys.setFileTime(pq, now - 120); Sys.setFileTime(csv, now - 180)
first <- gate(csv)
write.csv(data.frame(a = 9, b = 8), csv, row.names = FALSE)
second <- suppressMessages(gate(csv))
check("P8", identical(first, pq) && is.null(second), "(write.csv invalidates sidecar)")

unlink(d, recursive = TRUE)
if (fails > 0L) { cat(sprintf("  %d test(s) FAILED\n", fails)); quit(status = 1) }
cat("  ALL SIDECAR GATE TESTS PASSED\n")
