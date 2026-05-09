#!/usr/bin/env Rscript
# scripts/tools/r_pkg_drift_detector.R
# ============================================================================
# BIOME-CALC — Package Drift Detector
# ----------------------------------------------------------------------------
# Purpose: detect newly-installed or upgraded R packages that expose KNOWN
#          runtime knobs (threading, tempdir, BLAS linkage, new parallel
#          backends). When drift is detected, emit a JSON + human report so
#          the admin can extend the Rprofile fragments (50_pkg_hooks.R /
#          05_thread_guard.R) BEFORE a user script hits the regression.
#
# Paradigm: Pessimistic System Engineering — CRAN is the threat model, not
#           the users. Every release can silently add:
#             * a new `*_set_num_threads()` symbol
#             * a new `options("<pkg>.output_dir")` assumption
#             * a new parallel backend defaulting to detectCores()
#             * a new OpenMP linkage (potential BLAS pthread collision)
#
# Usage:   Rscript r_pkg_drift_detector.R [--baseline=/var/lib/biome-calc/pkg_baseline.rds]
#                                         [--json=/path/report.json]
#                                         [--quiet] [--update-baseline]
#
# Exit:    0 = no drift, 1 = drift detected (admin action suggested),
#          2 = new HIGH-RISK package, 3 = internal error
# ============================================================================

suppressPackageStartupMessages(invisible(NULL))

DRIFT_VERSION <- "1.0.0"

# ── Packages we already know how to handle (extend as fragments grow) ────────
# When one of these appears NEW or UPGRADED, log INFO — the profile covers it.
KNOWN_HANDLED <- c(
    "RhpcBLASctl", "parallel", "parallelly", "future", "future.apply",
    "doParallel", "foreach", "terra", "sf", "raster", "stars", "arrow",
    "nimble", "TMB", "rstan", "cmdstanr", "brms", "Rcpp", "RcppParallel",
    "data.table", "ggplot2", "keras", "tensorflow", "reticulate"
)

# ── Packages we DO NOT handle yet — any appearance = HIGH risk ────────────────
# These expose threading / tempdir / BLAS knobs the profile does not intercept.
# Expand this list as new threat-vector packages appear on CRAN.
KNOWN_UNHANDLED_HIGH_RISK <- c(
    "polars", # Rust runtime, own thread pool, ignores OMP_NUM_THREADS
    "duckdb", # own thread pool via PRAGMA threads
    "collapse", # set_collapse(nthreads=) — new threading knob
    "mirai", # new parallel backend, own worker model
    "crew", # dispatches via mirai/callr, detectCores defaults
    "parabar", # another parallel backend
    "RcppArmadillo", # OpenMP linkage — pthread/OpenBLAS collision risk
    "Rfast", # OpenMP linkage
    "Rfast2", # OpenMP linkage
    "torch", # own BLAS (LibTorch), ignores OPENBLAS_NUM_THREADS
    "keras3", # new TF front-end, different cache dirs
    "targets", # tempdir / cache sprawl
    "renv" # writes to ~/.cache/R/renv — NFS risk
)

# ── Patterns in DESCRIPTION that hint at a threading/tempdir knob ─────────────
# Heuristic scan of NEW packages' DESCRIPTION for risky markers.
RISK_PATTERNS <- list(
    openmp       = "(?i)openmp|SystemRequirements.*OpenMP",
    threads      = "(?i)set_?num_?threads|n_?threads|setDTthreads|setThreadOptions",
    tempdir_opt  = "(?i)output_?dir|cache_?dir|temp_?dir",
    parallel_be  = "(?i)makeCluster|PSOCK|detectCores|mc\\.cores"
)

# ---------------------------------------------------------------------------
parse_args <- function(argv) {
    out <- list(
        baseline = "/var/lib/biome-calc/pkg_baseline.rds",
        json     = NA_character_,
        quiet    = FALSE,
        update   = FALSE
    )
    for (a in argv) {
        if (startsWith(a, "--baseline=")) {
            out$baseline <- substring(a, 12)
        } else if (startsWith(a, "--json=")) {
            out$json <- substring(a, 8)
        } else if (identical(a, "--quiet")) {
            out$quiet <- TRUE
        } else if (identical(a, "--update-baseline")) {
            out$update <- TRUE
        } else if (a %in% c("--help", "-h")) {
            cat("Usage: r_pkg_drift_detector.R [--baseline=PATH] [--json=PATH] [--quiet] [--update-baseline]\n")
            quit(status = 0L, save = "no")
        }
    }
    out
}

snapshot_installed <- function() {
    ip <- tryCatch(
        installed.packages(fields = c(
            "Package", "Version", "LibPath", "Built",
            "NeedsCompilation", "Priority"
        )),
        error = function(e) NULL
    )
    if (is.null(ip) || nrow(ip) == 0L) {
        return(data.frame())
    }
    df <- as.data.frame(
        ip[, c(
            "Package", "Version", "LibPath", "Built",
            "NeedsCompilation", "Priority"
        ), drop = FALSE],
        stringsAsFactors = FALSE
    )
    # De-duplicate by package name (keep first libPath hit = effective on .libPaths)
    df <- df[!duplicated(df$Package), ]
    rownames(df) <- NULL
    df
}

load_baseline <- function(path) {
    if (!file.exists(path)) {
        return(NULL)
    }
    tryCatch(readRDS(path), error = function(e) NULL)
}

save_baseline <- function(df, path) {
    d <- dirname(path)
    if (!dir.exists(d)) dir.create(d, recursive = TRUE, showWarnings = FALSE, mode = "0755")
    saveRDS(df, path)
}

scan_package_risk <- function(pkg, libpath) {
    # Read DESCRIPTION + (if present) NAMESPACE to detect risk markers.
    desc_path <- file.path(libpath, pkg, "DESCRIPTION")
    ns_path <- file.path(libpath, pkg, "NAMESPACE")
    txt <- tryCatch(
        paste(c(
            if (file.exists(desc_path)) readLines(desc_path, warn = FALSE) else character(0),
            if (file.exists(ns_path)) readLines(ns_path, warn = FALSE) else character(0)
        ), collapse = "\n"),
        error = function(e) ""
    )
    hits <- vapply(
        RISK_PATTERNS, function(rx) grepl(rx, txt, perl = TRUE),
        logical(1)
    )
    names(hits)[hits]
}

classify <- function(pkg, risk_hits) {
    if (pkg %in% KNOWN_UNHANDLED_HIGH_RISK) {
        return("HIGH")
    }
    if (length(risk_hits) > 0L) {
        return("MEDIUM")
    }
    if (pkg %in% KNOWN_HANDLED) {
        return("HANDLED")
    }
    "LOW"
}

diff_snapshots <- function(current, baseline) {
    if (is.null(baseline) || !nrow(baseline)) {
        return(list(added = current, upgraded = data.frame(), removed = data.frame()))
    }
    merged <- merge(current, baseline,
        by = "Package",
        all = TRUE, suffixes = c(".new", ".old")
    )
    added <- merged[is.na(merged$Version.old) & !is.na(merged$Version.new), ]
    removed <- merged[!is.na(merged$Version.old) & is.na(merged$Version.new), ]
    upgraded <- merged[!is.na(merged$Version.old) & !is.na(merged$Version.new) &
        merged$Version.old != merged$Version.new, ]
    # Re-shape for consistency
    rehydrate <- function(x, version_col) {
        if (!nrow(x)) {
            return(data.frame())
        }
        data.frame(
            Package = x$Package,
            Version = x[[version_col]],
            LibPath = if ("LibPath.new" %in% names(x)) x$LibPath.new else NA_character_,
            stringsAsFactors = FALSE
        )
    }
    list(
        added = rehydrate(added, "Version.new"),
        upgraded = data.frame(
            Package = upgraded$Package,
            From = upgraded$Version.old,
            To = upgraded$Version.new,
            LibPath = upgraded$LibPath.new,
            stringsAsFactors = FALSE
        ),
        removed = rehydrate(removed, "Version.old")
    )
}

annotate_risk <- function(df) {
    if (!nrow(df)) {
        df$RiskMarkers <- character(0)
        df$Class <- character(0)
        return(df)
    }
    df$RiskMarkers <- vapply(seq_len(nrow(df)), function(i) {
        hits <- scan_package_risk(df$Package[i], df$LibPath[i])
        if (!length(hits)) "-" else paste(hits, collapse = ",")
    }, character(1))
    df$Class <- vapply(seq_len(nrow(df)), function(i) {
        hits <- if (df$RiskMarkers[i] == "-") {
            character(0)
        } else {
            strsplit(df$RiskMarkers[i], ",", fixed = TRUE)[[1]]
        }
        classify(df$Package[i], hits)
    }, character(1))
    df
}

emit_human <- function(rep) {
    sep <- strrep("=", 78)
    cat(sep, "\n")
    cat(sprintf(
        "BIOME-CALC Package Drift Report — v%s — %s\n",
        DRIFT_VERSION, format(Sys.time(), "%Y-%m-%d %H:%M:%S %Z")
    ))
    cat(sep, "\n\n")
    cat(sprintf("Host           : %s\n", Sys.info()[["nodename"]]))
    cat(sprintf("R version      : %s\n", R.version.string))
    cat(sprintf("Baseline file  : %s\n", rep$baseline_path))
    cat(sprintf(
        "Baseline age   : %s\n",
        if (is.na(rep$baseline_age_days)) {
            "(no baseline — first run)"
        } else {
            sprintf("%.1f days", rep$baseline_age_days)
        }
    ))
    cat(sprintf(
        "Total packages : %d (was %s)\n",
        rep$count_current,
        if (is.na(rep$count_baseline)) "-" else as.character(rep$count_baseline)
    ))
    cat("\n")

    print_block <- function(title, df, cols) {
        cat(sprintf("-- %s (%d) --\n", title, nrow(df)))
        if (!nrow(df)) {
            cat("  (none)\n\n")
            return(invisible())
        }
        for (i in seq_len(nrow(df))) {
            row <- df[i, , drop = FALSE]
            vals <- vapply(cols, function(k) as.character(row[[k]]), character(1))
            cat(sprintf(
                "  [%-6s] %s\n",
                row$Class %||% "-",
                paste(paste0(cols, "=", vals), collapse = "  ")
            ))
            if (!is.null(row$RiskMarkers) && row$RiskMarkers != "-") {
                cat(sprintf("           risk: %s\n", row$RiskMarkers))
            }
        }
        cat("\n")
    }
    `%||%` <- function(a, b) if (is.null(a) || length(a) == 0L) b else a

    print_block("ADDED", rep$added, c("Package", "Version"))
    print_block("UPGRADED", rep$upgraded, c("Package", "From", "To"))
    print_block("REMOVED", rep$removed, c("Package", "Version"))

    cat("-- Verdict --\n")
    cat(sprintf("  HIGH risk new/upgraded : %d\n", rep$n_high))
    cat(sprintf("  MEDIUM risk            : %d\n", rep$n_medium))
    cat(sprintf("  HANDLED by profile     : %d\n", rep$n_handled))
    cat(sprintf("  LOW / unknown-safe     : %d\n", rep$n_low))
    cat("\n")
    if (rep$n_high > 0L) {
        cat("  ACTION: extend /etc/R/Rprofile_site.d/50_pkg_hooks.R to intercept\n")
        cat("          threading/tempdir knobs for the HIGH-risk packages above.\n")
    } else if (rep$n_medium > 0L) {
        cat("  ACTION: review MEDIUM-risk packages' DESCRIPTION hints manually.\n")
    } else {
        cat("  No admin action required.\n")
    }
    cat("\n")
    cat(sprintf("[Exit code] %d\n", rep$exit_code))
    cat(sep, "\n")
}

emit_json <- function(rep, path) {
    if (requireNamespace("jsonlite", quietly = TRUE)) {
        writeLines(
            jsonlite::toJSON(rep,
                auto_unbox = TRUE, na = "null", null = "null",
                pretty = TRUE, force = TRUE
            ),
            path
        )
    } else {
        writeLines(c(
            "# jsonlite missing — dput() fallback",
            paste(deparse(rep), collapse = "\n")
        ), path)
    }
}

main <- function() {
    opts <- parse_args(commandArgs(trailingOnly = TRUE))
    current <- snapshot_installed()
    baseline <- load_baseline(opts$baseline)
    bage <- if (is.null(baseline)) {
        NA_real_
    } else {
        tryCatch(
            as.numeric(difftime(Sys.time(), file.info(opts$baseline)$mtime, units = "days")),
            error = function(e) NA_real_
        )
    }

    d <- diff_snapshots(current, baseline)
    d$added <- annotate_risk(d$added)
    d$upgraded <- annotate_risk(d$upgraded)

    n_high <- sum(d$added$Class == "HIGH", d$upgraded$Class == "HIGH")
    n_medium <- sum(d$added$Class == "MEDIUM", d$upgraded$Class == "MEDIUM")
    n_handled <- sum(d$added$Class == "HANDLED", d$upgraded$Class == "HANDLED")
    n_low <- sum(d$added$Class == "LOW", d$upgraded$Class == "LOW")

    exit_code <- if (n_high > 0L) {
        2L
    } else if (n_medium > 0L) {
        1L
    } else if (nrow(d$added) > 0L || nrow(d$upgraded) > 0L) {
        1L
    } else {
        0L
    }

    rep <- list(
        drift_version = DRIFT_VERSION,
        generated_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z"),
        hostname = Sys.info()[["nodename"]],
        r_version = R.version.string,
        baseline_path = opts$baseline,
        baseline_age_days = bage,
        count_current = nrow(current),
        count_baseline = if (is.null(baseline)) NA_integer_ else nrow(baseline),
        added = d$added,
        upgraded = d$upgraded,
        removed = d$removed,
        n_high = n_high,
        n_medium = n_medium,
        n_handled = n_handled,
        n_low = n_low,
        exit_code = exit_code
    )

    if (!opts$quiet) emit_human(rep)
    if (!is.na(opts$json) && nzchar(opts$json)) emit_json(rep, opts$json)

    if (opts$update) {
        tryCatch(save_baseline(current, opts$baseline),
            error = function(e) {
                message(sprintf(
                    "[WARN] Could not update baseline: %s",
                    conditionMessage(e)
                ))
            }
        )
        message(sprintf(
            "[INFO] Baseline updated: %s (%d packages)",
            opts$baseline, nrow(current)
        ))
    }

    quit(status = exit_code, save = "no")
}

tryCatch(main(), error = function(e) {
    message(sprintf("[FATAL] %s", conditionMessage(e)))
    quit(status = 3L, save = "no")
})
