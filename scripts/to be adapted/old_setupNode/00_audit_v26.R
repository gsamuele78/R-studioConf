# ==============================================================================
# BIOME-CALC: ENTERPRISE INFRASTRUCTURE AUDIT v26.1
# ==============================================================================
# Target: RStudio Server Open Source (Web Console Safe)
# Usage:  source("00_audit_v26.R")
#
# CHANGES from v26.0:
#   - AI model read from /etc/biome-calc/ai_model (no longer hardcoded codellama)
#   - WARN/FAIL severity split: QEMU cpu→WARN, CORETYPE mismatch→FAIL
#   - [1.4] Now FAILS if reference BLAS instead of OpenBLAS (10-50x perf diff)
#   - [1.5] Checks /etc/environment for stale static thread vars
#   - [1.6] Validates OpenMP pkg-config for R package compilation
#   - [2.3] Ollama Security (localhost binding check)
#   - [2.4] Ollama Model Readiness (configured model availability)
#   - [2.5] Ollama Systemd Hardening (MemoryMax, idle-unload, single-model)
#   - [4.5] System Log Permissions check
#   - suppressWarnings on mccollect (eliminates cosmetic noise)
#   - Self-heal /var/log/r_biome_system.log permissions on startup
# ==============================================================================

suppressMessages({
  library(utils)
  library(parallel)
})

# ── Setup Logging (NO sink — safe for RStudio websocket) ──
LOG_FILE <- file.path(Sys.getenv("HOME"), "biome_audit.log")
# Truncate log at start
tryCatch(cat("", file = LOG_FILE), error = function(e) NULL)

# Self-heal: ensure /var/log/r_biome_system.log is writable
# (setup_nodes_v7.2 creates this with correct perms, but if it was
# created before rstudio-server group existed, it may be root-only)
SYS_LOG <- "/var/log/r_biome_system.log"
tryCatch({
  if (file.exists(SYS_LOG) && file.access(SYS_LOG, 2) != 0) {
    # Can't write — try to fix if we're root, otherwise just warn
    if (Sys.info()[["user"]] == "root") {
      system(sprintf("chmod 666 '%s'", SYS_LOG), intern = FALSE)
    }
  } else if (!file.exists(SYS_LOG)) {
    # Create it if missing (will only work if /var/log is writable)
    tryCatch(cat("", file = SYS_LOG), error = function(e) NULL)
  }
}, error = function(e) NULL)

# Dual-write: console + logfile (replaces sink(split=TRUE))
audit_cat <- function(...) {
  msg <- paste0(...)
  cat(msg)
  tryCatch(cat(msg, file = LOG_FILE, append = TRUE), error = function(e) NULL)
}

# ── ANSI Colors ──
.A0 <- "\033[0m"; .AR <- "\033[31m"; .AG <- "\033[32m"
.AY <- "\033[33m"; .AB <- "\033[1;34m"; .AC <- "\033[36m"

audit_cat(paste0("\n", .AB,
  "==================================================================\n",
  "  BIOME-CALC ENTERPRISE AUDIT v26.1\n",
  "  ", format(Sys.time(), "%d %B %Y - %H:%M:%S"), "\n",
  "  Host: ", Sys.info()[["nodename"]], " | User: ", Sys.info()[["user"]], "\n",
  "==================================================================", .A0, "\n"))

# ── Configuration ──
# Read active AI model from setup_nodes config (written by Step 11)
.ai_model_default <- tryCatch({
  mf <- "/etc/biome-calc/ai_model"
  if (file.exists(mf)) trimws(readLines(mf, n = 1, warn = FALSE)) else "codellama:7b"
}, error = function(e) "codellama:7b")

conf <- list(
  ollama_port  = 11434,
  ollama_api   = "http://127.0.0.1:11434/api/generate",
  ai_model     = .ai_model_default,
  max_tmp_pct  = 85,
  max_threads  = 16L
)

audit_log <- list()

# ── Fork-Safe Timeout (replaces setTimeLimit) ──
# mcparallel forks a child process — if it hangs (BLAS livelock, curl),
# we pskill(SIGKILL) the child. setTimeLimit cannot do this.
safe_eval <- function(expr, timeout = 20) {
  if (.Platform$OS.type == "unix") {
    job <- parallel::mcparallel(expr)
    # suppressWarnings: mccollect emits "did not deliver a result" on
    # normal completion if the collect window is tight. Harmless noise.
    res <- suppressWarnings(parallel::mccollect(job, wait = FALSE, timeout = timeout))
    if (is.null(res)) {
      # Child hung — kill it hard
      try(tools::pskill(job$pid, signal = 9L), silent = TRUE)
      suppressWarnings(try(parallel::mccollect(job, wait = FALSE, timeout = 1), silent = TRUE))
      stop(sprintf("Timeout after %ds (child killed)", timeout))
    }
    val <- res[[1]]
    if (inherits(val, "try-error")) stop(attr(val, "condition")$message %||% as.character(val))
    return(val)
  }
  # Non-Unix fallback (limited — cannot interrupt C-level)
  setTimeLimit(elapsed = timeout, transient = TRUE)
  on.exit(setTimeLimit(elapsed = Inf))
  force(expr)
}

# ── Test Runner ──
run_audit <- function(id, name, expr, fix_hint = "Contact SysAdmin", timeout = 20, use_fork = FALSE) {
  # Safety: abort if /tmp is nearly full
  tryCatch({
    df <- as.numeric(sub("%", "", system("df -h /tmp | tail -1 | awk '{print $5}'", intern = TRUE)))
    if (df > conf$max_tmp_pct) stop("Safety Abort: /tmp full")
  }, error = function(e) stop("Safety check failed"))

  audit_cat(sprintf("[%s] %-45s ", id, name)); flush.console()

  # Use warning() in test expressions for advisory WARN (non-fatal).
  # Use stop() for hard FAIL.
  warn_msg <- NULL
  res <- tryCatch(
    withCallingHandlers({
      if (use_fork) {
        val <- safe_eval(expr, timeout = timeout)
      } else {
        setTimeLimit(elapsed = timeout, transient = TRUE)
        val <- force(expr)
        setTimeLimit(elapsed = Inf)
      }
      # If a warning was captured, promote to WARN status
      if (!is.null(warn_msg)) {
        list(s = "WARN", m = warn_msg)
      } else {
        list(s = "PASS", m = if (is.character(val)) val else "OK")
      }
    }, warning = function(w) {
      warn_msg <<- conditionMessage(w)
      invokeRestart("muffleWarning")
    }),
    error = function(e) {
      setTimeLimit(elapsed = Inf)
      list(s = "FAIL", m = e$message)
    },
    finally = { gc(verbose = FALSE) }
  )

  audit_log[[id]] <<- list(s = res$s, m = res$m, fix = fix_hint)
  status_color <- switch(res$s, "PASS" = .AG, "WARN" = .AY, .AR)
  audit_cat(paste0(status_color, "[", res$s, "]", .A0,
    if (res$m != "OK") sprintf(" (%s)", res$m) else "", "\n"))
  flush.console()
}

# ==============================================================================
# [1.0] CONFIGURATION & THREAD SAFETY
# ==============================================================================
audit_cat("\n[1.0] CONFIGURATION & THREAD SAFETY\n")

run_audit("1.1", "Rprofile Status", {
  if (!exists("status")) stop("Rprofile not loaded (status() missing)")
  "Active"
})

run_audit("1.2", "Thread Capping Check (Max 16)", {
  omp <- as.integer(Sys.getenv("OMP_NUM_THREADS"))
  if (is.na(omp)) stop("OMP_NUM_THREADS unset")
  if (omp > conf$max_threads) stop(sprintf("UNSAFE: Threads=%d (Must be <= %d for QEMU)", omp, conf$max_threads))
  sprintf("Safe: %d threads", omp)
}, fix_hint = "Update to Rprofile >= v9.3.14")

# ── CPU Model & OPENBLAS_CORETYPE Sanity Check ──
# QEMU emulated CPU alone is a WARN (advisory — Rprofile auto-corrects).
# CORETYPE vendor mismatch is a FAIL (dangerous — causes BLAS livelock).
run_audit("1.3", "CPU Model Detection", {
  cpuinfo <- tryCatch(readLines("/proc/cpuinfo", warn = FALSE), error = function(e) "")
  model_line <- grep("^model name", cpuinfo, value = TRUE)[1]
  vendor_line <- grep("^vendor_id", cpuinfo, value = TRUE)[1]
  model_name <- trimws(sub(".*:\\s*", "", model_line))
  vendor_id  <- trimws(sub(".*:\\s*", "", vendor_line))
  coretype <- Sys.getenv("OPENBLAS_CORETYPE", "")

  # Hard FAIL: CORETYPE vendor mismatch (this causes livelocks)
  if (nchar(coretype) > 0) {
    intel_types <- c("HASWELL", "SKYLAKEX", "SANDYBRIDGE", "IVYBRIDGE", "BROADWELL", "PRESCOTT")
    amd_types   <- c("ZEN", "BULLDOZER", "PILEDRIVER", "STEAMROLLER", "EXCAVATOR", "BARCELONA")
    if (grepl("AMD", vendor_id, ignore.case = TRUE) && toupper(coretype) %in% intel_types) {
      stop(sprintf("CORETYPE=%s (Intel) on AMD CPU — BLAS will livelock!", coretype))
    }
    if (grepl("Intel", vendor_id, ignore.case = TRUE) && toupper(coretype) %in% amd_types) {
      stop(sprintf("CORETYPE=%s (AMD) on Intel CPU — mismatch", coretype))
    }
  }

  info <- sprintf("%s (%s, CORETYPE=%s)", model_name, vendor_id,
    if (nchar(coretype) > 0) coretype else "auto")

  # Soft WARN: QEMU model name means emulated CPU (even x86-64-v4 shows this).
  # This is advisory only — Rprofile auto-corrects CORETYPE from vendor_id.
  if (grepl("QEMU", model_name, ignore.case = TRUE)) {
    warning(sprintf("Virtual CPU — recommend cpu:host if no live-migration needed (%s)", info))
  }

  info
}, fix_hint = "Set cpu:host in Proxmox VM config for best performance")

run_audit("1.4", "BLAS Library Check", {
  si <- sessionInfo()
  blas <- si$BLAS
  lapack <- si$LAPACK
  blas_base <- basename(blas)
  # Reference BLAS (libblas.so.3 → /usr/lib/.../blas/) is 10-50x slower than OpenBLAS.
  # This is the single biggest performance issue for any R linear algebra workload.
  if (grepl("openblas", blas, ignore.case = TRUE)) {
    variant <- if (grepl("pthread", blas)) "pthread" else
               if (grepl("openmp", blas)) "openmp" else "unknown-variant"
    sprintf("OpenBLAS (%s)", variant)
  } else if (grepl("/blas/", blas)) {
    stop(sprintf("Reference BLAS active (%s) — 10-50x slower! Run: update-alternatives --set libblas.so.3-x86_64-linux-gnu /usr/lib/x86_64-linux-gnu/openblas-pthread/libblas.so.3", blas_base))
  } else {
    warning(sprintf("Non-OpenBLAS: %s — verify performance", blas_base))
  }
}, fix_hint = "Run setup_nodes_v7.2.sh (sets BLAS alternative) or: sudo update-alternatives --config libblas.so.3-x86_64-linux-gnu")

run_audit("1.5", "Stale Env Vars (/etc/environment)", {
  # Static OPENBLAS_NUM_THREADS or OMP_NUM_THREADS in /etc/environment conflict
  # with dynamic thread management in Rprofile. The setup script removes these.
  env_file <- "/etc/environment"
  if (!file.exists(env_file)) return("OK (no /etc/environment)")
  env_lines <- readLines(env_file, warn = FALSE)
  stale_vars <- c("OPENBLAS_NUM_THREADS", "OMP_NUM_THREADS", "MKL_NUM_THREADS")
  found <- c()
  for (v in stale_vars) {
    if (any(grepl(sprintf("^%s=", v), env_lines))) found <- c(found, v)
  }
  if (length(found) > 0) {
    stop(sprintf("Static thread vars found: %s — conflicts with dynamic Rprofile", paste(found, collapse = ", ")))
  }
  "Clean (no static thread vars)"
}, fix_hint = "Run: sudo sed -i '/^OPENBLAS_NUM_THREADS\\|^OMP_NUM_THREADS\\|^MKL_NUM_THREADS/d' /etc/environment")

run_audit("1.6", "OpenMP pkg-config", {
  # R packages (terra, sf, data.table) use pkg-config to find OpenMP at compile
  # time. Without openmp.pc, packages silently compile single-threaded.
  pc_check <- tryCatch(
    system2("pkg-config", args = c("--cflags", "openmp"), stdout = TRUE, stderr = FALSE),
    error = function(e) ""
  )
  if (length(pc_check) == 0 || !any(grepl("-fopenmp", pc_check))) {
    warning("OpenMP not found by pkg-config — R packages may compile single-threaded")
  } else {
    "Available (-fopenmp)"
  }
}, fix_hint = "Create /usr/local/lib/pkgconfig/openmp.pc (setup_nodes_v7.2.sh does this)")


# ==============================================================================
# [2.0] SERVICES
# ==============================================================================
audit_cat("\n[2.0] SERVICES\n")

run_audit("2.1", "Ollama Connection", {
  con <- tryCatch(
    socketConnection("127.0.0.1", conf$ollama_port, open = "r", timeout = 2),
    error = function(e) NULL
  )
  if (is.null(con)) stop("Unreachable on port 11434")
  close(con)
  "Online"
})

# FIX-3: Direct curl with -m timeout instead of ask_ai() + capture.output()
# Timeout 90s: qwen2.5-coder:14b cold-load from disk to RAM can take 30-60s
# on first call. Subsequent calls are fast (model stays loaded 15min).
run_audit("2.2", "AI Inference", {
  body <- sprintf('{"model":"%s","prompt":"Say OK","stream":false}', conf$ai_model)
  res <- system2("curl", args = c(
    "-s",              # silent
    "-m", "90",        # 90s hard timeout (curl-level, survives model cold-load)
    "--connect-timeout", "5",
    "-X", "POST",
    conf$ollama_api,
    "-d", shQuote(body)
  ), stdout = TRUE, stderr = FALSE)
  raw <- paste(res, collapse = "")
  if (nchar(raw) == 0) stop("Empty response (model loading? timeout?)")
  if (!grepl('"response"', raw)) stop("Invalid response format")
  if (grepl('"error"', raw)) stop("Ollama returned error")
  sprintf("Response OK (%s)", conf$ai_model)
}, timeout = 100, use_fork = FALSE)  # curl -m handles its own timeout

run_audit("2.3", "Ollama Security (Localhost Binding)", {
  # Verify Ollama only listens on 127.0.0.1, not 0.0.0.0
  ss_out <- tryCatch(
    system2("ss", args = c("-tlnp"), stdout = TRUE, stderr = FALSE),
    error = function(e) ""
  )
  ollama_lines <- grep(":11434", ss_out, value = TRUE)
  if (length(ollama_lines) == 0) stop("Ollama not listening on port 11434")
  if (any(grepl("0\\.0\\.0\\.0:11434|\\*:11434|\\[::\\]:11434", ollama_lines))) {
    stop("EXPOSED on 0.0.0.0 — data leaves VM! Fix: OLLAMA_HOST=127.0.0.1:11434")
  }
  "Localhost-only (127.0.0.1:11434)"
}, fix_hint = "Redeploy with setup_nodes_v7.2.sh or add OLLAMA_HOST=127.0.0.1:11434 to systemd override")

run_audit("2.4", "Ollama Model Readiness", {
  # Check that the configured model actually exists in ollama
  models_raw <- tryCatch(
    system2("curl", args = c("-s", "-m", "5", "http://127.0.0.1:11434/api/tags"),
      stdout = TRUE, stderr = FALSE),
    error = function(e) ""
  )
  models_str <- paste(models_raw, collapse = "")
  if (nchar(models_str) == 0) stop("Cannot list models (Ollama unreachable)")

  # Parse model names from JSON (safe: no jsonlite dependency required)
  model_names <- regmatches(models_str, gregexpr('"name"\\s*:\\s*"([^"]+)"', models_str))[[1]]
  model_names <- gsub('"name"\\s*:\\s*"', '', gsub('"$', '', model_names))

  has_configured <- any(grepl(conf$ai_model, model_names, fixed = TRUE))
  has_fallback   <- any(grepl("codellama", model_names, ignore.case = TRUE))
  has_rcoder     <- any(grepl("r-coder", model_names, ignore.case = TRUE))

  parts <- c()
  if (has_rcoder)     parts <- c(parts, "r-coder")
  if (has_configured && conf$ai_model != "r-coder") parts <- c(parts, conf$ai_model)
  if (has_fallback)   parts <- c(parts, "codellama")

  if (length(parts) == 0) {
    stop(sprintf("No models found (expected %s)", conf$ai_model))
  }
  if (!has_configured && !has_rcoder) {
    warning(sprintf("Configured model '%s' missing — using fallback", conf$ai_model))
  }
  sprintf("Available: %s", paste(unique(parts), collapse = ", "))
}, fix_hint = "Run: ollama pull qwen2.5-coder:14b-instruct-q8_0 && ollama create r-coder -f /etc/biome-calc/r-coder.modelfile")

run_audit("2.5", "Ollama Systemd Hardening", {
  # Verify the systemd override has key hardening settings.
  # These prevent Ollama from consuming all VM resources or exposing data.
  override <- "/etc/systemd/system/ollama.service.d/biome-hardening.conf"
  if (!file.exists(override)) {
    stop("No systemd hardening override found")
  }
  oconf <- readLines(override, warn = FALSE)
  oconf_str <- paste(oconf, collapse = "\n")

  checks <- c()
  issues <- c()

  # MemoryMax — caps RAM so Ollama doesn't starve R sessions
  if (any(grepl("MemoryMax=", oconf))) {
    mem <- sub(".*MemoryMax=([0-9]+[A-Z]).*", "\\1", oconf[grep("MemoryMax=", oconf)[1]])
    checks <- c(checks, sprintf("RAM=%s", mem))
  } else {
    issues <- c(issues, "No MemoryMax (Ollama could consume all RAM)")
  }

  # OLLAMA_HOST — must be localhost
  if (any(grepl("OLLAMA_HOST=127\\.0\\.0\\.1", oconf))) {
    checks <- c(checks, "localhost")
  } else {
    issues <- c(issues, "OLLAMA_HOST not set to 127.0.0.1")
  }

  # OLLAMA_KEEP_ALIVE — idle unload to free RAM
  if (any(grepl("OLLAMA_KEEP_ALIVE=", oconf))) {
    checks <- c(checks, "idle-unload")
  }

  # OLLAMA_MAX_LOADED_MODELS — prevent multiple large models eating RAM
  if (any(grepl("OLLAMA_MAX_LOADED_MODELS=", oconf))) {
    checks <- c(checks, "single-model")
  }

  if (length(issues) > 0) {
    stop(paste(issues, collapse = "; "))
  }
  paste(checks, collapse = ", ")
}, fix_hint = "Redeploy with setup_nodes_v7.2.sh (creates /etc/systemd/system/ollama.service.d/biome-hardening.conf)")

# ==============================================================================
# [3.0] COMPUTATIONAL STRESS (SAFE MODE)
# ==============================================================================
audit_cat("\n[3.0] COMPUTATIONAL STRESS\n")

# use_fork=TRUE: if BLAS livelocks, the forked child gets killed
run_audit("3.1", "BLAS Warmup (100x100)", {
  A <- matrix(runif(100 * 100), 100, 100)
  B <- A %*% A
  "OK"
}, timeout = 15, use_fork = TRUE,
   fix_hint = "BLAS livelock: set cpu:host in Proxmox or OPENBLAS_CORETYPE=SANDYBRIDGE")

run_audit("3.2", "Matrix Mult Stress (2000x2000)", {
  N <- 2000
  A <- matrix(runif(N * N), N, N)
  t0 <- Sys.time()
  C <- A %*% A
  dt <- as.numeric(difftime(Sys.time(), t0, units = "secs"))
  sprintf("Done in %.2fs", dt)
}, timeout = 60, use_fork = TRUE,
   fix_hint = "BLAS livelock or slow: check OPENBLAS_CORETYPE and cpu type")

run_audit("3.3", "Keras CPU Backend", {
  if (requireNamespace("keras", quietly = TRUE)) {
    tryCatch({
      tensorflow::tf$constant("Hello")
      "Active (OneDNN)"
    }, error = function(e) stop(e$message))
  } else "Skipped (not installed)"
}, use_fork = TRUE, timeout = 30)

# ==============================================================================
# [4.0] SYSTEM HEALTH
# ==============================================================================
audit_cat("\n[4.0] SYSTEM HEALTH\n")

run_audit("4.1", "/tmp Usage", {
  df_line <- system("df -h /tmp | tail -1", intern = TRUE)
  parts <- strsplit(trimws(df_line), "\\s+")[[1]]
  usage <- parts[5]  # e.g. "3%"
  pct <- as.numeric(sub("%", "", usage))
  if (pct > 80) stop(sprintf("Critical: /tmp at %s", usage))
  if (pct > 60) warning(sprintf("/tmp at %s — consider cleanup", usage))
  sprintf("OK (%s used, tmpfs)", usage)
}, fix_hint = "Clean stale Rtmp* dirs in /tmp")

run_audit("4.2", "NFS Mount (/nfs/home)", {
  mounts <- system("mount | grep '/nfs/home'", intern = TRUE)
  if (length(mounts) == 0) stop("Not mounted")
  if (grepl("nfs4", mounts[1])) {
    # Quick I/O test
    tf <- file.path("/nfs/home", Sys.info()[["user"]], ".biome_nfs_test")
    tryCatch({
      writeLines("test", tf)
      file.remove(tf)
      "Mounted (nfs4, I/O OK)"
    }, error = function(e) {
      sprintf("Mounted but I/O failed: %s", e$message)
    })
  } else "Mounted (non-nfs4)"
}, fix_hint = "Check NFS server biome-store03 and network")

run_audit("4.3", "Swap Configuration", {
  si <- system("swapon --show --noheadings --bytes 2>/dev/null", intern = TRUE)
  if (length(si) == 0) stop("No swap active")
  sprintf("Active (%d devices)", length(si))
})

run_audit("4.4", "Disk I/O Scheduler", {
  scheds <- list.files("/sys/block", full.names = TRUE)
  scheds <- scheds[!grepl("loop|ram|dm-", scheds)]
  results <- vapply(scheds, function(d) {
    sf <- file.path(d, "queue", "scheduler")
    if (file.exists(sf)) {
      s <- readLines(sf, n = 1, warn = FALSE)
      # Extract active scheduler from [brackets]
      m <- regmatches(s, regexpr("\\[\\w+\\]", s))
      if (length(m) > 0) gsub("[\\[\\]]", "", m) else "unknown"
    } else "none"
  }, character(1))
  paste(paste0(basename(names(results)), "=", results), collapse = ", ")
})

run_audit("4.5", "System Log Permissions", {
  slog <- "/var/log/r_biome_system.log"
  if (!file.exists(slog)) stop("Missing: /var/log/r_biome_system.log")
  if (file.access(slog, 2) != 0) stop("Not writable (run: chmod 666 /var/log/r_biome_system.log)")
  # Test actual write
  tryCatch({
    cat(sprintf("[%s] [AUDIT] Permission test OK\n", format(Sys.time())), file = slog, append = TRUE)
    "Writable"
  }, error = function(e) stop(sprintf("Write failed: %s", e$message)))
}, fix_hint = "Run: sudo chmod 666 /var/log/r_biome_system.log (or redeploy with setup_nodes_v7.2.sh)")

run_audit("4.6", "NUMA Topology", {
  numa_raw <- tryCatch(
    system2("lscpu", stdout = TRUE, stderr = FALSE), error = function(e) "")
  numa_line <- grep("NUMA node\\(s\\)", numa_raw, value = TRUE)
  if (length(numa_line) == 0) return("Unknown (lscpu unavailable)")
  numa_count <- as.integer(trimws(sub(".*:\\s*", "", numa_line[1])))
  sockets <- grep("Socket\\(s\\)", numa_raw, value = TRUE)
  socket_count <- if (length(sockets) > 0) as.integer(trimws(sub(".*:\\s*", "", sockets[1]))) else 1L
  if (socket_count > 1 && numa_count <= 1) {
    warning(sprintf("Multi-socket (%d) but NUMA not exposed (enable NUMA in Proxmox VM config)", socket_count))
  }
  sprintf("%d node(s), %d socket(s)", numa_count, socket_count)
}, fix_hint = "In Proxmox: VM → Hardware → Processor → Enable NUMA")

# ==============================================================================
# [5.0] SUMMARY
# ==============================================================================
audit_cat("\n")
fails <- which(vapply(audit_log, function(x) x$s == "FAIL", logical(1)))
warns <- which(vapply(audit_log, function(x) x$s == "WARN", logical(1)))

if (length(fails) == 0 && length(warns) == 0) {
  audit_cat(paste0(.AG, "  \u2705 AUDIT COMPLETE - ALL CHECKS PASSED (", length(audit_log), " tests)", .A0, "\n"))
} else if (length(fails) == 0 && length(warns) > 0) {
  audit_cat(paste0(.AG, "  \u2705 AUDIT COMPLETE - PASSED", .A0,
    paste0(.AY, " (", length(warns), " advisory warning(s))", .A0), "\n"))
  for (wid in names(audit_log)[warns]) {
    entry <- audit_log[[wid]]
    audit_cat(sprintf("    %s[%s]%s %s\n", .AY, wid, .A0, entry$m))
    audit_cat(sprintf("         HINT: %s\n", entry$fix))
  }
} else {
  audit_cat(paste0(.AR, "  \u274c AUDIT COMPLETE - ", length(fails), " FAILURE(S)", .A0))
  if (length(warns) > 0) audit_cat(paste0(.AY, ", ", length(warns), " WARNING(S)", .A0))
  audit_cat("\n")
  for (fid in names(audit_log)[fails]) {
    entry <- audit_log[[fid]]
    audit_cat(sprintf("    %s[%s]%s %s\n", .AR, fid, .A0, entry$m))
    audit_cat(sprintf("         FIX: %s\n", entry$fix))
  }
  for (wid in names(audit_log)[warns]) {
    entry <- audit_log[[wid]]
    audit_cat(sprintf("    %s[%s]%s %s\n", .AY, wid, .A0, entry$m))
    audit_cat(sprintf("         HINT: %s\n", entry$fix))
  }
}
audit_cat(sprintf("\nLog saved to: %s\n", LOG_FILE))