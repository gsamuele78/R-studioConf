#!/bin/bash
# scripts/99_diagnose_lussu_hang.sh — Lussu-specific overlay over the generic
# HC-13 user-script triage harness (99_diagnose_user_script.sh).
# HARNESS_VERSION="1.2"  (script-level only — does NOT bump RPROFILE_VERSION)

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
${BOLD}99_diagnose_lussu_hang.sh${NC} — Lussu overlay (HC-13, v1.2)
Usage: $0 [--timeout SECONDS] [--progress-window SECONDS] <user_script.R> [args...]

Runs the generic L0..L3 harness, then two Lussu-specific probes (E, F)
that source the unmodified user script through diagnostic shims.

CLI flags (forwarded to the generic harness via env; CLI overrides env):
  --timeout SECONDS         per-layer/per-probe wall-clock timeout (default 600)
  --progress-window SECONDS PROGRESS_TIMEOUT mtime window (default 60s) — if
                            log was written to within this window when timeout
                            fires, status is PROGRESSING (not TIMEOUT/FAIL).
  -h | --help               this help and exit

Verdict statuses (probes E/F): PASS / FAIL / TIMEOUT / PROGRESSING.
Exit codes: 0=all-pass, 1=genuine-fail, 2=invocation-error, 3=PROGRESSING-only.
EOF
}

# CLI parser (v1.2): mirror of generic harness — same flags, same semantics.
__CLI_TIMEOUT=""
__CLI_PROGWIN=""
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
cat > "$SHIM_DIR/probe_E_psock.R" <<RSHIM
# probe_E_psock.R — Lussu-specific diagnostic shim (HC-13)
# Replaces parallel::mclapply with a PSOCK-cluster parLapply for the duration
# of source()ing the user script. The user script file is NEVER modified.
local({
    n <- max(1L, as.integer(Sys.getenv("BIOME_PROBE_NCORES", "4")))
    cl <- parallel::makeCluster(n, type = "PSOCK")
    on.exit(try(parallel::stopCluster(cl), silent = TRUE), add = TRUE)
    orig_mclapply <- parallel::mclapply
    shim <- function(X, FUN, ..., mc.cores = n) {
        parallel::clusterExport(cl, varlist = character(0), envir = .GlobalEnv)
        parallel::parLapply(cl, X, FUN, ...)
    }
    # In-place override in the parallel namespace (diagnostic only)
    unlockBinding("mclapply", asNamespace("parallel"))
    assign("mclapply", shim, envir = asNamespace("parallel"))
    lockBinding("mclapply", asNamespace("parallel"))
    cat(sprintf("[probe_E] mclapply -> PSOCK(parLapply) n=%d\n", n))
})
.script <- commandArgs(trailingOnly = TRUE)[1]
cat(sprintf("[probe_E] sourcing UNMODIFIED user script: %s\n", .script))
source(.script, echo = FALSE)
cat("[probe_E] DONE\n")
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
echo


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

# Exit code mapping (v1.2):
#   0 = generic + both probes PASS
#   3 = no genuine fail anywhere, but at least one PROGRESSING (inconclusive)
#   1 = at least one genuine FAIL/TIMEOUT/KILLED somewhere
if [[ $GENERIC_EC -eq 0 && $E_EC -eq 0 && $F_EC -eq 0 ]]; then
    exit 0
fi
__has_progressing=0
__has_genuine_fail=0
# Generic harness: 0=pass, 3=progressing-only, anything else=genuine fail
case "$GENERIC_EC" in
    0)   ;;
    3)   __has_progressing=1 ;;
    *)   __has_genuine_fail=1 ;;
esac
for __c in "$E_EC" "$F_EC"; do
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

