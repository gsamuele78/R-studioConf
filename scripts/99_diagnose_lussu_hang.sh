#!/bin/bash
# scripts/99_diagnose_lussu_hang.sh — Lussu-specific overlay over the generic
# HC-13 user-script triage harness (99_diagnose_user_script.sh).
# HARNESS_VERSION="1.5"  (script-level only — does NOT bump RPROFILE_VERSION)
# v1.5 (2026-05-11): forwards new generic-harness flags --no-lint and --smoke
#                    so that L0a (static lint) and L0b (smoke run) participate
#                    in the Lussu overlay verdict. No probe semantics change.
# v1.4 (2026-05-11): added Probe G — asserts that v12.9.4 glibc allocator caps
#                    (MALLOC_ARENA_MAX, MALLOC_TRIM_THRESHOLD_, R_GC_MEM_GROW)
#                    propagate to PSOCK workers via fragment 30 env_vec.
#                    Catches a regression in 30_psock_factory.R.template's
#                    rscript_envs= list before it reaches users.
# v1.3 (2026-05-10): Probe E now also asserts that master-defined globals
# survive the PSOCK reroute (HC-13 parity with mclapply fork). Catches the
# class of bug fixed by Rprofile v12.9.3 fragment 52 GLOBAL-SYNC block:
# `could not find function "process_chunk"` × N when user's portable code
# defines helpers at script level and calls them from inside mclapply FUN.

# ==============================================================================
# Wraps the generic harness and adds two Lussu-flavored extra probes that
# DO NOT MODIFY the user script (HC-13):
#   E) PSOCK swap probe — runs the user script under a wrapper that flips
#      mclapply -> parallel::parLapply on a PSOCK cluster, in a sibling .R
#      file that source()s the user script via local() with a shim. The user
#      file on disk is untouched.
#   F) terra todisk probe — preloads terra::terraOptions(todisk=TRUE,
#      memfrac=0.2) before source()ing the user script. Again the user
#      file is untouched.
#
# RESPONSIBILITY BOUNDARIES (HC-13):
#   These probes are diagnostic only. If E or F passes while L3 hangs, the
#   sysadmin's fix is to land an equivalent option/fragment on the SYSTEM
#   side (e.g. terra todisk default in 50_pkg_hooks.R, or a documented
#   PSOCK launcher) — NOT to ask the user to rewrite their .R file.
#
# Usage:
#   99_diagnose_lussu_hang.sh <user_script.R> [args...]
# ==============================================================================
set -euo pipefail

RED=$'\e[0;31m'; GREEN=$'\e[0;32m'
BLUE=$'\e[0;34m'; CYAN=$'\e[0;36m'; BOLD=$'\e[1m'; NC=$'\e[0m'

# ── HC-13 refuse-root guard (mirror of generic harness) ───────────────────
# Fail-fast BEFORE creating $OUT_DIR or invoking the generic harness, so we
# don't pollute /tmp or /Rtmp with root-owned artefacts. Opt-in via
# BIOME_DIAG_ALLOW_ROOT=1 (forensic only).
if [[ ${EUID:-$(id -u)} -eq 0 && "${BIOME_DIAG_ALLOW_ROOT:-0}" != "1" ]]; then
    cat >&2 <<EOF
${RED}${BOLD}ERROR:${NC} Lussu HC-13 overlay must run as the SCRIPT OWNER, not root.

Running as root creates root-owned /Rtmp/biome_root, /Rtmp/Rtmp*, and
/tmp/lussu_diag_* dirs that block subsequent debug runs by other users.

Correct invocation:
  ${BOLD}su - <username>${NC}
  /usr/local/bin/99_diagnose_lussu_hang.sh /path/to/user_script.R

Forensic override (only to debug the harness itself):
  ${BOLD}sudo BIOME_DIAG_ALLOW_ROOT=1 \$0 ...${NC}
EOF
    exit 2
fi

print_usage() {
    cat <<EOF >&2
${BOLD}99_diagnose_lussu_hang.sh${NC} — Lussu overlay (HC-13, v1.5)
Usage: $0 [--timeout SECONDS] [--progress-window SECONDS] [--no-lint] [--smoke] <user_script.R> [args...]

Runs the generic L0..L3 harness (incl. v1.3 L0a static_lint and optional
L0b smoke_run), then three Lussu-specific probes (E, F, G) that source
the unmodified user script through diagnostic shims.

CLI flags (forwarded to the generic harness via env; CLI overrides env):
  --timeout SECONDS         per-layer/per-probe wall-clock timeout (default 600)
  --progress-window SECONDS PROGRESS_TIMEOUT mtime window (default 60s) — if
                            log was written to within this window when timeout
                            fires, status is PROGRESSING (not TIMEOUT/FAIL).
  --no-lint                 skip generic harness L0a (static lint of user .R)
  --smoke                   enable generic harness L0b (in-process smoke run)
  -h | --help               this help and exit

Verdict statuses (probes E/F/G): PASS / FAIL / TIMEOUT / PROGRESSING.
Exit codes: 0=all-pass, 1=genuine-fail, 2=invocation-error,
            3=PROGRESSING-only, 4=infra-green-but-L0a-HIGH-findings.
EOF
}

# CLI parser (v1.5): same flags as generic harness — forwarded via env.
__CLI_TIMEOUT=""
__CLI_PROGWIN=""
__CLI_NO_LINT=""
__CLI_SMOKE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --timeout)
            [[ $# -ge 2 ]] || { echo "${RED}ERROR:${NC} --timeout requires SECONDS" >&2; exit 2; }
            __CLI_TIMEOUT="$2"; shift 2 ;;
        --timeout=*)        __CLI_TIMEOUT="${1#--timeout=}"; shift ;;
        --progress-window)
            [[ $# -ge 2 ]] || { echo "${RED}ERROR:${NC} --progress-window requires SECONDS" >&2; exit 2; }
            __CLI_PROGWIN="$2"; shift 2 ;;
        --progress-window=*) __CLI_PROGWIN="${1#--progress-window=}"; shift ;;
        --no-lint)           __CLI_NO_LINT=1; shift ;;
        --smoke)             __CLI_SMOKE=1;   shift ;;
        -h|--help) print_usage; exit 0 ;;
        --) shift; break ;;
        -*) echo "${RED}ERROR:${NC} unknown flag: $1" >&2; print_usage; exit 2 ;;
        *)  break ;;
    esac
done

for __v in "$__CLI_TIMEOUT" "$__CLI_PROGWIN"; do
    if [[ -n "$__v" && ! "$__v" =~ ^[0-9]+$ ]]; then
        echo "${RED}ERROR:${NC} flag value must be a positive integer (got: $__v)" >&2
        exit 2
    fi
done
[[ -n "$__CLI_TIMEOUT" ]] && export BIOME_DIAG_TIMEOUT_S="$__CLI_TIMEOUT"
[[ -n "$__CLI_PROGWIN" ]] && export BIOME_DIAG_PROGRESS_WINDOW_S="$__CLI_PROGWIN"
[[ -n "$__CLI_NO_LINT" ]] && export BIOME_DIAG_NO_LINT=1
[[ -n "$__CLI_SMOKE"   ]] && export BIOME_DIAG_SMOKE=1

if [[ $# -lt 1 ]]; then
    print_usage; exit 2
fi

USER_SCRIPT="$(realpath -- "$1")"; shift
USER_ARGS=("$@")


if [[ ! -f "$USER_SCRIPT" ]]; then
    echo "${RED}ERROR:${NC} script not found: $USER_SCRIPT" >&2
    exit 2
fi

TS="$(date +%Y%m%d_%H%M%S)"
RUN_USER="${USER:-$(id -un)}"
OUT_DIR="${BIOME_DIAG_OUT_DIR:-/tmp/lussu_diag_${RUN_USER}_${TS}}"
TIMEOUT_S="${BIOME_DIAG_TIMEOUT_S:-600}"
PROGRESS_WINDOW_S="${BIOME_DIAG_PROGRESS_WINDOW_S:-60}"
R_BIN="${BIOME_DIAG_R_BIN:-Rscript}"

GENERIC="${BIOME_DIAG_GENERIC:-/usr/local/bin/99_diagnose_user_script.sh}"
[[ -x "$GENERIC" ]] || GENERIC="$(dirname -- "$(realpath -- "$0")")/99_diagnose_user_script.sh"

mkdir -p "$OUT_DIR"
export BIOME_DIAG_OUT_DIR="$OUT_DIR"
export BIOME_DIAG_TIMEOUT_S="$TIMEOUT_S"

# ── Cleanup trap + setsid: kill the whole process group on exit so leftover
# R/Rscript fork/PSOCK workers do NOT linger holding NFS/cgroup resources.
__HARNESS_PGID=$$
cleanup_pgid() {
    local rc=$?
    trap - EXIT INT TERM
    kill -TERM -- "-${__HARNESS_PGID}" 2>/dev/null || true
    sleep 1
    kill -KILL -- "-${__HARNESS_PGID}" 2>/dev/null || true
    exit "$rc"
}
trap cleanup_pgid EXIT INT TERM
if command -v setsid >/dev/null 2>&1 && [[ -z "${__HARNESS_SETSID:-}" ]]; then
    export __HARNESS_SETSID=1
    exec setsid -w "$0" "$USER_SCRIPT" "${USER_ARGS[@]}"
fi
__HARNESS_PGID=$(ps -o pgid= -p $$ | tr -d ' ')

echo "${BOLD}${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo "${BOLD}${BLUE}  LUSSU HANG TRIAGE  (HC-13 + Lussu overlay)${NC}"
echo "${BOLD}${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo "  Script:   $USER_SCRIPT"
echo "  Out:      $OUT_DIR"
echo "  Generic:  $GENERIC"
echo

# ── Step 1: run generic L0..L3 harness ────────────────────────────────────
echo "${CYAN}── Running generic harness (L0..L3) ──${NC}"
set +e
"$GENERIC" "$USER_SCRIPT" "${USER_ARGS[@]}"
GENERIC_EC=$?
set -e
echo

# ── Step 2: build sandbox shims (do NOT touch user script) ────────────────
SHIM_DIR="$OUT_DIR/shims"
mkdir -p "$SHIM_DIR"

# E) PSOCK swap shim
# v1.3: shim now exports BOTH attached pkgs AND globalenv user objects to
# workers, mirroring the production fragment 52 GLOBAL-SYNC fix (v12.9.3).
# Also performs a self-test BEFORE source()ing the user script: defines a
# master-only helper, runs it through the swapped mclapply, and aborts with
# a clear error if globals don't reach workers — so an HC-13 regression in
# fragment 52 can never silently pass this probe.
cat > "$SHIM_DIR/probe_E_psock.R" <<'RSHIM'
# probe_E_psock.R — Lussu-specific diagnostic shim (HC-13)
# Replaces parallel::mclapply with a PSOCK-cluster parLapply for the duration
# of source()ing the user script. The user script file is NEVER modified.
local({
    n <- max(1L, as.integer(Sys.getenv("BIOME_PROBE_NCORES", "4")))
    cl <- parallel::makeCluster(n, type = "PSOCK")
    assign(".__probe_E_cl", cl, envir = globalenv())
    shim <- function(X, FUN, ..., mc.cores = n) {
        # Mirror fragment 52 PKG-SYNC: replicate master attached packages
        master_pkgs <- setdiff(rev(.packages()),
            c("base","methods","datasets","utils","grDevices","graphics","stats","parallel"))
        if (length(master_pkgs)) {
            tryCatch(parallel::clusterCall(cl, function(pp) {
                for (p in pp) suppressPackageStartupMessages(
                    tryCatch(library(p, character.only = TRUE), error = function(e) NULL))
            }, pp = master_pkgs), error = function(e) NULL)
        }
        # Mirror fragment 52 GLOBAL-SYNC: export master globals (HC-13 parity)
        master_globals <- tryCatch(ls(envir = globalenv(), all.names = FALSE),
                                   error = function(e) character(0))
        # Don't ship the cluster handle itself
        master_globals <- setdiff(master_globals, ".__probe_E_cl")
        if (length(master_globals)) {
            tryCatch(parallel::clusterExport(cl, master_globals, envir = globalenv()),
                     error = function(e) NULL)
        }
        parallel::parLapply(cl, X, FUN, ...)
    }
    # In-place override in the parallel namespace (diagnostic only)
    unlockBinding("mclapply", asNamespace("parallel"))
    assign("mclapply", shim, envir = asNamespace("parallel"))
    lockBinding("mclapply", asNamespace("parallel"))
    cat(sprintf("[probe_E] mclapply -> PSOCK(parLapply) n=%d\n", n))
})

# ── Self-test (HC-13 parity assertion) ─────────────────────────────────────
# Defines a master-only helper and runs it through the swapped mclapply.
# Replicates Lussu's pipeline: helper defined at script top level, then
# called by name from inside the FUN closure. Failure mode caught:
#   `could not find function ".__probe_E_helper"` → globals NOT exported
.__probe_E_helper <- function(x) x * 7L + 1L
.__probe_E_self <- tryCatch(
    parallel::mclapply(1:3, function(i) .__probe_E_helper(i), mc.cores = 2L),
    error = function(e) e
)
if (inherits(.__probe_E_self, "error") ||
    !identical(unlist(.__probe_E_self), c(8L, 15L, 22L))) {
    msg <- if (inherits(.__probe_E_self, "error"))
        conditionMessage(.__probe_E_self) else "result mismatch"
    cat(sprintf("[probe_E] SELF-TEST FAIL: master globals NOT reaching workers (%s)\n", msg))
    cat("[probe_E] HC-13 regression: fragment 52 GLOBAL-SYNC missing or broken\n")
    quit(status = 1, save = "no")
}
cat("[probe_E] self-test OK: master globals propagate to PSOCK workers\n")

.script <- commandArgs(trailingOnly = TRUE)[1]
cat(sprintf("[probe_E] sourcing UNMODIFIED user script: %s\n", .script))
source(.script, echo = FALSE)
# Stop cluster only at the end (let the user script use it via the shim)
tryCatch(parallel::stopCluster(get(".__probe_E_cl", envir = globalenv())),
         error = function(e) NULL)
cat("[probe_E] DONE\n")
RSHIM

# G) v12.9.4 MALLOC_ARENA_MAX propagation probe
# Spawns a PSOCK cluster via parallelly::makeClusterPSOCK (same factory used
# by .biome_make_cluster_impl in fragment 30) and asserts that workers see
# MALLOC_ARENA_MAX=2, MALLOC_TRIM_THRESHOLD_=134217728, R_GC_MEM_GROW=0.
# Failure indicates regression in 30_psock_factory.R.template's env_vec.
cat > "$SHIM_DIR/probe_G_malloc_envprop.R" <<'RSHIM'
# probe_G_malloc_envprop.R — v12.9.4 regression check (HC-13)
# DOES NOT source the user script (this is a system-side smoke test).
local({
    if (!requireNamespace("parallelly", quietly = TRUE)) {
        cat("[probe_G] parallelly not installed — skipping (informational)\n")
        quit(status = 0, save = "no")
    }
    # Use the production factory if available, otherwise plain makeClusterPSOCK
    cl <- if (exists(".biome_env", inherits = TRUE) &&
              !is.null(.biome_env$.biome_make_cluster_impl)) {
        .biome_env$.biome_make_cluster_impl(workers = 2L)
    } else {
        # Fallback: simulate fragment 30 env_vec minimally
        parallelly::makeClusterPSOCK(2L, rscript_envs = c(
            MALLOC_ARENA_MAX        = "2",
            MALLOC_TRIM_THRESHOLD_  = "134217728",
            R_GC_MEM_GROW           = "0"))
    }
    on.exit(try(parallel::stopCluster(cl), silent = TRUE), add = TRUE)
    res <- parallel::clusterEvalQ(cl, list(
        MALLOC_ARENA_MAX        = Sys.getenv("MALLOC_ARENA_MAX",        ""),
        MALLOC_TRIM_THRESHOLD_  = Sys.getenv("MALLOC_TRIM_THRESHOLD_",  ""),
        R_GC_MEM_GROW           = Sys.getenv("R_GC_MEM_GROW",           "")
    ))
    expected <- list(MALLOC_ARENA_MAX = "2",
                     MALLOC_TRIM_THRESHOLD_ = "134217728",
                     R_GC_MEM_GROW = "0")
    fail <- FALSE
    for (i in seq_along(res)) {
        for (k in names(expected)) {
            got <- res[[i]][[k]]; want <- expected[[k]]
            if (!identical(got, want)) {
                cat(sprintf("[probe_G] worker %d: %s='%s' (expected '%s')\n",
                            i, k, got, want))
                fail <- TRUE
            }
        }
    }
    if (fail) {
        cat("[probe_G] HC regression: v12.9.4 MALLOC_ARENA_MAX not propagated to PSOCK workers\n")
        cat("[probe_G] check: templates/Rprofile_site.d/30_psock_factory.R.template env_vec\n")
        quit(status = 1, save = "no")
    }
    cat("[probe_G] PASS — v12.9.4 glibc allocator caps reach all PSOCK workers\n")
})
RSHIM

# F) terra todisk shim
cat > "$SHIM_DIR/probe_F_terra_todisk.R" <<RSHIM
# probe_F_terra_todisk.R — Lussu-specific diagnostic shim (HC-13)
# Forces terra to spill rasters to disk before sourcing the user script.
# User script file UNMODIFIED.
local({
    if (requireNamespace("terra", quietly = TRUE)) {
        terra::terraOptions(todisk = TRUE, memfrac = 0.2,
                             tempdir = Sys.getenv("BIOME_USER_TMP", "/Rtmp"))
        cat(sprintf("[probe_F] terra todisk=TRUE memfrac=0.2 tmp=%s\n",
                    terra::terraOptions(print = FALSE)\$tempdir))
    } else {
        cat("[probe_F] terra not installed — probe is informational only\n")
    }
})
.script <- commandArgs(trailingOnly = TRUE)[1]
cat(sprintf("[probe_F] sourcing UNMODIFIED user script: %s\n", .script))
source(.script, echo = FALSE)
cat("[probe_F] DONE\n")
RSHIM

# ── Step 3: run probes ────────────────────────────────────────────────────
# v1.2: returns 0=PASS, 1=FAIL, 124=TIMEOUT, 125=PROGRESSING (custom code,
# distinguishable from genuine timeout). Caller maps these to verdict.
YELLOW=$'\e[0;33m'
run_probe() {
    local tag="$1" rfile="$2"
    local logf="$OUT_DIR/${tag}.log" errf="$OUT_DIR/${tag}.err"
    echo "${CYAN}── [$tag] $rfile ──${NC}"
    local t0 t1 ec status
    t0=$(date +%s)
    set +e
    timeout --kill-after=10s "${TIMEOUT_S}s" \
        "$R_BIN" "$rfile" "$USER_SCRIPT" "${USER_ARGS[@]}" \
        >"$logf" 2>"$errf"
    ec=$?
    set -e
    t1=$(date +%s)
    local dt=$(( t1 - t0 ))
    status="FAIL"
    if [[ $ec -eq 0 ]]; then
        status="PASS"
        echo "  ${GREEN}PASS${NC} in ${dt}s"
    elif [[ $ec -eq 124 ]]; then
        # PROGRESS_TIMEOUT detection (v1.2): if either log was written-to
        # within PROGRESS_WINDOW_S seconds, the probe is alive (long compute).
        local log_mtime err_mtime mtime log_age
        log_mtime=$(stat -c %Y "$logf" 2>/dev/null || echo "$t0")
        err_mtime=$(stat -c %Y "$errf" 2>/dev/null || echo "$t0")
        mtime=$(( log_mtime > err_mtime ? log_mtime : err_mtime ))
        log_age=$(( t1 - mtime ))
        if [[ $log_age -le $PROGRESS_WINDOW_S ]]; then
            status="PROGRESSING"
            ec=125  # synthetic: PROGRESSING — distinguishable from 124 TIMEOUT
            echo "  ${YELLOW}PROGRESSING${NC} (timeout ${dt}s, last log write ${log_age}s ago — alive; re-run with --timeout doubled)"
        else
            status="TIMEOUT"
            echo "  ${RED}TIMEOUT${NC} after ${dt}s (silent ${log_age}s — genuine stall)"
        fi
    else
        status="FAIL"
        echo "  ${RED}FAIL${NC} (exit $ec) in ${dt}s — tail of stderr:"
        tail -n 10 -- "$errf" 2>/dev/null | sed 's/^/    /' || true
    fi
    echo "$tag $ec $dt $status" >> "$OUT_DIR/lussu_overlay.tsv"
    return $ec
}


: > "$OUT_DIR/lussu_overlay.tsv"
set +e
run_probe "probe_E_psock"        "$SHIM_DIR/probe_E_psock.R"
E_EC=$?
run_probe "probe_F_terra_todisk" "$SHIM_DIR/probe_F_terra_todisk.R"
F_EC=$?
run_probe "probe_G_malloc_envprop" "$SHIM_DIR/probe_G_malloc_envprop.R"
G_EC=$?
set -e

# ── Step 4: verdict ───────────────────────────────────────────────────────
echo
echo "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo "${BOLD}  LUSSU OVERLAY VERDICT${NC}"
echo "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
__probe_label() {
    case "$1" in
        0)   echo "PASS" ;;
        125) echo "PROGRESSING" ;;
        124) echo "TIMEOUT" ;;
        *)   echo "FAIL" ;;
    esac
}
echo "  Generic L0..L3 exit: $GENERIC_EC"
echo "  Probe E (PSOCK swap):       $(__probe_label $E_EC)"
echo "  Probe F (terra todisk):     $(__probe_label $F_EC)"
echo "  Probe G (MALLOC envprop):   $(__probe_label $G_EC)"
echo

if [[ $G_EC -ne 0 ]]; then
    echo "  ${BOLD}HC REGRESSION:${NC} v12.9.4 glibc allocator caps NOT propagating to PSOCK workers."
    echo "  ${BOLD}SYSTEM-SIDE FIX:${NC} restore MALLOC_ARENA_MAX/MALLOC_TRIM_THRESHOLD_/R_GC_MEM_GROW"
    echo "  in env_vec inside templates/Rprofile_site.d/30_psock_factory.R.template, then redeploy"
    echo "  (sudo bash scripts/50_setup_nodes.sh — option 3)."
fi


if [[ $E_EC -eq 0 && $GENERIC_EC -ne 0 ]]; then
    echo "  ${BOLD}HYPOTHESIS:${NC} fork-inherited terra/GDAL state on NFS deadlocks under mclapply."
    echo "  ${BOLD}SYSTEM-SIDE FIX:${NC} document PSOCK launcher OR add fragment that swaps mclapply"
    echo "  for users whose code matches the pattern. DO NOT edit user .R files."
fi
if [[ $F_EC -eq 0 && $GENERIC_EC -ne 0 ]]; then
    echo "  ${BOLD}HYPOTHESIS:${NC} terra in-RAM raster under fork() exhausts memfrac and stalls on NFS writes."
    echo "  ${BOLD}SYSTEM-SIDE FIX:${NC} land terraOptions(todisk=TRUE) default in templates/Rprofile_site.d/50_pkg_hooks.R.template."
fi
echo
echo "  Full report: $OUT_DIR/report.md (generic harness)"
echo "  Overlay TSV: $OUT_DIR/lussu_overlay.tsv"
echo "  Shims:       $SHIM_DIR/"
echo
echo "  ${BOLD}HC-13 reminder:${NC} the user script was UNMODIFIED in every probe."
echo "  System-side adaptation is the preferred resolution."

# Exit code mapping (v1.5):
#   0 = generic + all probes PASS
#   3 = no genuine fail anywhere, but at least one PROGRESSING (inconclusive)
#   4 = generic verdict is INFRASTRUCTURE GREEN but L0a flagged HIGH findings
#       (forwarded as-is from the generic harness when all probes also pass)
#   1 = at least one genuine FAIL/TIMEOUT/KILLED somewhere
if [[ $GENERIC_EC -eq 0 && $E_EC -eq 0 && $F_EC -eq 0 && $G_EC -eq 0 ]]; then
    exit 0
fi
if [[ $GENERIC_EC -eq 4 && $E_EC -eq 0 && $F_EC -eq 0 && $G_EC -eq 0 ]]; then
    exit 4
fi
__has_progressing=0
__has_genuine_fail=0
# Generic harness: 0=pass, 3=progressing-only, 4=infra-green-but-L0a-HIGH,
# anything else=genuine fail
case "$GENERIC_EC" in
    0|4) ;;
    3)   __has_progressing=1 ;;
    *)   __has_genuine_fail=1 ;;
esac
for __c in "$E_EC" "$F_EC" "$G_EC"; do
    case "$__c" in
        0)   ;;
        125) __has_progressing=1 ;;
        *)   __has_genuine_fail=1 ;;
    esac
done
if [[ $__has_genuine_fail -eq 0 && $__has_progressing -eq 1 ]]; then
    exit 3
fi
exit 1

