#!/usr/bin/env Rscript
# tests/rprofile_quota_test.R — exact quota helper block from fragment 70

frag <- readLines("templates/Rprofile_site.d/70_persistent_tools.R.template", warn = FALSE)
start <- grep("# v12.11 . Home quota", frag)[1]
end <- grep('assign\\("biome_save_session"', frag)[1] - 1L
stopifnot(is.finite(start), is.finite(end), end > start)
code <- paste(frag[start:end], collapse = "\n")
code <- gsub("%%ENABLE_HOME_QUOTA_VIEW%%", "true", code, fixed = TRUE)
code <- gsub("%%QUOTA_WARN_PCT%%", "90", code, fixed = TRUE)
code <- gsub("%%QUOTA_STALE_MIN%%", "30", code, fixed = TRUE)

.C_RED <- .C_YELLOW <- .C_RESET <- ""
tool_env <- new.env(parent = globalenv())
eval(parse(text = code), envir = globalenv())
quota <- get("biome_quota", envir = tool_env)

root <- tempfile("biome-quota-")
dir.create(root)
Sys.setenv(BIOME_QUOTA_CACHE_DIR = root)
uid <- trimws(system2("id", "-u", stdout = TRUE))
f <- file.path(root, uid)
now <- as.numeric(Sys.time())
write_quota <- function(used, limit, objects, object_limit, stamp = now) {
  writeLines(paste(used, limit, objects, object_limit, stamp, sep = "\t"), f)
}
msg <- function() paste(capture.output(quota(), type = "message"), collapse = "\n")

# disabled: no misleading "not available" — explicitly says feature is off
.biome_quota_enabled <- FALSE
stopifnot(grepl("not enabled", msg(), fixed = TRUE))
.biome_quota_enabled <- TRUE

# missing
stopifnot(grepl("not available", msg(), fixed = TRUE))
# 98%, no object limit
write_quota(147 * 1024^3, 150 * 1024^3, 361, "none")
x <- msg()
stopifnot(grepl("147.0 GB of 150.0 GB used (98%)", x, fixed = TRUE))
stopifnot(grepl("Almost full", x, fixed = TRUE))
stopifnot(grepl("Files : 361 (no limit)", x, fixed = TRUE))
stopifnot(grepl("98%", .biome_quota_line(), fixed = TRUE))
# no limit
write_quota(12 * 1024^3, "none", 7, "none")
stopifnot(grepl("no personal limit", msg(), fixed = TRUE))
# stale
write_quota(12 * 1024^3, 100 * 1024^3, 7, 1000, stamp = now - 7200)
stopifnot(grepl("may be out of date", msg(), fixed = TRUE))
# malformed (wrong field count and non-numeric required field)
writeLines("bad", f)
stopifnot(grepl("not available", msg(), fixed = TRUE))
writeLines(paste("NaN", "none", 7, "none", now, sep = "\t"), f)
stopifnot(grepl("not available", msg(), fixed = TRUE))
cat("rprofile_quota_test: PASS\n")
