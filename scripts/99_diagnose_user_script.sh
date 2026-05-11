#!/bin/bash
# scripts/99_diagnose_user_script.sh — GENERIC HC-13 user-script triage harness
# HARNESS_VERSION="1.3"  (script-level only — does NOT bump RPROFILE_VERSION)
# ==============================================================================
# Implements the operator-perspective L0..L4 escalation ladder defined in
# .ai/agents.md §6.6 (HC-13) and docs/operations/USER_SCRIPT_TROUBLESHOOTING.md.
#
# RESPONSIBILITY BOUNDARIES (HC-13):
#   * This tool runs the USER'S R SCRIPT UNMODIFIED through 4 system layers.
#   * It DOES NOT edit, patch, rewrite, or transform the user's .R file.
#   * It tells the sysadmin which layer is responsible for the failure so the
#     fix can land on the SYSTEM side (Renviron / fragment / mount / cgroup)
#     whenever possible. Layer 5 (user-script or upstream bug) is the only
#     verdict that authorizes a conversation with the user about their code.
#
# Usage:
#   99_diagnose_user_script.sh <user_script.R> [arg1 arg2 ...]
#
# RUN AS THE AFFECTED USER (HC-13). Running as root pollutes /Rtmp with
# root-owned session/cache dirs that block subsequent debug runs by other
# users. The harness refuses to run as root unless BIOME_DIAG_ALLOW_ROOT=1
# is exported (forensic last-resort for debugging the harness itself, not
# user code).
#
# CLI flags (v1.3):
#   --timeout SECONDS         per-layer wall-clock timeout (overrides env)
#   --progress-window SECONDS PROGRESS_TIMEOUT detection window (default 60)
#   --no-lint                 skip the L0a static lint step
#   --smoke                   run the L0b in-process smoke (sets BIOME_DIAG_SMOKE=1)
#   -h | --help               this help and exit
#
# Optional env (CLI flags take precedence):
#   BIOME_DIAG_TIMEOUT_S          per-layer timeout in seconds (default 600 = 10 min)
#   BIOME_DIAG_PROGRESS_WINDOW_S  PROGRESS_TIMEOUT mtime window (default 60s)
#   BIOME_DIAG_OUT_DIR            output dir (default /tmp/user_diag_<USER>_<ts>)
#   BIOME_DIAG_R_BIN              Rscript binary (default: Rscript on PATH)
#   BIOME_DIAG_ALLOW_ROOT         set to 1 to bypass the run-as-user guard (forensic)
#   BIOME_DIAG_NO_LINT            set to 1 to disable L0a (static lint) — same as --no-lint
#   BIOME_DIAG_SMOKE              set to 1 to enable L0b (smoke run)    — same as --smoke
#   BIOME_DIAG_SMOKE_TIMEOUT_S    smoke wall-clock cap (default 300s)
#
# NEW LAYERS (v1.3, gated by L0_STATUS==PASS so infra is proven first):
#   L0a static_lint   scripts/lib/r_lint.R  — describes user-code smells (HC-13).
#                     HIGH/MED/LOW counts attached to report.md. R020 hardcoded
#                     credential triggers a SECURITY banner.
#   L0b smoke_run     scripts/lib/r_smoke.R — opt-in (BIOME_DIAG_SMOKE=1 / --smoke).
#                     Sources the user file UNMODIFIED with BIOME_SMOKE_* knobs
#                     and a 300s in-process timeout. Educational, not authoritative.
#
# OLD-VS-NEW APPENDIX (v1.3): a markdown section at the end of report.md reads
# /sys/fs/cgroup/<self>/{memory.max,cpu.max} and contrasts them against the
# legacy "16 vCPU / 512 GB / 2 TB no-cgroup" VM. This counters the recurring
# researcher excuse "sul vecchio server funzionava" with hard cgroup numbers.
#
# VERDICT STATUSES (v1.2):
#   PASS         layer ran to completion, exit 0.
#   FAIL         layer exited non-zero (real script error).
#   KILLED       layer SIGKILLed (137) — typically OOM-killer or cgroup MemoryMax.
#   TIMEOUT      layer hit wall-clock timeout AND log was silent in the last
#                PROGRESS_WINDOW seconds → genuine stall (deadlock/livelock).
#   PROGRESSING  layer hit wall-clock timeout BUT log was being written to in
#                the last PROGRESS_WINDOW seconds → script alive, just long
#                compute. Layer is NOT considered failing for verdict purposes;
#                operator should re-run with --timeout doubled or accept that
#                the legitimate workload exceeds the diagnostic window.
#                (HC-13: long compute is not a system bug — refusing to
#                 misclassify it as TIMEOUT==FAIL preserves operator trust.)
#
# Exit codes:
#   0 — all layers passed (script is healthy in production)
#   1 — at least one layer FAIL/KILLED/TIMEOUT (genuine stall); verdict in report.md
#   2 — invocation error (missing script, bad args, run-as-root refused)
#   3 — at least one layer PROGRESSING (inconclusive; re-run with longer --timeout)
# ==============================================================================
set -euo pipefail

# ── Color vars (PSE convention — HC-03) ───────────────────────────────────
RED=$'\e[0;31m'; YELLOW=$'\e[0;33m'; GREEN=$'\e[0;32m'
BLUE=$'\e[0;34m'; CYAN=$'\e[0;36m'; BOLD=$'\e[1m'; NC=$'\e[0m'

# ── HC-13 refuse-root guard ───────────────────────────────────────────────
# The harness must reproduce the affected user's runtime env (cgroup, NFS
# uid/gid, R_LIBS_USER, BIOME_USER_TMP). Running as root creates root-owned
# /Rtmp/biome_root, /Rtmp/Rtmp*, /tmp/user_diag_* that other users cannot
# read/clean. Refuse loudly; opt-in via BIOME_DIAG_ALLOW_ROOT=1.
if [[ ${EUID:-$(id -u)} -eq 0 && "${BIOME_DIAG_ALLOW_ROOT:-0}" != "1" ]]; then
    cat >&2 <<EOF
${RED}${BOLD}ERROR:${NC} HC-13 harness must run as the SCRIPT OWNER, not root.

The harness reproduces the user's runtime environment (cgroup user.slice,
R_LIBS_USER, BIOME_USER_TMP, NFS uid/gid). Running as root pollutes /Rtmp
with root-owned files that block subsequent debug runs by other users
(observed: /Rtmp/biome_root/, /Rtmp/Rtmp*, /tmp/user_diag_*).

Correct invocation (PAM session as the affected user):
  ${BOLD}su - <username>${NC}
  /usr/local/bin/99_diagnose_user_script.sh /path/to/user_script.R

Forensic override (only to debug the harness itself, NOT user code):
  ${BOLD}sudo BIOME_DIAG_ALLOW_ROOT=1 \$0 ...${NC}
EOF
    exit 2
fi

# ── Args ──────────────────────────────────────────────────────────────────
print_usage() {
    cat <<EOF >&2
${BOLD}99_diagnose_user_script.sh${NC} — HC-13 generic user-script triage harness (v1.3)
Usage: $0 [--timeout SECONDS] [--progress-window SECONDS] [--no-lint] [--smoke] <user_script.R> [args...]

Per HC-13 we run YOUR SCRIPT UNMODIFIED through 4 system layers and
tell you which layer is responsible. We do not edit your code.

CLI flags (override env):
  --timeout SECONDS         per-layer wall-clock timeout (default 600 = 10 min)
  --progress-window SECONDS PROGRESS_TIMEOUT mtime window (default 60s) — if
                            log was written to within this window when timeout
                            fires, status is PROGRESSING (not TIMEOUT/FAIL).
  --no-lint                 skip L0a (static lint of user .R file)
  --smoke                   enable L0b (in-process smoke run with BIOME_SMOKE_* knobs)
  -h | --help               this help and exit

Verdict statuses: PASS / FAIL / KILLED / TIMEOUT (silent stall) / PROGRESSING.
Exit codes: 0=all-pass, 1=genuine-fail, 2=invocation-error,
            3=PROGRESSING-only, 4=infra-green-but-L0a-HIGH-findings.
EOF
}

# CLI parser (v1.3): --timeout, --progress-window, --no-lint, --smoke,
# -h/--help, -- terminator. CLI overrides env.
__CLI_TIMEOUT=""
__CLI_PROGWIN=""
__CLI_NO_LINT=""
__CLI_SMOKE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --timeout)
            [[ $# -ge 2 ]] || { echo "${RED}ERROR:${NC} --timeout requires SECONDS" >&2; exit 2; }
            __CLI_TIMEOUT="$2"; shift 2 ;;
        --timeout=*)
            __CLI_TIMEOUT="${1#--timeout=}"; shift ;;
        --progress-window)
            [[ $# -ge 2 ]] || { echo "${RED}ERROR:${NC} --progress-window requires SECONDS" >&2; exit 2; }
            __CLI_PROGWIN="$2"; shift 2 ;;
        --progress-window=*)
            __CLI_PROGWIN="${1#--progress-window=}"; shift ;;
        --no-lint)
            __CLI_NO_LINT=1; shift ;;
        --smoke)
            __CLI_SMOKE=1; shift ;;
        -h|--help)
            print_usage; exit 0 ;;
        --) shift; break ;;
        -*) echo "${RED}ERROR:${NC} unknown flag: $1" >&2; print_usage; exit 2 ;;
        *)  break ;;
    esac
done
[[ -n "$__CLI_NO_LINT" ]] && export BIOME_DIAG_NO_LINT=1
[[ -n "$__CLI_SMOKE"   ]] && export BIOME_DIAG_SMOKE=1

# Validate numerics if provided
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

USER_SCRIPT="$1"; shift
USER_ARGS=("$@")


if [[ ! -f "$USER_SCRIPT" ]]; then
    echo "${RED}ERROR:${NC} script not found: $USER_SCRIPT" >&2
    exit 2
fi
USER_SCRIPT="$(realpath -- "$USER_SCRIPT")"

TIMEOUT_S="${BIOME_DIAG_TIMEOUT_S:-600}"
PROGRESS_WINDOW_S="${BIOME_DIAG_PROGRESS_WINDOW_S:-60}"
TS="$(date +%Y%m%d_%H%M%S)"

RUN_USER="${USER:-$(id -un)}"
OUT_DIR="${BIOME_DIAG_OUT_DIR:-/tmp/user_diag_${RUN_USER}_${TS}}"
R_BIN="${BIOME_DIAG_R_BIN:-Rscript}"
R_MIN="/usr/local/bin/r_minimal_rscript"

mkdir -p "$OUT_DIR"
REPORT="$OUT_DIR/report.md"
SUMMARY="$OUT_DIR/summary.tsv"

# ── Cleanup trap: on any exit (incl. Ctrl-C/TERM) kill our process group
# so leftover R/Rscript workers (mclapply forks, PSOCK children) do NOT
# linger and hold NFS/cgroup resources after the harness terminates.
__HARNESS_PGID=$$
cleanup_pgid() {
    local rc=$?
    # Kill the whole process group (negative PID = pgid). Ignore errors —
    # most children will already be gone by the time we get here.
    trap - EXIT INT TERM
    kill -TERM -- "-${__HARNESS_PGID}" 2>/dev/null || true
    sleep 1
    kill -KILL -- "-${__HARNESS_PGID}" 2>/dev/null || true
    exit "$rc"
}
trap cleanup_pgid EXIT INT TERM
# Promote ourselves to a session leader so the negative-pgid kill above
# only targets *our* descendants, never the parent shell.
if command -v setsid >/dev/null 2>&1 && [[ -z "${__HARNESS_SETSID:-}" ]]; then
    export __HARNESS_SETSID=1
    exec setsid -w "$0" "$USER_SCRIPT" "${USER_ARGS[@]}"
fi
__HARNESS_PGID=$(ps -o pgid= -p $$ | tr -d ' ')

# ── Header ────────────────────────────────────────────────────────────────
echo "${BOLD}${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo "${BOLD}${BLUE}  BIOME-CALC USER-SCRIPT TRIAGE HARNESS  (HC-13)${NC}"
echo "${BOLD}${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo "  Script:  $USER_SCRIPT"
echo "  Args:    ${USER_ARGS[*]:-(none)}"
echo "  Out:     $OUT_DIR"
echo "  Timeout:        ${TIMEOUT_S}s per layer"
echo "  Progress window: ${PROGRESS_WINDOW_S}s (PROGRESSING vs TIMEOUT discriminator)"
echo


cat > "$REPORT" <<EOF
# User Script Triage Report — HC-13

| Field | Value |
|-------|-------|
| Script | \`$USER_SCRIPT\` |
| Args | \`${USER_ARGS[*]:-(none)}\` |
| Host | \`$(hostname)\` |
| Started | \`$(date '+%Y-%m-%d %H:%M:%S %Z')\` |
| Per-layer timeout | ${TIMEOUT_S}s |
| Progress window | ${PROGRESS_WINDOW_S}s |
| Harness version | 1.3 |
| Lint (L0a) | $( [[ "${BIOME_DIAG_NO_LINT:-0}" == "1" ]] && echo "disabled" || echo "enabled" ) |
| Smoke (L0b) | $( [[ "${BIOME_DIAG_SMOKE:-0}" == "1" ]] && echo "enabled" || echo "disabled (opt-in via --smoke)" ) |


---

## Responsibility Boundaries (HC-13)

> *We adapt system → profile → fragments → env so that portable user R code keeps working.
> We do not patch user scripts. When the system has been exhausted and the hang persists,
> the clean-VM baseline (L4) proves whether the residual issue is in the user's code or upstream.*

EOF

printf "layer\tname\tstatus\telapsed_s\texit_code\tlog\n" > "$SUMMARY"

# ── Helper: run one layer ─────────────────────────────────────────────────
run_layer() {
    local layer="$1"; shift
    local name="$1";  shift
    local logf="$OUT_DIR/${layer}_${name}.log"
    local errf="$OUT_DIR/${layer}_${name}.err"
    local t0 t1 ec status

    echo "${CYAN}── [$layer] $name ──${NC}"
    echo "  cmd: $*"
    echo "  log: $logf"

    t0=$(date +%s)
    set +e
    timeout --kill-after=10s "${TIMEOUT_S}s" "$@" >"$logf" 2>"$errf"
    ec=$?
    set -e
    t1=$(date +%s)
    local dt=$(( t1 - t0 ))

    case "$ec" in
        0)   status="PASS"  ; echo "  ${GREEN}PASS${NC}  in ${dt}s" ;;
        124)
            # PROGRESS_TIMEOUT detection (v1.2): on wall-clock timeout, check
            # whether the user script was still emitting output recently. If
            # the log file was written-to within PROGRESS_WINDOW_S seconds,
            # the script is alive (long compute, not a stall) and we mark
            # PROGRESSING — NOT TIMEOUT/FAIL. HC-13: long compute is not a
            # system bug; misclassifying it as failure poisons triage.
            local log_mtime log_age
            log_mtime=$(stat -c %Y "$logf" 2>/dev/null || echo "$t0")
            log_age=$(( t1 - log_mtime ))
            if [[ $log_age -le $PROGRESS_WINDOW_S ]]; then
                status="PROGRESSING"
                echo "  ${YELLOW}PROGRESSING${NC} (timeout ${dt}s, last log write ${log_age}s ago — script alive; re-run with --timeout doubled)"
            else
                status="TIMEOUT"
                echo "  ${RED}TIMEOUT${NC} after ${dt}s (silent ${log_age}s — genuine stall)"
            fi
            ;;
        137) status="KILLED"; echo "  ${RED}KILLED${NC} (137 = SIGKILL/OOM) after ${dt}s" ;;
        *)   status="FAIL"  ; echo "  ${RED}FAIL${NC} (exit $ec) in ${dt}s" ;;
    esac


    printf "%s\t%s\t%s\t%d\t%d\t%s\n" \
        "$layer" "$name" "$status" "$dt" "$ec" "$(basename -- "$logf")" >> "$SUMMARY"

    cat >> "$REPORT" <<EOF

### Layer ${layer} — ${name}: **${status}** (${dt}s, exit ${ec})

\`\`\`
$ $*
\`\`\`

- stdout: \`$(basename -- "$logf")\` ($(wc -l <"$logf") lines)
- stderr: \`$(basename -- "$errf")\` ($(wc -l <"$errf") lines)
EOF

    if [[ "$status" != "PASS" ]]; then
        # Attach last 30 lines of stderr to report for quick triage
        cat >> "$REPORT" <<EOF

<details><summary>Last 30 lines of stderr</summary>

\`\`\`
$(tail -n 30 -- "$errf" 2>/dev/null || true)
\`\`\`

</details>
EOF
    fi

    return 0  # never abort the harness — collect ALL layers for the report
}

# ── L0: OS / NFS / fork health under r_minimal (no user script yet) ───────
L0_STATUS=PASS
if [[ -x "$R_MIN" ]]; then
    run_layer "L0" "infra_health" "$R_MIN" -e \
'biome_diag(); cat("\n"); biome_nfs_check(); cat("\n"); biome_fork_probe(n=10)'
    L0_STATUS=$(awk -F'\t' '$1=="L0"{print $3; exit}' "$SUMMARY")
else
    echo "${YELLOW}WARN:${NC} $R_MIN not found — skipping L0 (deploy via 50_setup_nodes.sh)"
    cat >> "$REPORT" <<EOF

### Layer L0 — infra_health: **SKIPPED**

\`$R_MIN\` not deployed. Run \`scripts/50_setup_nodes.sh\` to install.
EOF
    L0_STATUS=SKIPPED
fi

# ── L0a: Static lint of the user .R file (HC-13: describes, never patches) ─
# Gated by L0_STATUS == PASS so we always vouch for infra first. If infra
# is red, blaming user code would be premature and corrosive to trust.
LINTER="$(dirname -- "$(realpath -- "$0")")/lib/r_lint.R"
L0A_STATUS=SKIPPED
L0A_HIGH=0; L0A_MED=0; L0A_LOW=0; L0A_R020=0
if [[ "${BIOME_DIAG_NO_LINT:-0}" == "1" ]]; then
    echo "${YELLOW}── [L0a] static_lint ── SKIPPED (--no-lint / BIOME_DIAG_NO_LINT=1)${NC}"
    cat >> "$REPORT" <<EOF

### Layer L0a — static_lint: **SKIPPED** (disabled by operator)
EOF
elif [[ "$L0_STATUS" != "PASS" ]]; then
    echo "${YELLOW}── [L0a] static_lint ── SKIPPED (L0=$L0_STATUS; fix infra first)${NC}"
    cat >> "$REPORT" <<EOF

### Layer L0a — static_lint: **SKIPPED**

Skipped because L0 infra_health is \`$L0_STATUS\`. Per HC-13 we do not
discuss user-code smells until the infrastructure is proven green —
otherwise the conversation degenerates into "sysadmin vs researcher
copy-paste". Fix L0 first, then re-run.
EOF
elif [[ ! -x "$LINTER" && ! -f "$LINTER" ]]; then
    echo "${YELLOW}── [L0a] static_lint ── SKIPPED (linter not found: $LINTER)${NC}"
    cat >> "$REPORT" <<EOF

### Layer L0a — static_lint: **SKIPPED**

Linter not found at \`$LINTER\`. Deploy via \`scripts/50_setup_nodes.sh\`.
EOF
else
    echo "${CYAN}── [L0a] static_lint ──${NC}"
    L0A_TSV="$OUT_DIR/L0a_lint.tsv"
    L0A_MD="$OUT_DIR/L0a_lint.md"
    set +e
    Rscript "$LINTER" "$USER_SCRIPT"        > "$L0A_TSV" 2>"$OUT_DIR/L0a_lint.err"
    L0A_EC=$?
    Rscript "$LINTER" --md "$USER_SCRIPT"   > "$L0A_MD"  2>>"$OUT_DIR/L0a_lint.err" || true
    set -e
    L0A_HIGH=$(awk -F'\t' '$2=="HIGH"' "$L0A_TSV" | wc -l)
    L0A_MED=$( awk -F'\t' '$2=="MED"'  "$L0A_TSV" | wc -l)
    L0A_LOW=$( awk -F'\t' '$2=="LOW"'  "$L0A_TSV" | wc -l)
    L0A_R020=$(awk -F'\t' '$1=="R020"' "$L0A_TSV" | wc -l)
    case "$L0A_EC" in
        0) L0A_STATUS=PASS ;;
        1) L0A_STATUS=MED  ;;
        2) L0A_STATUS=HIGH ;;
        *) L0A_STATUS=ERROR;;
    esac
    echo "  findings: HIGH=$L0A_HIGH MED=$L0A_MED LOW=$L0A_LOW   status=$L0A_STATUS"
    {
        echo
        echo "### Layer L0a — static_lint: **$L0A_STATUS** (HIGH=$L0A_HIGH MED=$L0A_MED LOW=$L0A_LOW)"
        echo
        if [[ $L0A_R020 -gt 0 ]]; then
            echo "> ⚠ **SECURITY:** ${L0A_R020} hardcoded credential(s) detected (rule R020)."
            echo "> Sysadmin **must** rotate the affected provider credentials and migrate"
            echo "> them to \`~/.Renviron\` (chmod 600). Treat this report as confidential."
            echo
        fi
        cat "$L0A_MD"
        echo
        echo "> HC-13: the linter only describes findings. The user .R file was NOT modified."
    } >> "$REPORT"
fi

# ── L0b: Smoke run (opt-in via --smoke / BIOME_DIAG_SMOKE=1) ──────────────
SMOKE="$(dirname -- "$(realpath -- "$0")")/lib/r_smoke.R"
L0B_STATUS=SKIPPED
if [[ "${BIOME_DIAG_SMOKE:-0}" != "1" ]]; then
    echo "${YELLOW}── [L0b] smoke_run ── SKIPPED (opt-in via --smoke)${NC}"
    cat >> "$REPORT" <<EOF

### Layer L0b — smoke_run: **SKIPPED** (opt-in, pass \`--smoke\` to enable)
EOF
elif [[ "$L0_STATUS" != "PASS" ]]; then
    echo "${YELLOW}── [L0b] smoke_run ── SKIPPED (L0=$L0_STATUS)${NC}"
    cat >> "$REPORT" <<EOF

### Layer L0b — smoke_run: **SKIPPED** (L0=$L0_STATUS, fix infra first)
EOF
elif [[ ! -f "$SMOKE" ]]; then
    echo "${YELLOW}── [L0b] smoke_run ── SKIPPED (runner missing: $SMOKE)${NC}"
    cat >> "$REPORT" <<EOF

### Layer L0b — smoke_run: **SKIPPED** (\`$SMOKE\` not deployed)
EOF
else
    run_layer "L0b" "smoke_run" \
        env BIOME_DIAG_SMOKE=1 \
            BIOME_DIAG_SMOKE_TIMEOUT_S="${BIOME_DIAG_SMOKE_TIMEOUT_S:-300}" \
        "$R_BIN" "$SMOKE" "$USER_SCRIPT" "${USER_ARGS[@]}"
    L0B_STATUS=$(awk -F'\t' '$1=="L0b"{print $3; exit}' "$SUMMARY")
fi

# ── L1: User script under PURE R (minimal profile) ────────────────────────
L1_STATUS=SKIPPED
if [[ -x "$R_MIN" ]]; then
    run_layer "L1" "pure_R_minimal" "$R_MIN" "$USER_SCRIPT" "${USER_ARGS[@]}"
    L1_STATUS=$(awk -F'\t' '$1=="L1"{print $3; exit}' "$SUMMARY")
fi

# ── L2: Selective fragment disable (only meaningful if L1 PASSED & L3 FAILS) ─
# Run with all fragments disabled — if THIS passes but L3 fails, the bug is
# inside one of the fragments; sysadmin then bisects manually with smaller
# BIOME_DISABLE_FRAGMENTS values. We pick the all-off run as the L2 probe
# because it's the most informative single run.
run_layer "L2" "all_fragments_off" \
    env BIOME_DISABLE_FRAGMENTS="20,30,35,40,45,50,55,60,70,80" \
    "$R_BIN" "$USER_SCRIPT" "${USER_ARGS[@]}"
L2_STATUS=$(awk -F'\t' '$1=="L2"{print $3; exit}' "$SUMMARY")

# ── L3: Full profile baseline (production reference) ──────────────────────
run_layer "L3" "full_profile" "$R_BIN" "$USER_SCRIPT" "${USER_ARGS[@]}"
L3_STATUS=$(awk -F'\t' '$1=="L3"{print $3; exit}' "$SUMMARY")

# ── Verdict ───────────────────────────────────────────────────────────────
echo
echo "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo "${BOLD}  VERDICT${NC}"
echo "${BOLD}═══════════════════════════════════════════════════════════════${NC}"

VERDICT_LINE=""
RECOMMENDED=""

# v1.2: PROGRESSING means the layer hit timeout while still emitting log
# output → script alive (long compute), not a system bug. Surface this
# *before* the failure tree because it changes the verdict semantics:
# we do NOT blame any layer, we tell the operator to extend --timeout.
__has_progressing=0
for __s in "$L0_STATUS" "$L1_STATUS" "$L2_STATUS" "$L3_STATUS"; do
    [[ "$__s" == "PROGRESSING" ]] && __has_progressing=1
done
__has_genuine_fail=0
for __s in "$L0_STATUS" "$L1_STATUS" "$L2_STATUS" "$L3_STATUS"; do
    [[ "$__s" == "FAIL" || "$__s" == "TIMEOUT" || "$__s" == "KILLED" ]] && __has_genuine_fail=1
done

if [[ "$L0_STATUS" == "FAIL" || "$L0_STATUS" == "TIMEOUT" || "$L0_STATUS" == "KILLED" ]]; then
    VERDICT_LINE="LAYER L0 FAILED: infra (NFS/fork/cgroup)"
    RECOMMENDED="Fix system infrastructure. Check biome_nfs_check() output; user script blameless."
elif [[ $__has_progressing -eq 1 && $__has_genuine_fail -eq 0 ]]; then
    VERDICT_LINE="INCONCLUSIVE: at least one layer was PROGRESSING when timeout fired (long compute, not a stall)"
    RECOMMENDED="Re-run with --timeout doubled (e.g. --timeout $((TIMEOUT_S*2))). Script is alive; no layer blamed. HC-13: long compute is not a system bug."
elif [[ "$L3_STATUS" == "PASS" && "$L1_STATUS" == "PASS" && "$L0A_STATUS" == "HIGH" ]]; then
    # v1.3: infra+production both green BUT static lint surfaced HIGH-severity
    # smells in the user .R file. Don't blame infra; tell the operator that
    # the system is doing its job and the user code has issues to address.
    VERDICT_LINE="INFRASTRUCTURE GREEN — user .R file has ${L0A_HIGH} HIGH-severity lint finding(s)"
    RECOMMENDED="Read 'Layer L0a — static_lint' in the report and docs/user_guides/PARALLEL_R_DOS_AND_DONTS.md. The system is not the bottleneck."
elif [[ "$L3_STATUS" == "PASS" && "$L1_STATUS" == "PASS" ]]; then

    VERDICT_LINE="ALL LAYERS PASSED: script is healthy in production"
    RECOMMENDED="If user reports a bug, ask for exact reproduction (inputs, args, env)."
elif [[ "$L3_STATUS" != "PASS" && "$L2_STATUS" == "PASS" ]]; then
    VERDICT_LINE="LAYER L3 FAILED but L2 (fragments-off) PASSED: a profile fragment is the cause"
    RECOMMENDED="Bisect manually: BIOME_DISABLE_FRAGMENTS=\"50\" → 45 → 40 → ... until pass. Patch the offending fragment."
elif [[ "$L3_STATUS" != "PASS" && "$L1_STATUS" == "PASS" ]]; then
    VERDICT_LINE="LAYER L3 FAILED, L1 PASSED, L2 FAILED: dispatcher itself or fragment-load contract"
    RECOMMENDED="Inspect dispatcher main local({}) in templates/Rprofile_site.R.template. The bug survives \"all fragments off\" → it's in the dispatcher core."
elif [[ "$L1_STATUS" != "PASS" && "$L3_STATUS" != "PASS" ]]; then
    VERDICT_LINE="LAYERS L1+L3 BOTH FAILED: NOT a profile issue → infra+terra+NFS or user-script bug"
    RECOMMENDED="Escalate to L4 (clean-VM baseline). See docs/operations/CLEAN_VM_BASELINE.md. If L4 also fails → L5 (user-script or upstream package bug)."
elif [[ "$L1_STATUS" == "PASS" && "$L3_STATUS" == "PASS" && "$L2_STATUS" != "PASS" ]]; then
    VERDICT_LINE="L2 FAILED but L1+L3 PASSED: spurious — investigate run-to-run variance"
    RECOMMENDED="Re-run with BIOME_DIAG_TIMEOUT_S doubled. Check for transient NFS contention."
else
    VERDICT_LINE="MIXED RESULT — see per-layer status in $REPORT"
    RECOMMENDED="Manual review."
fi

echo "  ${BOLD}${VERDICT_LINE}${NC}"
echo
echo "  Per-layer status:"
echo "    L0  infra_health     : $L0_STATUS"
echo "    L0a static_lint      : $L0A_STATUS  (HIGH=$L0A_HIGH MED=$L0A_MED LOW=$L0A_LOW)"
echo "    L0b smoke_run        : $L0B_STATUS"
echo "    L1  pure_R_minimal   : $L1_STATUS"
echo "    L2  all_fragments_off: $L2_STATUS"
echo "    L3  full_profile     : $L3_STATUS"
echo
echo "  Recommended next step:"
echo "    $RECOMMENDED"
echo
echo "  Full report: $REPORT"
echo "  Summary TSV: $SUMMARY"
echo

cat >> "$REPORT" <<EOF

---

## Verdict

**$VERDICT_LINE**

**Recommended next step:** $RECOMMENDED

| Layer | Name | Status |
|-------|------|--------|
| L0  | infra_health      | $L0_STATUS |
| L0a | static_lint       | $L0A_STATUS (HIGH=$L0A_HIGH MED=$L0A_MED LOW=$L0A_LOW) |
| L0b | smoke_run         | $L0B_STATUS |
| L1  | pure_R_minimal    | $L1_STATUS |
| L2  | all_fragments_off | $L2_STATUS |
| L3  | full_profile      | $L3_STATUS |

> **Per HC-13:** the user script was run UNMODIFIED in every layer above.
> If the verdict is L0..L3, the fix lands on the SYSTEM SIDE.
> Only an L4-clean-VM-passes-but-L3-fails outcome warrants a conversation
> with the user about their code, and only with kernel-stack evidence.
EOF

# ── old_vs_new appendix ───────────────────────────────────────────────────
# Read THIS process's cgroup memory.max and cpu.max and contrast with the
# legacy "16 vCPU / 512 GB / 2 TB no-cgroup" VM. Counters the recurring
# researcher excuse "sul vecchio server funzionava". HC-13: this section
# is INFORMATIONAL (no verdict change), it just gives the operator a
# concrete answer in the same report rather than off-channel.
__cg_self="$(awk -F: '$1=="0"{print $3}' /proc/self/cgroup 2>/dev/null || true)"
__cg_root="/sys/fs/cgroup${__cg_self}"
__mem_max="(unknown)"; __cpu_max="(unknown)"; __mem_cur="(unknown)"
[[ -r "$__cg_root/memory.max"      ]] && __mem_max="$(cat "$__cg_root/memory.max"      2>/dev/null || echo unknown)"
[[ -r "$__cg_root/memory.current"  ]] && __mem_cur="$(cat "$__cg_root/memory.current"  2>/dev/null || echo unknown)"
[[ -r "$__cg_root/cpu.max"         ]] && __cpu_max="$(cat "$__cg_root/cpu.max"         2>/dev/null || echo unknown)"

# Format mem.max in GiB if it is a plain integer
__mem_max_h="$__mem_max"
if [[ "$__mem_max" =~ ^[0-9]+$ ]]; then
    __mem_max_h="$(awk -v n="$__mem_max" 'BEGIN{printf "%.1f GiB",n/1024/1024/1024}')"
fi
__mem_cur_h="$__mem_cur"
if [[ "$__mem_cur" =~ ^[0-9]+$ ]]; then
    __mem_cur_h="$(awk -v n="$__mem_cur" 'BEGIN{printf "%.1f GiB",n/1024/1024/1024}')"
fi
# cpu.max is "<quota> <period>"; ratio = quota/period (-1 means unbounded)
__cpu_human="$__cpu_max"
if [[ "$__cpu_max" =~ ^[0-9-]+\ [0-9]+$ ]]; then
    __q="${__cpu_max% *}"; __p="${__cpu_max#* }"
    if [[ "$__q" == "max" || "$__q" == "-1" ]]; then
        __cpu_human="unbounded ($__cpu_max)"
    else
        __cpu_human="$(awk -v q="$__q" -v p="$__p" 'BEGIN{printf "%.2f vCPU equiv. (quota=%s period=%s)",q/p,q,p}')"
    fi
fi

cat >> "$REPORT" <<EOF

---

## Appendix — old_vs_new (cgroup reality check)

| Resource | Legacy "old server" (no cgroup) | This biome-calc node (your slice) |
|---|---|---|
| Memory limit (\`memory.max\`) | 512 GiB (host total, no enforcement) | **${__mem_max_h}** |
| Memory in use (\`memory.current\`) | n/a | ${__mem_cur_h} |
| CPU quota (\`cpu.max\`) | 16 vCPU (host total, no enforcement) | **${__cpu_human}** |
| Per-user temp | 2 TB shared root \`/tmp\` | \`/Rtmp\` (400 GiB ext4, per-user dir) |
| OOM behaviour | host OOM-killer (kills any process) | cgroup MemoryMax → SIGKILL **only your tree** |

> **Why this matters:** the old VM had **no per-user limits** and a 2 TB \`/tmp\`,
> so a script that allocates 100 GiB or writes 500 GB of intermediates
> "just worked" — at the cost of starving every other user when contention
> hit. The biome-calc nodes enforce per-user cgroup slices: you get a
> deterministic share, and the system **kills you cleanly** instead of
> letting you DoS the cluster. If your script worked on the old server but
> SIGKILLs here, the script needs to fit the slice — that is **not** a
> system regression.
>
> Cgroup path read: \`${__cg_root}\`
EOF

# Exit code mapping (v1.3):
#   0 = ALL LAYERS PASSED (and no L0a HIGH)
#   1 = at least one genuine FAIL/TIMEOUT/KILLED in L0..L3
#   3 = only PROGRESSING (no genuine fail) — inconclusive
#   4 = L0..L3 all PASS but L0a flagged HIGH-severity smells in user code
if [[ "$VERDICT_LINE" == "ALL LAYERS PASSED"* ]]; then
    exit 0
elif [[ "$VERDICT_LINE" == "INFRASTRUCTURE GREEN"* ]]; then
    exit 4
elif [[ $__has_genuine_fail -eq 0 && $__has_progressing -eq 1 ]]; then
    exit 3
else
    exit 1
fi

