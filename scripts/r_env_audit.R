#!/usr/bin/env Rscript
# =============================================================================
# r_env_audit.R — Pessimistic R environment audit
# -----------------------------------------------------------------------------
# Purpose : Full audit of R runtime, installed packages, BLAS backend,
#           CPU capabilities, memory limits, and critical env vars on
#           BIOME-CALC nodes (or any Linux R host: bare-metal, VM, container).
#
# Paradigm: Pessimistic System Engineering
#           - assume failure at every layer
#           - bound every external call (timeout + size limit)
#           - verify, don't trust (QEMU lies about CPU model name)
#           - no fork-children where /proc works (zero pgrep/awk/grep)
#           - fail-fast on P0 misconfiguration, warn on P1/P2
#           - machine-parseable output (JSON) + human report
#           - exit codes: 0=OK, 1=warnings, 2=errors, 3=internal
#
# Usage   : Rscript r_env_audit.R [--json=/path/out.json] [--quiet] [--strict]
#
# Author  : BIOME IT Infrastructure
# License : Internal use
# =============================================================================

suppressPackageStartupMessages({
  # Only base R and a deliberately minimal surface. jsonlite is optional.
  invisible(NULL)
})

# ---- Hard limits & constants ------------------------------------------------
AUDIT_VERSION     <- "1.0.0"
MAX_PROC_BYTES    <- 262144L   # 256 KiB per /proc file — refuse anything larger
MAX_EXEC_SECONDS  <- 8L        # bound for any single probe
SIZE_PROBE_RETRY  <- 2L        # retries for transient /proc reads
SEVERITY <- list(OK = 0L, WARN = 1L, ERROR = 2L, INTERNAL = 3L)

# ---- Global findings accumulator --------------------------------------------
.findings <- new.env(parent = emptyenv())
.findings$items <- list()

record <- function(id, severity, message, detail = NULL) {
  stopifnot(severity %in% names(SEVERITY))
  .findings$items[[length(.findings$items) + 1L]] <- list(
    id       = id,
    severity = severity,
    message  = message,
    detail   = detail
  )
  invisible(NULL)
}

# =============================================================================
# SECTION 1 — Bounded primitives (paranoid I/O)
# =============================================================================

# Read a file with a hard size cap and a hard timeout. Never throws; returns
# NULL on failure and records a finding so silent degradation is impossible.
safe_read_file <- function(path, what = "text", max_bytes = MAX_PROC_BYTES,
                           timeout_s = MAX_EXEC_SECONDS) {
  if (!file.exists(path)) return(NULL)

  info <- tryCatch(file.info(path), error = function(e) NULL)
  if (is.null(info) || is.na(info$size)) {
    record(paste0("io.stat.fail:", path), "WARN",
           sprintf("stat() failed on %s", path))
    return(NULL)
  }
  # /proc reports size=0 for most files — that's fine, only refuse real oversize.
  if (!is.na(info$size) && info$size > max_bytes) {
    record(paste0("io.oversize:", path), "WARN",
           sprintf("Refusing oversized file %s (%d bytes)", path, info$size))
    return(NULL)
  }

  setTimeLimit(elapsed = timeout_s, transient = TRUE)
  on.exit(setTimeLimit(elapsed = Inf, transient = FALSE), add = TRUE)

  out <- tryCatch({
    if (identical(what, "lines")) {
      readLines(path, warn = FALSE, n = -1L, encoding = "UTF-8")
    } else {
      paste(readLines(path, warn = FALSE, n = -1L, encoding = "UTF-8"),
            collapse = "\n")
    }
  }, error = function(e) {
    record(paste0("io.read.fail:", path), "WARN",
           sprintf("read failed: %s", conditionMessage(e)))
    NULL
  })
  out
}

# Run a system command with a hard timeout. Returns character(0) on failure.
# We AVOID this where /proc or R introspection suffices — every fork is a risk.
safe_system <- function(cmd, args = character(), timeout_s = MAX_EXEC_SECONDS) {
  setTimeLimit(elapsed = timeout_s, transient = TRUE)
  on.exit(setTimeLimit(elapsed = Inf, transient = FALSE), add = TRUE)
  tryCatch({
    out <- suppressWarnings(system2(cmd, args, stdout = TRUE, stderr = FALSE))
    if (is.null(out)) character(0) else out
  }, error = function(e) {
    record(paste0("exec.fail:", cmd), "WARN",
           sprintf("exec failed: %s", conditionMessage(e)))
    character(0)
  })
}

# Parse "key: value" blocks from /proc (one record per blank-line separator).
parse_proc_blocks <- function(lines) {
  if (is.null(lines) || length(lines) == 0L) return(list())
  idx <- cumsum(lines == "")
  split_groups <- split(lines[lines != ""], idx[lines != ""])
  lapply(unname(split_groups), function(block) {
    kv <- regmatches(block, regexec("^([^:]+):\\s*(.*)$", block))
    out <- list()
    for (m in kv) {
      if (length(m) == 3L) {
        key <- trimws(m[2])
        val <- trimws(m[3])
        out[[key]] <- val
      }
    }
    out
  })
}

# =============================================================================
# SECTION 2 — Hypervisor / container detection
# =============================================================================

detect_runtime_env <- function() {
  res <- list(
    is_container = FALSE,
    container_kind = NA_character_,
    is_vm = FALSE,
    hypervisor = NA_character_,
    dmi_sys_vendor = NA_character_,
    dmi_product_name = NA_character_
  )

  # cgroup v1 leaks (the docker/lxc/kubepods token in /proc/1/cgroup)
  cg <- safe_read_file("/proc/1/cgroup", what = "text")
  if (!is.null(cg)) {
    if (grepl("docker", cg, fixed = TRUE)) {
      res$is_container <- TRUE; res$container_kind <- "docker"
    } else if (grepl("lxc", cg, fixed = TRUE)) {
      res$is_container <- TRUE; res$container_kind <- "lxc"
    } else if (grepl("kubepods", cg, fixed = TRUE)) {
      res$is_container <- TRUE; res$container_kind <- "kubernetes"
    } else if (grepl("podman", cg, fixed = TRUE)) {
      res$is_container <- TRUE; res$container_kind <- "podman"
    }
  }
  # systemd-nspawn / unprivileged containers
  if (file.exists("/run/systemd/container")) {
    res$is_container <- TRUE
    res$container_kind <- trimws(
      safe_read_file("/run/systemd/container", "text") %||% "systemd-nspawn")
  }
  if (file.exists("/.dockerenv") && is.na(res$container_kind)) {
    res$is_container <- TRUE; res$container_kind <- "docker"
  }

  # DMI — works in most VMs, sometimes leaks inside containers too
  res$dmi_sys_vendor   <- trimws(safe_read_file(
    "/sys/class/dmi/id/sys_vendor",   "text") %||% NA_character_)
  res$dmi_product_name <- trimws(safe_read_file(
    "/sys/class/dmi/id/product_name", "text") %||% NA_character_)

  # The 'hypervisor' flag in /proc/cpuinfo is the most reliable VM tell.
  # (Set separately in detect_cpu() — mirrored here for early awareness.)
  cpuinfo <- safe_read_file("/proc/cpuinfo", "text")
  if (!is.null(cpuinfo) && grepl("\\bhypervisor\\b", cpuinfo)) {
    res$is_vm <- TRUE
    # Try to name it
    if (!is.na(res$dmi_sys_vendor)) {
      hv <- tolower(res$dmi_sys_vendor)
      res$hypervisor <- if (grepl("qemu",    hv)) "QEMU/KVM"
                   else if (grepl("vmware",  hv)) "VMware"
                   else if (grepl("xen",     hv)) "Xen"
                   else if (grepl("microsoft", hv)) "Hyper-V"
                   else res$dmi_sys_vendor
    }
  }
  res
}

`%||%` <- function(a, b) if (is.null(a) || length(a) == 0L || is.na(a[1])) b else a

# =============================================================================
# SECTION 3 — CPU detection (QEMU-aware: trust flags, not model name)
# =============================================================================

detect_cpu <- function() {
  lines <- safe_read_file("/proc/cpuinfo", "lines")
  if (is.null(lines)) {
    record("cpu.cpuinfo.missing", "ERROR", "/proc/cpuinfo unreadable")
    return(NULL)
  }

  blocks <- parse_proc_blocks(lines)
  if (length(blocks) == 0L) {
    record("cpu.cpuinfo.empty", "ERROR", "/proc/cpuinfo parsed empty")
    return(NULL)
  }

  # Logical CPUs are count of blocks. Physical cores require dedup on
  # (physical id, core id) when present; otherwise fall back to lscpu-free logic.
  logical_cpus <- length(blocks)

  phys_ids <- vapply(blocks, function(b) b[["physical id"]] %||% NA_character_,
                     character(1))
  core_ids <- vapply(blocks, function(b) b[["core id"]] %||% NA_character_,
                     character(1))
  phys_cores <- if (all(is.na(phys_ids)) || all(is.na(core_ids))) {
    NA_integer_
  } else {
    length(unique(paste(phys_ids, core_ids, sep = "::")))
  }

  # Vendor and flags — these are what we actually trust.
  vendor_id <- blocks[[1]][["vendor_id"]] %||% NA_character_
  model_name <- blocks[[1]][["model name"]] %||% NA_character_
  flags_str  <- blocks[[1]][["flags"]] %||% ""
  flags      <- if (nzchar(flags_str)) strsplit(flags_str, "\\s+")[[1]] else character(0)

  is_virtual   <- "hypervisor" %in% flags
  qemu_generic <- grepl("QEMU Virtual CPU", model_name, fixed = TRUE)

  # CPU capability feature set — what matters for BLAS/OMP decisions.
  feat <- list(
    sse2    = "sse2"    %in% flags,
    sse4_1  = "sse4_1"  %in% flags,
    sse4_2  = "sse4_2"  %in% flags,
    avx     = "avx"     %in% flags,
    avx2    = "avx2"    %in% flags,
    fma     = "fma"     %in% flags,
    avx512f = "avx512f" %in% flags,
    aes     = "aes"     %in% flags
  )

  # Map vendor+flags to a recommended OPENBLAS_CORETYPE. Conservative:
  # we prefer the LEAST-specific microarch that satisfies flags, to survive
  # vCPU downgrades and live-migration across heterogeneous hosts.
  rec_coretype <- if (is.na(vendor_id)) {
    NA_character_
  } else if (identical(vendor_id, "AuthenticAMD")) {
    # AMD on OpenBLAS: ZEN is the safe modern target when AVX2+FMA present.
    # Do NOT report HASWELL for AMD — that was the exact bug fixed in v9.5.
    if (feat$avx2 && feat$fma) "ZEN" else "BARCELONA"
  } else if (identical(vendor_id, "GenuineIntel")) {
    if (feat$avx512f)           "SKYLAKEX"
    else if (feat$avx2 && feat$fma) "HASWELL"
    else if (feat$avx)          "SANDYBRIDGE"
    else if (feat$sse4_2)       "NEHALEM"
    else                        "PRESCOTT"
  } else {
    NA_character_  # non-x86, or QEMU with unknown vendor
  }

  # Advisory
  if (qemu_generic) {
    record("cpu.model.qemu_generic", "WARN",
           "model name is 'QEMU Virtual CPU version 2.5+' — Proxmox CPU type likely default/kvm64. Consider host-passthrough if workload-compatible.")
  }
  if (is_virtual && is.na(rec_coretype)) {
    record("cpu.coretype.unknown", "WARN",
           "Cannot infer a safe OPENBLAS_CORETYPE for this vCPU.")
  }

  list(
    vendor_id        = vendor_id,
    model_name       = model_name,
    logical_cpus     = logical_cpus,
    physical_cores   = phys_cores,
    is_virtual       = is_virtual,
    qemu_generic     = qemu_generic,
    features         = feat,
    recommended_coretype = rec_coretype,
    flags            = flags
  )
}

# =============================================================================
# SECTION 4 — Memory detection (cgroup v1 & v2 aware — report the MIN)
# =============================================================================

detect_memory <- function() {
  # /proc/meminfo — host view
  meminfo_lines <- safe_read_file("/proc/meminfo", "lines")
  host_total <- NA_real_
  host_avail <- NA_real_
  if (!is.null(meminfo_lines)) {
    kv <- regmatches(meminfo_lines,
                     regexec("^([A-Za-z_()]+):\\s+([0-9]+)\\s*kB", meminfo_lines))
    for (m in kv) {
      if (length(m) == 3L) {
        key <- m[2]; val <- as.numeric(m[3]) * 1024  # bytes
        if (identical(key, "MemTotal"))     host_total <- val
        if (identical(key, "MemAvailable")) host_avail <- val
      }
    }
  }

  # cgroup v2: /sys/fs/cgroup/memory.max (scalar: number or "max")
  # cgroup v1: /sys/fs/cgroup/memory/memory.limit_in_bytes
  cgroup_limit <- NA_real_
  cg_version   <- NA_character_

  v2 <- safe_read_file("/sys/fs/cgroup/memory.max", "text")
  if (!is.null(v2)) {
    v2 <- trimws(v2)
    cg_version <- "v2"
    if (!identical(v2, "max") && grepl("^[0-9]+$", v2)) {
      cgroup_limit <- as.numeric(v2)
    }
  } else {
    v1 <- safe_read_file("/sys/fs/cgroup/memory/memory.limit_in_bytes", "text")
    if (!is.null(v1)) {
      v1 <- trimws(v1)
      cg_version <- "v1"
      if (grepl("^[0-9]+$", v1)) {
        n <- as.numeric(v1)
        # cgroup v1 uses an absurdly large sentinel for "unlimited"
        if (n > 0 && n < 2^62) cgroup_limit <- n
      }
    }
  }

  # Effective bound = min(host, cgroup) — pessimism by construction
  effective <- if (!is.na(host_total) && !is.na(cgroup_limit)) {
    min(host_total, cgroup_limit)
  } else if (!is.na(cgroup_limit)) {
    cgroup_limit
  } else {
    host_total
  }

  # R's own process RSS (useful for confirming we're not already bloated)
  rss <- tryCatch({
    gc_info <- gc(reset = TRUE, full = TRUE)
    sum(gc_info[, "used"] * c(8, 8)) * 1024  # rough bytes
  }, error = function(e) NA_real_)

  if (is.na(effective)) {
    record("mem.detect.fail", "ERROR",
           "Could not determine any memory bound (host or cgroup).")
  } else if (effective < 2 * 1024^3) {
    record("mem.very_low", "WARN",
           sprintf("Effective memory bound is only %.2f GiB — R sessions will struggle.",
                   effective / 1024^3))
  }

  list(
    host_total_bytes    = host_total,
    host_available_bytes = host_avail,
    cgroup_version      = cg_version,
    cgroup_limit_bytes  = cgroup_limit,
    effective_bytes     = effective,
    r_process_rss_bytes = rss
  )
}

# =============================================================================
# SECTION 5 — BLAS / LAPACK backend introspection
# =============================================================================

detect_blas <- function(cpu) {
  ext <- tryCatch(extSoftVersion(), error = function(e) character(0))
  si  <- tryCatch(sessionInfo(),    error = function(e) NULL)

  blas_path   <- if (!is.null(si$BLAS))   si$BLAS   else NA_character_
  lapack_path <- if (!is.null(si$LAPACK)) si$LAPACK else NA_character_

  # Resolve symlink chain — we want to know the ACTUAL .so, not the alias
  resolve <- function(p) {
    if (is.na(p) || !nzchar(p)) return(NA_character_)
    tryCatch(Sys.readlink(p), error = function(e) NA_character_) -> lnk
    if (is.na(lnk) || !nzchar(lnk)) p else normalizePath(lnk, mustWork = FALSE)
  }
  blas_real   <- resolve(blas_path)
  lapack_real <- resolve(lapack_path)

  # Best-effort backend naming from the path
  name_backend <- function(p) {
    if (is.na(p)) return(NA_character_)
    lp <- tolower(p)
    if (grepl("openblas", lp)) "OpenBLAS"
    else if (grepl("libmkl", lp)) "Intel MKL"
    else if (grepl("libblas\\.so\\.3\\.(10\\.|9\\.|8\\.)", lp)) "Reference BLAS"
    else if (grepl("atlas", lp)) "ATLAS"
    else if (grepl("blis", lp)) "BLIS"
    else NA_character_
  }
  blas_backend <- name_backend(blas_real %||% blas_path)

  # Thread counts — try RhpcBLASctl if available, else env vars.
  threads <- list(openblas = NA_integer_, omp = NA_integer_, mkl = NA_integer_)
  if (requireNamespace("RhpcBLASctl", quietly = TRUE)) {
    threads$openblas <- tryCatch(
      RhpcBLASctl::blas_get_num_procs(), error = function(e) NA_integer_)
    threads$omp <- tryCatch(
      RhpcBLASctl::omp_get_max_threads(), error = function(e) NA_integer_)
  }

  env <- list(
    OPENBLAS_NUM_THREADS = Sys.getenv("OPENBLAS_NUM_THREADS", NA),
    OMP_NUM_THREADS      = Sys.getenv("OMP_NUM_THREADS",      NA),
    MKL_NUM_THREADS      = Sys.getenv("MKL_NUM_THREADS",      NA),
    OPENBLAS_CORETYPE    = Sys.getenv("OPENBLAS_CORETYPE",    NA),
    GOTO_NUM_THREADS     = Sys.getenv("GOTO_NUM_THREADS",     NA),
    BLIS_NUM_THREADS     = Sys.getenv("BLIS_NUM_THREADS",     NA)
  )

  # ===== Validation: CORETYPE vs CPU vendor (the v9.5 class of bug) =====
  coretype <- env$OPENBLAS_CORETYPE
  if (!is.na(coretype) && nzchar(coretype) &&
      !is.null(cpu) && !is.na(cpu$vendor_id)) {
    amd_safe   <- c("ZEN", "BARCELONA", "OPTERON", "STEAMROLLER", "EXCAVATOR",
                    "PILEDRIVER", "BULLDOZER")
    intel_safe <- c("SKYLAKEX", "HASWELL", "SANDYBRIDGE", "NEHALEM", "PRESCOTT",
                    "CORE2", "ATOM", "COOPERLAKE", "SAPPHIRERAPIDS")
    if (identical(cpu$vendor_id, "AuthenticAMD") && coretype %in% intel_safe) {
      record("blas.coretype.vendor_mismatch", "ERROR",
             sprintf("OPENBLAS_CORETYPE=%s is an Intel target on an AMD CPU. This is the v9.5 bug class — switch to ZEN or unset.",
                     coretype))
    }
    if (identical(cpu$vendor_id, "GenuineIntel") && coretype %in% amd_safe) {
      record("blas.coretype.vendor_mismatch", "ERROR",
             sprintf("OPENBLAS_CORETYPE=%s is an AMD target on an Intel CPU.",
                     coretype))
    }
  }

  # ===== Validation: thread oversubscription =====
  if (!is.null(cpu) && !is.na(cpu$logical_cpus)) {
    for (var in c("OPENBLAS_NUM_THREADS", "OMP_NUM_THREADS", "MKL_NUM_THREADS")) {
      val <- env[[var]]
      if (!is.na(val) && nzchar(val) && grepl("^[0-9]+$", val)) {
        if (as.integer(val) > cpu$logical_cpus) {
          record(paste0("blas.threads.oversubscribe:", var), "WARN",
                 sprintf("%s=%s exceeds logical CPUs=%d", var, val, cpu$logical_cpus))
        }
      }
    }
  }

  # Reference BLAS is usually a performance footgun for research workloads.
  if (identical(blas_backend, "Reference BLAS")) {
    record("blas.reference", "WARN",
           "R is linked against Reference BLAS — consider switching to OpenBLAS for BIOME numerical workloads.")
  }

  list(
    ext_versions = as.list(ext),
    blas_path     = blas_path,
    blas_realpath = blas_real,
    blas_backend  = blas_backend,
    lapack_path   = lapack_path,
    lapack_realpath = lapack_real,
    env_vars      = env,
    threads       = threads
  )
}

# =============================================================================
# SECTION 6 — Library paths & installed packages
# =============================================================================

audit_libpaths <- function() {
  lp <- .libPaths()

  per_path <- lapply(lp, function(p) {
    exists_   <- dir.exists(p)
    writable  <- if (exists_) file.access(p, mode = 2L) == 0L else FALSE
    pkgs_dir  <- if (exists_) list.dirs(p, recursive = FALSE, full.names = FALSE)
                 else character(0)

    # Detect broken packages: a dir without DESCRIPTION
    broken <- vapply(pkgs_dir, function(d) {
      desc <- file.path(p, d, "DESCRIPTION")
      !file.exists(desc)
    }, logical(1))

    list(
      path        = p,
      exists      = exists_,
      writable    = writable,
      package_count = length(pkgs_dir),
      broken_packages = as.character(pkgs_dir[broken])
    )
  })

  # Record findings for writable top-path (affects install.packages default)
  if (length(lp) >= 1L) {
    top <- per_path[[1]]
    if (!top$writable) {
      record("libpaths.top.readonly", "WARN",
             sprintf("Top libPath is not writable: %s — install.packages() will fail or fall back.",
                     top$path))
    }
    if (length(top$broken_packages) > 0L) {
      record("libpaths.top.broken", "ERROR",
             sprintf("Broken packages in %s: %s",
                     top$path, paste(top$broken_packages, collapse = ", ")))
    }
  }

  # Full inventory — guarded against a broken package killing installed.packages()
  inv <- tryCatch({
    ip <- installed.packages(fields = c("Package", "Version", "Priority",
                                        "LibPath", "Built"))
    as.data.frame(ip[, c("Package", "Version", "Priority", "LibPath", "Built"),
                    drop = FALSE], stringsAsFactors = FALSE)
  }, error = function(e) {
    record("pkgs.inventory.fail", "ERROR",
           sprintf("installed.packages() failed: %s", conditionMessage(e)))
    NULL
  })

  # Count by type
  summary <- if (is.null(inv)) NULL else list(
    total        = nrow(inv),
    base         = sum(!is.na(inv$Priority) & inv$Priority == "base"),
    recommended  = sum(!is.na(inv$Priority) & inv$Priority == "recommended"),
    user         = sum(is.na(inv$Priority))
  )

  list(
    libpaths = per_path,
    inventory_summary = summary,
    inventory = inv
  )
}

# =============================================================================
# SECTION 7 — R runtime & environment snapshot
# =============================================================================

detect_r_runtime <- function() {
  cap <- capabilities()
  # critical env vars for R behavior
  env_keys <- c("R_HOME", "R_LIBS_USER", "R_LIBS_SITE", "R_LIBS",
                "R_PROFILE", "R_PROFILE_USER", "R_ENVIRON", "R_ENVIRON_USER",
                "R_DEFAULT_PACKAGES", "TMPDIR", "LANG", "LC_ALL",
                "LD_LIBRARY_PATH", "LD_PRELOAD")
  env <- setNames(
    vapply(env_keys, function(k) Sys.getenv(k, unset = NA), character(1)),
    env_keys
  )

  # TMPDIR sanity — must be writable, and ideally not /tmp if /tmp is tmpfs-bounded
  tmp <- tempdir()
  if (!dir.exists(tmp) || file.access(tmp, 2L) != 0L) {
    record("r.tmpdir.bad", "ERROR",
           sprintf("R tempdir '%s' not writable.", tmp))
  }

  # Locale — UTF-8 matters for RStudio Server in AD environments
  loc <- Sys.getlocale("LC_CTYPE")
  if (!grepl("UTF-8", loc, ignore.case = TRUE)) {
    record("r.locale.non_utf8", "WARN",
           sprintf("LC_CTYPE is '%s' — non-UTF-8 locale breaks many BIOME packages (sf, terra).",
                   loc))
  }

  list(
    version      = R.version.string,
    platform     = R.version$platform,
    r_home       = R.home(),
    lib_paths    = .libPaths(),
    capabilities = as.list(cap),
    env          = as.list(env),
    tempdir      = tmp,
    locale_ctype = loc,
    options_snapshot = list(
      repos   = getOption("repos"),
      Ncpus   = getOption("Ncpus"),
      pkgType = getOption("pkgType"),
      timeout = getOption("timeout")
    )
  )
}

# =============================================================================
# SECTION 8 — Output
# =============================================================================

fmt_bytes <- function(b) {
  if (is.na(b) || is.null(b)) return("n/a")
  units <- c("B", "KiB", "MiB", "GiB", "TiB")
  i <- 1L
  while (b >= 1024 && i < length(units)) { b <- b / 1024; i <- i + 1L }
  sprintf("%.2f %s", b, units[i])
}

emit_human_report <- function(report) {
  sep <- strrep("=", 78)
  cat(sep, "\n")
  cat(sprintf("R Environment Audit — v%s — %s\n",
              AUDIT_VERSION, format(Sys.time(), "%Y-%m-%d %H:%M:%S %Z")))
  cat(sep, "\n\n")

  # -- Runtime --------------------------------------------------------------
  cat("[R Runtime]\n")
  cat(sprintf("  Version       : %s\n", report$r$version))
  cat(sprintf("  Platform      : %s\n", report$r$platform))
  cat(sprintf("  R_HOME        : %s\n", report$r$r_home))
  cat(sprintf("  tempdir       : %s\n", report$r$tempdir))
  cat(sprintf("  LC_CTYPE      : %s\n", report$r$locale_ctype))
  cat("  libPaths:\n")
  for (p in report$r$lib_paths) cat(sprintf("    - %s\n", p))
  cat("\n")

  # -- Runtime environment --------------------------------------------------
  cat("[Runtime Environment]\n")
  re <- report$runtime_env
  cat(sprintf("  Container     : %s (%s)\n",
              re$is_container, re$container_kind %||% "-"))
  cat(sprintf("  VM            : %s (%s)\n",
              re$is_vm, re$hypervisor %||% "-"))
  cat(sprintf("  DMI vendor    : %s / %s\n",
              re$dmi_sys_vendor %||% "-", re$dmi_product_name %||% "-"))
  cat("\n")

  # -- CPU ------------------------------------------------------------------
  cat("[CPU]\n")
  cp <- report$cpu
  if (is.null(cp)) {
    cat("  (unavailable)\n\n")
  } else {
    cat(sprintf("  vendor_id     : %s\n", cp$vendor_id %||% "-"))
    cat(sprintf("  model_name    : %s%s\n",
                cp$model_name %||% "-",
                if (isTRUE(cp$qemu_generic)) "  [QEMU generic — model name untrusted]" else ""))
    cat(sprintf("  logical CPUs  : %s\n", cp$logical_cpus))
    cat(sprintf("  physical cores: %s\n", cp$physical_cores %||% "-"))
    cat(sprintf("  is_virtual    : %s\n", cp$is_virtual))
    f <- cp$features
    cat(sprintf("  features      : SSE4.2=%s AVX=%s AVX2=%s FMA=%s AVX512F=%s\n",
                f$sse4_2, f$avx, f$avx2, f$fma, f$avx512f))
    cat(sprintf("  recommended OPENBLAS_CORETYPE: %s\n",
                cp$recommended_coretype %||% "-"))
  }
  cat("\n")

  # -- Memory ---------------------------------------------------------------
  cat("[Memory]\n")
  m <- report$memory
  cat(sprintf("  Host MemTotal : %s\n", fmt_bytes(m$host_total_bytes)))
  cat(sprintf("  Host MemAvail : %s\n", fmt_bytes(m$host_available_bytes)))
  cat(sprintf("  cgroup        : %s  limit=%s\n",
              m$cgroup_version %||% "-", fmt_bytes(m$cgroup_limit_bytes)))
  cat(sprintf("  EFFECTIVE     : %s  (min of host, cgroup)\n",
              fmt_bytes(m$effective_bytes)))
  cat("\n")

  # -- BLAS -----------------------------------------------------------------
  cat("[BLAS / LAPACK]\n")
  b <- report$blas
  cat(sprintf("  Backend       : %s\n", b$blas_backend %||% "(unknown)"))
  cat(sprintf("  BLAS path     : %s\n", b$blas_path %||% "-"))
  if (!is.na(b$blas_realpath) && !identical(b$blas_realpath, b$blas_path))
    cat(sprintf("  BLAS realpath : %s\n", b$blas_realpath))
  cat(sprintf("  LAPACK path   : %s\n", b$lapack_path %||% "-"))
  cat("  Env vars      :\n")
  for (k in names(b$env_vars)) {
    v <- b$env_vars[[k]]
    cat(sprintf("    %-24s= %s\n", k, if (is.na(v) || !nzchar(v)) "(unset)" else v))
  }
  cat(sprintf("  Threads       : openblas=%s omp=%s\n",
              b$threads$openblas %||% "?", b$threads$omp %||% "?"))
  cat("\n")

  # -- Packages -------------------------------------------------------------
  cat("[Packages]\n")
  s <- report$packages$inventory_summary
  if (is.null(s)) {
    cat("  (inventory unavailable)\n")
  } else {
    cat(sprintf("  total=%d  base=%d  recommended=%d  user=%d\n",
                s$total, s$base, s$recommended, s$user))
  }
  for (lp in report$packages$libpaths) {
    broken <- length(lp$broken_packages)
    flag <- if (!lp$writable) " [RO]" else ""
    cat(sprintf("  - %s%s  pkgs=%d  broken=%d\n",
                lp$path, flag, lp$package_count, broken))
    if (broken > 0L) {
      cat(sprintf("      broken: %s\n",
                  paste(lp$broken_packages, collapse = ", ")))
    }
  }
  cat("\n")

  # -- Findings -------------------------------------------------------------
  cat("[Findings]\n")
  if (length(report$findings) == 0L) {
    cat("  (none — system is clean by the checks this script performs)\n")
  } else {
    for (f in report$findings) {
      cat(sprintf("  [%-5s] %s: %s\n", f$severity, f$id, f$message))
    }
  }
  cat("\n")
  cat(sprintf("[Exit code] %d\n", report$exit_code))
  cat(sep, "\n")
}

emit_json <- function(report, path) {
  has_jsonlite <- requireNamespace("jsonlite", quietly = TRUE)
  if (has_jsonlite) {
    txt <- jsonlite::toJSON(report, auto_unbox = TRUE, null = "null",
                            na = "null", pretty = TRUE, force = TRUE)
    writeLines(txt, path)
  } else {
    # Finding already recorded in main() before the snapshot. Fall back to dput.
    writeLines(c("# jsonlite not available — falling back to dput()",
                 paste(deparse(report), collapse = "\n")), path)
  }
}

# =============================================================================
# SECTION 9 — Main
# =============================================================================

parse_args <- function(argv) {
  out <- list(json = NA_character_, quiet = FALSE, strict = FALSE)
  for (a in argv) {
    if (startsWith(a, "--json="))    out$json   <- substring(a, 8)
    else if (identical(a, "--quiet"))  out$quiet  <- TRUE
    else if (identical(a, "--strict")) out$strict <- TRUE
    else if (identical(a, "--help") || identical(a, "-h")) {
      cat("Usage: Rscript r_env_audit.R [--json=/path/out.json] [--quiet] [--strict]\n")
      quit(status = 0L, save = "no")
    }
  }
  out
}

main <- function() {
  argv <- commandArgs(trailingOnly = TRUE)
  opts <- parse_args(argv)

  # Early check: jsonlite matters only if we're asked to emit JSON.
  # Record the finding now so it shows up in both outputs and affects exit code.
  if (!is.na(opts$json) && nzchar(opts$json) &&
      !requireNamespace("jsonlite", quietly = TRUE)) {
    record("output.jsonlite.missing", "WARN",
           "jsonlite not installed — JSON export will degrade to dput(). Install jsonlite for a real JSON artifact.")
  }

  runtime_env <- tryCatch(detect_runtime_env(),
                          error = function(e) {
                            record("runtime_env.detect.fail", "INTERNAL",
                                   conditionMessage(e)); list() })
  cpu    <- tryCatch(detect_cpu(),
                     error = function(e) {
                       record("cpu.detect.fail", "INTERNAL",
                              conditionMessage(e)); NULL })
  mem    <- tryCatch(detect_memory(),
                     error = function(e) {
                       record("memory.detect.fail", "INTERNAL",
                              conditionMessage(e)); list() })
  blas   <- tryCatch(detect_blas(cpu),
                     error = function(e) {
                       record("blas.detect.fail", "INTERNAL",
                              conditionMessage(e)); list() })
  pkgs   <- tryCatch(audit_libpaths(),
                     error = function(e) {
                       record("pkgs.audit.fail", "INTERNAL",
                              conditionMessage(e)); list() })
  rr     <- tryCatch(detect_r_runtime(),
                     error = function(e) {
                       record("r.runtime.fail", "INTERNAL",
                              conditionMessage(e)); list() })

  findings <- .findings$items
  sev_values <- vapply(findings, function(f) SEVERITY[[f$severity]], integer(1))
  worst <- if (length(sev_values) == 0L) 0L else max(sev_values)

  # Strict mode: any WARN is treated as failure
  exit_code <- if (opts$strict && worst >= SEVERITY$WARN) {
    max(worst, SEVERITY$ERROR)
  } else {
    worst
  }

  report <- list(
    audit_version = AUDIT_VERSION,
    generated_at  = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z"),
    hostname      = Sys.info()[["nodename"]],
    r             = rr,
    runtime_env   = runtime_env,
    cpu           = cpu,
    memory        = mem,
    blas          = blas,
    packages      = pkgs,
    findings      = findings,
    exit_code     = exit_code
  )

  if (!opts$quiet) emit_human_report(report)
  if (!is.na(opts$json) && nzchar(opts$json)) emit_json(report, opts$json)

  quit(status = exit_code, save = "no")
}

# Guard: never let an internal failure leave the caller with exit 0
tryCatch(main(), error = function(e) {
  message(sprintf("[FATAL] Unhandled error: %s", conditionMessage(e)))
  quit(status = SEVERITY$INTERNAL, save = "no")
})
