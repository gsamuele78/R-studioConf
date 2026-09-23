#!/usr/bin/env bash
set -euo pipefail
# scripts/99_diagnose_user_script.sh — GENERIC HC-13 user-script triage harness
# HARNESS_VERSION="1.4"  (script-level only — does NOT bump RPROFILE_VERSION)
# ==============================================================================
# Implements the operator-perspective L0..L4 escalation ladder defined in
# .ai/agents.md §6.6 (HC-13) and docs/operations/USER_SCRIPT_TROUBLESHOOTING.md.
#
# RESPONSIBILITY BOUNDARIES (HC-13):
#   * After the L0 infra probe, this tool runs the USER'S R SCRIPT UNMODIFIED
#     through 4 system layers (L1, L2, L3s, L3).
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
#   BIOME_DIAG_R_MIN              minimal-profile Rscript (default /usr/local/bin/r_minimal_rscript)
#   BIOME_DIAG_FRAG_DIR           deployed fragment dir the L2 disable list is read from
#                                 (default /etc/R/Rprofile_site.d)
#
# LAYERS (v1.4 — user startup files are isolated, so they can be blamed):
#   L1   pure_R_minimal     minimal profile, NO ~/.Renviron / ~/.Rprofile
#   L2   all_fragments_off  dispatcher only: every DEPLOYED fragment prefix is
#                           disabled (list read from BIOME_DIAG_FRAG_DIR, not
#                           hardcoded), NO user startup files
#   L3s  system_profile     full system profile, NO user startup files
#   L3   full_profile       production: system profile + ~/.Renviron + ~/.Rprofile
#   "No user startup files" = R_ENVIRON_USER= (set but empty: neither ./.Renviron
#   nor ~/.Renviron is read) + --no-init-file (no ./.Rprofile, no ~/.Rprofile).
#   L1 only needs the environ half: r_minimal already replaces the user profile
#   with its own via R_PROFILE_USER. Before v1.4, L1-L3 all read ~/.Renviron
#   (and L2/L3 ~/.Rprofile), so a broken user profile was reported as
#   "dispatcher core" or "not a profile issue → L4/L5". L3s PASS + L3 FAIL now
#   names the user's startup files — a CONFIG-layer cause (HC-13 ordering),
#   repaired with scripts/99_check_rprofile_health.sh --user <u> [--fix |
#   --reset-profile] (repo checkout; dry-run unless --commit), never by editing
#   the .R script.
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
#   SKIPPED      (listed since v1.4) layer not run because its prerequisite is
#                missing: r_minimal not deployed (L0/L1), no fragment deployed
#                (L2), L0 not green (L0a/L0b). Never counted as PASS; an L3
#                failure that needs the skipped layer is reported unattributed.
#
# Exit codes (v1.4) — keyed on the PRODUCTION layer L3. L1/L2/L3s withhold
# configuration on purpose, so a script that needs it fails there legitimately;
# they attribute an L3 failure, they never fail a script that passes in L3.
#   0 — production layer L3 passed (other-layer anomalies are notes, not failures)
#   1 — L0 infra failed, or L3 failed (FAIL/KILLED/TIMEOUT); verdict in report.md
#   2 — invocation error (missing script, bad args, run-as-root refused)
#   3 — inconclusive: production layer L3 was PROGRESSING (re-run with longer --timeout)
#   4 — L3 passed but L0a flagged HIGH-severity lint findings in the user .R file
# ==============================================================================

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
  ${BOLD}su - USER_D${NC}
  /usr/local/bin/99_diagnose_user_script.sh /path/to/user_script.R

Forensic override (only to debug the harness itself, NOT user code):
  ${BOLD}sudo BIOME_DIAG_ALLOW_ROOT=1 \$0 ...${NC}
EOF
    exit 2
fi

# ── Args ──────────────────────────────────────────────────────────────────
print_usage() {
    cat <<EOF >&2
${BOLD}99_diagnose_user_script.sh${NC} — HC-13 generic user-script triage harness (v1.4)
Usage: $0 [--timeout SECONDS] [--progress-window SECONDS] [--no-lint] [--smoke] <user_script.R> [args...]

Per HC-13 we probe the infrastructure (L0), then run YOUR SCRIPT UNMODIFIED
through 4 system layers and tell you which one is responsible. We do not
edit your code.
  L1 minimal profile · L2 dispatcher, all fragments off · L3s full system
  profile · L3 production (system profile + your ~/.Renviron/~/.Rprofile).
  L1, L2 and L3s never read your startup files, so L3s PASS + L3 FAIL
  points at them (repair, from the R-studioConf checkout:
  scripts/99_check_rprofile_health.sh --user <you> --fix).

CLI flags (override env):
  --timeout SECONDS         per-layer wall-clock timeout (default 600 = 10 min)
  --progress-window SECONDS PROGRESS_TIMEOUT mtime window (default 60s) — if
                            log was written to within this window when timeout
                            fires, status is PROGRESSING (not TIMEOUT/FAIL).
  --no-lint                 skip L0a (static lint of user .R file)
  --smoke                   enable L0b (in-process smoke run with BIOME_SMOKE_* knobs)
  -h | --help               this help and exit

Verdict statuses: PASS / FAIL / KILLED / TIMEOUT (silent stall) / PROGRESSING / SKIPPED.
Exit codes: 0=production(L3)-pass, 1=genuine-fail, 2=invocation-error,
            3=inconclusive(PROGRESSING), 4=infra-green-but-L0a-HIGH-findings.
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
# Exported so the setsid re-exec below reuses the SAME directory (it used to
# recompute TS and leave an empty /tmp/user_diag_* behind).
export BIOME_DIAG_OUT_DIR="$OUT_DIR"
R_BIN="${BIOME_DIAG_R_BIN:-Rscript}"
R_MIN="${BIOME_DIAG_R_MIN:-/usr/local/bin/r_minimal_rscript}"
FRAG_DIR="${BIOME_DIAG_FRAG_DIR:-/etc/R/Rprofile_site.d}"

REPORT="$OUT_DIR/report.md"
SUMMARY="$OUT_DIR/summary.tsv"

# ── Cleanup trap: on any exit (incl. Ctrl-C/TERM) kill our process group
# so leftover R/Rscript workers (mclapply forks, PSOCK children) do NOT
# linger and hold NFS/cgroup resources after the harness terminates.
__HARNESS_PGID=$$
cleanup_pgid() {
    local rc=$?
    local -a __stragglers=()
    # Kill the whole process group (negative PID = pgid). Ignore errors —
    # most children will already be gone by the time we get here.
    # The harness is itself in that group: it must ignore its own TERM and be
    # left out of the KILL, else it dies 143/137 and the verdict exit code
    # never reaches the caller (v1.3 bug: every run exited 143).
    trap - EXIT INT
    trap '' TERM
    kill -TERM -- "-${__HARNESS_PGID}" 2>/dev/null || true
    sleep 1
    mapfile -t __stragglers < <(ps -e -o pid=,pgid= 2>/dev/null \
        | awk -v g="$__HARNESS_PGID" -v me="$$" '$2 == g && $1 != me {print $1}')
    if [[ ${#__stragglers[@]} -gt 0 ]]; then
        kill -KILL "${__stragglers[@]}" 2>/dev/null || true
    fi
    exit "$rc"
}
trap cleanup_pgid EXIT INT TERM
# Promote ourselves to a session leader so the negative-pgid kill above
# only targets *our* descendants, never the parent shell. Test the session,
# not an exported flag: a flag is inherited by nested harnesses (the Lussu
# overlay exported one), which then stayed in the caller's group and killed
# the caller on exit. A successful setsid makes us the leader → no re-exec loop.
if command -v setsid >/dev/null 2>&1 && [[ "$(ps -o sid= -p $$ | tr -d ' ')" != "$$" ]]; then
    exec setsid -w "$0" "$USER_SCRIPT" "${USER_ARGS[@]}"
fi
__HARNESS_PGID=$(ps -o pgid= -p $$ | tr -d ' ')
mkdir -p "$OUT_DIR"

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
| Harness version | 1.4 |
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

# ── L1: User script under PURE R (minimal profile, no user startup files) ──
# R_ENVIRON_USER set-but-empty is NOT a no-op: R then skips ./.Renviron and
# ~/.Renviron. r_minimal already swaps the user profile for its own.
L1_STATUS=SKIPPED
if [[ -x "$R_MIN" ]]; then
    run_layer "L1" "pure_R_minimal" \
        env R_ENVIRON_USER= "$R_MIN" "$USER_SCRIPT" "${USER_ARGS[@]}"
    L1_STATUS=$(awk -F'\t' '$1=="L1"{print $3; exit}' "$SUMMARY")
else
    echo "${YELLOW}── [L1] pure_R_minimal ── SKIPPED ($R_MIN not deployed)${NC}"
    cat >> "$REPORT" <<EOF

### Layer L1 — pure_R_minimal: **SKIPPED**

\`$R_MIN\` not deployed. Run \`scripts/50_setup_nodes.sh\` to install.
EOF
fi

# ── L2: dispatcher only — every DEPLOYED fragment off, no user startup files ─
# The disable list is built from what the dispatcher would load (^[0-9]{2}_.*\.R$),
# so a fragment added later can never stay ON here (the v1.3 hardcoded list
# silently kept 04/05/42/52 active). L3s FAIL + L2 PASS → bisect the list.
FRAG_PREFIXES=""
for __frag in "$FRAG_DIR"/[0-9][0-9]_*.R; do
    [[ -f "$__frag" ]] || continue
    __pref="$(basename -- "$__frag")"; __pref="${__pref:0:2}"
    [[ ",$FRAG_PREFIXES," == *",$__pref,"* ]] || FRAG_PREFIXES="${FRAG_PREFIXES:+$FRAG_PREFIXES,}$__pref"
done
L2_STATUS=SKIPPED
if [[ -n "$FRAG_PREFIXES" ]]; then
    run_layer "L2" "all_fragments_off" \
        env R_ENVIRON_USER= BIOME_DISABLE_FRAGMENTS="$FRAG_PREFIXES" \
        "$R_BIN" --no-init-file "$USER_SCRIPT" "${USER_ARGS[@]}"
    L2_STATUS=$(awk -F'\t' '$1=="L2"{print $3; exit}' "$SUMMARY")
else
    echo "${YELLOW}── [L2] all_fragments_off ── SKIPPED (no fragment deployed in $FRAG_DIR)${NC}"
    cat >> "$REPORT" <<EOF

### Layer L2 — all_fragments_off: **SKIPPED**

No \`[0-9][0-9]_*.R\` fragment found in \`$FRAG_DIR\`: nothing to switch off, so
fragments cannot be separated from the dispatcher core. Deploy via
\`scripts/50_setup_nodes.sh\`.
EOF
fi

# ── L3s: full system profile, no user startup files (v1.4) ────────────────
# Differs from L3 ONLY by the user's startup files (home or cwd), so
# L3s PASS + L3 FAIL puts the cause in ~/.Renviron / ~/.Rprofile.
run_layer "L3s" "system_profile" \
    env R_ENVIRON_USER= "$R_BIN" --no-init-file "$USER_SCRIPT" "${USER_ARGS[@]}"
L3S_STATUS=$(awk -F'\t' '$1=="L3s"{print $3; exit}' "$SUMMARY")

# ── L3: production reference (system profile + user startup files) ────────
run_layer "L3" "full_profile" "$R_BIN" "$USER_SCRIPT" "${USER_ARGS[@]}"
L3_STATUS=$(awk -F'\t' '$1=="L3"{print $3; exit}' "$SUMMARY")

# ── Verdict ───────────────────────────────────────────────────────────────
echo
echo "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo "${BOLD}  VERDICT${NC}"
echo "${BOLD}═══════════════════════════════════════════════════════════════${NC}"

VERDICT_LINE=""
RECOMMENDED=""
NOTES=()
EXIT_CODE=1

is_bad_status() { [[ "$1" == "FAIL" || "$1" == "TIMEOUT" || "$1" == "KILLED" ]]; }

if is_bad_status "$L0_STATUS"; then
    VERDICT_LINE="LAYER L0 FAILED: infra (NFS/fork/cgroup)"
    RECOMMENDED="Fix system infrastructure. Check biome_nfs_check() output; user script blameless."
elif [[ "$L3_STATUS" == "PASS" ]]; then
    EXIT_CODE=0
    if [[ "$L0A_STATUS" == "HIGH" ]]; then
        EXIT_CODE=4
        VERDICT_LINE="INFRASTRUCTURE GREEN — user .R file has ${L0A_HIGH} HIGH-severity lint finding(s)"
        RECOMMENDED="Read 'Layer L0a — static_lint' in the report and docs/user_guides/PARALLEL_R_DOS_AND_DONTS.md. The system is not the bottleneck."
    elif [[ "$L1_STATUS" == "PASS" && "$L2_STATUS" == "PASS" && "$L3S_STATUS" == "PASS" ]]; then
        VERDICT_LINE="ALL LAYERS PASSED: script is healthy in production"
        RECOMMENDED="If user reports a bug, ask for exact reproduction (inputs, args, env)."
    else
        VERDICT_LINE="PRODUCTION LAYER L3 PASSED: script is healthy in production for this user"
        RECOMMENDED="No system fix needed. If user reports a bug, ask for exact reproduction (inputs, args, env)."
    fi
    if is_bad_status "$L3S_STATUS"; then
        NOTES+=("L3s=$L3S_STATUS but L3=PASS: the script only works WITH this user's ~/.Renviron / ~/.Rprofile (a path, token or option set there); it will not reproduce for other users or batch jobs without them.")
    fi
    if [[ "$L1_STATUS" != "PASS" || "$L2_STATUS" != "PASS" ]]; then
        NOTES+=("L1=$L1_STATUS, L2=$L2_STATUS: these layers withhold part of the system profile by design and only attribute L3 failures; a non-PASS there is not a defect of a script that passes L3.")
    fi
elif [[ "$L3_STATUS" == "PROGRESSING" ]]; then
    EXIT_CODE=3
    VERDICT_LINE="INCONCLUSIVE: production layer L3 was PROGRESSING when the timeout fired (long compute, not a stall)"
    RECOMMENDED="Re-run with --timeout doubled (e.g. --timeout $((TIMEOUT_S*2))). Script is alive; no layer blamed. HC-13: long compute is not a system bug."
elif [[ "$L3S_STATUS" == "PASS" ]]; then
    VERDICT_LINE="LAYER L3 FAILED but L3s (system profile, no user startup files) PASSED: the user's ~/.Renviron / ~/.Rprofile is the cause"
    RECOMMENDED="CONFIG-layer fix; the .R script is not edited (HC-13). From the R-studioConf checkout: sudo bash scripts/99_check_rprofile_health.sh --user ${RUN_USER} --fix (repair plan; add --commit to apply). Last resort: --reset-profile --commit quarantines the startup state."
elif is_bad_status "$L3S_STATUS" && [[ "$L2_STATUS" == "PASS" ]]; then
    VERDICT_LINE="LAYER L3s FAILED but L2 (all fragments off) PASSED: a profile fragment is the cause"
    RECOMMENDED="Bisect without user startup files: R_ENVIRON_USER= BIOME_DISABLE_FRAGMENTS=<half of: ${FRAG_PREFIXES}> ${R_BIN} --no-init-file ${USER_SCRIPT} — halve the list until one fragment is left, then patch it."
elif is_bad_status "$L3S_STATUS" && is_bad_status "$L2_STATUS" && [[ "$L1_STATUS" == "PASS" ]]; then
    VERDICT_LINE="LAYERS L3s+L2 FAILED, L1 PASSED: dispatcher itself or fragment-load contract"
    RECOMMENDED="Inspect dispatcher main local({}) in templates/Rprofile_site.R.template. The bug survives \"all fragments off\" → it's in the dispatcher core."
elif is_bad_status "$L3S_STATUS" && is_bad_status "$L2_STATUS" && is_bad_status "$L1_STATUS"; then
    VERDICT_LINE="LAYERS L1, L2, L3s, L3 ALL FAILED: NOT a profile issue → infra+terra+NFS or user-script bug"
    RECOMMENDED="Escalate to L4 (clean-VM baseline). See docs/operations/CLEAN_VM_BASELINE.md. If L4 also fails → L5 (user-script or upstream package bug)."
else
    VERDICT_LINE="LAYER L3 FAILED — cause not attributable (L1=$L1_STATUS L2=$L2_STATUS L3s=$L3S_STATUS)"
    RECOMMENDED="A layer needed for attribution was SKIPPED or PROGRESSING: deploy what is missing (scripts/50_setup_nodes.sh) or re-run with --timeout $((TIMEOUT_S*2))."
fi
if ! is_bad_status "$L0_STATUS" && [[ "$L3_STATUS" == "KILLED" || "$L3_STATUS" == "TIMEOUT" ]]; then
    NOTES+=("L3 was $L3_STATUS (resource limit or stall, not an R error): such outcomes vary with load, so confirm the attribution with a second run before patching.")
fi

echo "  ${BOLD}${VERDICT_LINE}${NC}"
for __note in "${NOTES[@]}"; do
    echo "  ${YELLOW}NOTE:${NC} $__note"
done
echo
echo "  Per-layer status:"
echo "    L0  infra_health     : $L0_STATUS"
echo "    L0a static_lint      : $L0A_STATUS  (HIGH=$L0A_HIGH MED=$L0A_MED LOW=$L0A_LOW)"
echo "    L0b smoke_run        : $L0B_STATUS"
echo "    L1  pure_R_minimal   : $L1_STATUS"
echo "    L2  all_fragments_off: $L2_STATUS"
echo "    L3s system_profile   : $L3S_STATUS"
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
$(for __note in "${NOTES[@]}"; do printf -- '\n- **Note:** %s' "$__note"; done)

| Layer | Name | Status |
|-------|------|--------|
| L0  | infra_health      | $L0_STATUS |
| L0a | static_lint       | $L0A_STATUS (HIGH=$L0A_HIGH MED=$L0A_MED LOW=$L0A_LOW) |
| L0b | smoke_run         | $L0B_STATUS |
| L1  | pure_R_minimal    | $L1_STATUS |
| L2  | all_fragments_off | $L2_STATUS |
| L3s | system_profile    | $L3S_STATUS |
| L3  | full_profile      | $L3_STATUS |

> **Per HC-13:** the user script was run UNMODIFIED in every layer above.
> If the verdict is L0..L3, the fix lands on the SYSTEM SIDE — or, when L3s
> passes and L3 fails, in the user's startup files (99_check_rprofile_health.sh),
> still never in the .R script. Only an L4-clean-VM-passes-but-L3-fails outcome
> warrants a conversation with the user about their code, and only with
> kernel-stack evidence.
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

# Exit code: set by the verdict tree above (contract: "Exit codes (v1.4)" in the header).
exit "$EXIT_CODE"

