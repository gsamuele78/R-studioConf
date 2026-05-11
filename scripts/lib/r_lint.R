#!/usr/bin/env Rscript
# scripts/lib/r_lint.R — HC-13-compliant static linter for user R scripts.
#
# Reads a TSV rule file (default: scripts/lib/r_lint_rules.tsv), scans the
# user's .R file LINE-BY-LINE with each rule's regex, and emits TSV findings
# to stdout (and optionally Markdown if --md is passed).
#
# HC-13: this tool DESCRIBES findings, it never modifies the user file.
#
# Usage:
#   Rscript r_lint.R <user_script.R> [--rules /path/to/rules.tsv] [--md] [--severity HIGH|MED|LOW]
#
# Output (TSV, header included):
#   rule_id<TAB>severity<TAB>line<TAB>file<TAB>title<TAB>match
#
# Exit codes:
#   0 — no findings (or only LOW)
#   1 — at least one MED finding
#   2 — at least one HIGH finding (sysadmin should block re-run until addressed)
#   3 — invocation error (missing file, malformed rules)
#
# This script must remain dependency-free (base R only) so it runs under
# r_minimal_rscript without library() side effects.

suppressWarnings(suppressMessages({}))

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 1L) {
    cat("Usage: r_lint.R <user_script.R> [--rules PATH] [--md] [--severity HIGH|MED|LOW]\n",
        file = stderr()
    )
    quit(status = 3L, save = "no")
}

# ---- arg parsing ----
user_file <- NA_character_
rules_file <- NA_character_
emit_md <- FALSE
sev_floor <- "LOW" # report all by default
i <- 1L
while (i <= length(args)) {
    a <- args[[i]]
    if (a == "--rules" && i < length(args)) {
        rules_file <- args[[i + 1L]]
        i <- i + 2L
    } else if (a == "--md") {
        emit_md <- TRUE
        i <- i + 1L
    } else if (a == "--severity" && i < length(args)) {
        sev_floor <- toupper(args[[i + 1L]])
        i <- i + 2L
    } else if (startsWith(a, "--")) {
        cat(sprintf("r_lint.R: unknown flag '%s'\n", a), file = stderr())
        quit(status = 3L, save = "no")
    } else {
        if (is.na(user_file)) {
            user_file <- a
        } else {
            cat(sprintf("r_lint.R: unexpected positional arg '%s'\n", a), file = stderr())
            quit(status = 3L, save = "no")
        }
        i <- i + 1L
    }
}

if (is.na(user_file) || !file.exists(user_file)) {
    cat(sprintf("r_lint.R: file not found: %s\n", user_file), file = stderr())
    quit(status = 3L, save = "no")
}

# Default rules path: same dir as this script
if (is.na(rules_file)) {
    self <- normalizePath(
        sub(
            "^--file=", "",
            grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)[1L]
        ),
        mustWork = FALSE
    )
    if (is.na(self) || !nzchar(self)) self <- "scripts/lib/r_lint.R"
    rules_file <- file.path(dirname(self), "r_lint_rules.tsv")
}
if (!file.exists(rules_file)) {
    cat(sprintf("r_lint.R: rules file not found: %s\n", rules_file), file = stderr())
    quit(status = 3L, save = "no")
}

# ---- load rules ----
# Skip comment lines starting with '#', take TSV with header.
rules_raw <- readLines(rules_file, warn = FALSE)
rules_raw <- rules_raw[!grepl("^\\s*#", rules_raw) & nzchar(rules_raw)]
if (length(rules_raw) < 2L) {
    cat("r_lint.R: rules file has no rule rows\n", file = stderr())
    quit(status = 3L, save = "no")
}
con <- textConnection(rules_raw)
rules <- tryCatch(
    read.table(con,
        sep = "\t", header = TRUE, quote = "",
        comment.char = "", stringsAsFactors = FALSE,
        strip.white = FALSE, na.strings = ""
    ),
    error = function(e) {
        cat(sprintf(
            "r_lint.R: failed to parse rules: %s\n",
            conditionMessage(e)
        ), file = stderr())
        quit(status = 3L, save = "no")
    }
)
close(con)

req_cols <- c("id", "severity", "kind", "pattern", "title", "why", "fix", "doc_anchor")
miss <- setdiff(req_cols, names(rules))
if (length(miss)) {
    cat(sprintf(
        "r_lint.R: rules file missing columns: %s\n",
        paste(miss, collapse = ", ")
    ), file = stderr())
    quit(status = 3L, save = "no")
}

sev_rank <- c(LOW = 1L, MED = 2L, HIGH = 3L)
floor_rank <- sev_rank[[sev_floor]]
if (is.null(floor_rank) || is.na(floor_rank)) floor_rank <- 1L

# ---- scan user file ----
src <- readLines(user_file, warn = FALSE)
n_lines <- length(src)

# Strip line comments for regex match (but keep original text for display).
strip_comment <- function(line) sub("(?<!\\\\)#.*$", "", line, perl = TRUE)
src_no_comment <- vapply(src, strip_comment, character(1L), USE.NAMES = FALSE)

findings <- list()
fid <- 0L

for (r in seq_len(nrow(rules))) {
    rule <- rules[r, , drop = FALSE]
    rsev <- rule$severity
    rrank <- sev_rank[[rsev]]
    if (is.null(rrank) || is.na(rrank) || rrank < floor_rank) next

    pat <- rule$pattern
    matches <- tryCatch(
        grepl(pat, src_no_comment, perl = TRUE),
        error = function(e) {
            cat(sprintf(
                "r_lint.R: rule %s has invalid regex (%s)\n",
                rule$id, conditionMessage(e)
            ), file = stderr())
            rep(FALSE, n_lines)
        }
    )
    hit_lines <- which(matches)

    # R001 special case: makeCluster present but NO clusterExport anywhere
    if (rule$id == "R001" && length(hit_lines) > 0L) {
        if (any(grepl("clusterExport\\s*\\(", src_no_comment, perl = TRUE))) {
            hit_lines <- integer(0L)
        }
    }
    # R008 special case: only flag library() preceded by non-trivial code
    if (rule$id == "R008" && length(hit_lines) > 0L) {
        is_code_line <- function(s) {
            t <- trimws(s)
            if (!nzchar(t)) {
                return(FALSE)
            }
            if (startsWith(t, "#")) {
                return(FALSE)
            }
            if (grepl("^(library|require|suppressPackageStartupMessages|suppressMessages)\\s*\\(", t)) {
                return(FALSE)
            }
            TRUE
        }
        keep <- vapply(hit_lines, function(ln) {
            if (ln <= 1L) {
                return(FALSE)
            }
            any(vapply(
                src_no_comment[seq_len(ln - 1L)],
                is_code_line, logical(1L)
            ))
        }, logical(1L))
        hit_lines <- hit_lines[keep]
    }
    # R007 special case: skip if inside an interactive guard (heuristic)
    if (rule$id == "R007" && length(hit_lines) > 0L) {
        keep <- vapply(hit_lines, function(ln) {
            ctx <- paste(src_no_comment[max(1L, ln - 2L):ln], collapse = " ")
            !grepl("interactive\\s*\\(\\s*\\)", ctx, perl = TRUE)
        }, logical(1L))
        hit_lines <- hit_lines[keep]
    }

    for (ln in hit_lines) {
        fid <- fid + 1L
        findings[[fid]] <- list(
            id = rule$id, severity = rsev, line = ln,
            file = user_file, title = rule$title,
            match = trimws(substr(src[[ln]], 1L, 200L)),
            why = rule$why, fix = rule$fix, doc_anchor = rule$doc_anchor
        )
    }
}

# ---- emit ----
if (emit_md) {
    if (length(findings) == 0L) {
        cat("## R Lint — no findings ✓\n")
    } else {
        cat("## R Lint findings\n\n")
        cat(sprintf("**File:** `%s`  \n", user_file))
        cat(sprintf("**Total findings:** %d  \n\n", length(findings)))
        # Group by severity
        for (sev in c("HIGH", "MED", "LOW")) {
            sub <- Filter(function(f) f$severity == sev, findings)
            if (length(sub) == 0L) next
            cat(sprintf("### %s — %d finding(s)\n\n", sev, length(sub)))
            for (f in sub) {
                cat(sprintf("- **[%s] %s** (line %d)\n", f$id, f$title, f$line))
                cat(sprintf("  - line: `%s`\n", f$match))
                cat(sprintf("  - why: %s\n", f$why))
                cat(sprintf("  - fix: `%s`\n", f$fix))
                cat(sprintf("  - doc: PARALLEL_R_DOS_AND_DONTS.md%s\n\n", f$doc_anchor))
            }
        }
    }
} else {
    # TSV
    cat("rule_id\tseverity\tline\tfile\ttitle\tmatch\n")
    for (f in findings) {
        cat(sprintf(
            "%s\t%s\t%d\t%s\t%s\t%s\n",
            f$id, f$severity, f$line, f$file, f$title, f$match
        ))
    }
}

# ---- exit code ----
sev_seen <- vapply(findings, function(f) sev_rank[[f$severity]], integer(1L))
if (length(sev_seen) == 0L) quit(status = 0L, save = "no")
if (any(sev_seen >= 3L)) quit(status = 2L, save = "no")
if (any(sev_seen >= 2L)) quit(status = 1L, save = "no")
quit(status = 0L, save = "no")
