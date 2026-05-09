#!/bin/bash
# scripts/99_diagnose_user_script.sh — GENERIC HC-13 user-script triage harness
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
# Optional env:
#   BIOME_DIAG_TIMEOUT_S   per-layer timeout in seconds (default 1200 = 20 min)
#   BIOME_DIAG_OUT_DIR     output dir (default /tmp/user_diag_<ts>)
#   BIOME_DIAG_R_BIN       Rscript binary (default: Rscript on PATH)
#
# Exit codes:
#   0 — all layers passed (script is healthy in production)
#   1 — at least one layer failed; verdict in $OUT_DIR/report.md
#   2 — invocation error (missing script, bad args)
# ==============================================================================
set -euo pipefail

# ── Color vars (PSE convention — HC-03) ───────────────────────────────────
RED=$'\e[0;31m'; YELLOW=$'\e[0;33m'; GREEN=$'\e[0;32m'
BLUE=$'\e[0;34m'; CYAN=$'\e[0;36m'; BOLD=$'\e[1m'; NC=$'\e[0m'

# ── Args ──────────────────────────────────────────────────────────────────
if [[ $# -lt 1 ]]; then
    cat <<EOF >&2
${BOLD}99_diagnose_user_script.sh${NC} — HC-13 generic user-script triage harness
Usage: $0 <user_script.R> [args...]

Per HC-13 we run YOUR SCRIPT UNMODIFIED through 4 system layers and
tell you which layer is responsible. We do not edit your code.
EOF
    exit 2
fi

USER_SCRIPT="$1"; shift
USER_ARGS=("$@")

if [[ ! -f "$USER_SCRIPT" ]]; then
    echo "${RED}ERROR:${NC} script not found: $USER_SCRIPT" >&2
    exit 2
fi
USER_SCRIPT="$(realpath -- "$USER_SCRIPT")"

TIMEOUT_S="${BIOME_DIAG_TIMEOUT_S:-1200}"
TS="$(date +%Y%m%d_%H%M%S)"
OUT_DIR="${BIOME_DIAG_OUT_DIR:-/tmp/user_diag_${TS}}"
R_BIN="${BIOME_DIAG_R_BIN:-Rscript}"
R_MIN="/usr/local/bin/r_minimal_rscript"

mkdir -p "$OUT_DIR"
REPORT="$OUT_DIR/report.md"
SUMMARY="$OUT_DIR/summary.tsv"

# ── Header ────────────────────────────────────────────────────────────────
echo "${BOLD}${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo "${BOLD}${BLUE}  BIOME-CALC USER-SCRIPT TRIAGE HARNESS  (HC-13)${NC}"
echo "${BOLD}${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo "  Script:  $USER_SCRIPT"
echo "  Args:    ${USER_ARGS[*]:-(none)}"
echo "  Out:     $OUT_DIR"
echo "  Timeout: ${TIMEOUT_S}s per layer"
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
        124) status="TIMEOUT"; echo "  ${RED}TIMEOUT${NC} after ${dt}s" ;;
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

if [[ "$L0_STATUS" == "FAIL" || "$L0_STATUS" == "TIMEOUT" || "$L0_STATUS" == "KILLED" ]]; then
    VERDICT_LINE="LAYER L0 FAILED: infra (NFS/fork/cgroup)"
    RECOMMENDED="Fix system infrastructure. Check biome_nfs_check() output; user script blameless."
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
echo "    L0 infra_health      : $L0_STATUS"
echo "    L1 pure_R_minimal    : $L1_STATUS"
echo "    L2 all_fragments_off : $L2_STATUS"
echo "    L3 full_profile      : $L3_STATUS"
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
| L0 | infra_health | $L0_STATUS |
| L1 | pure_R_minimal | $L1_STATUS |
| L2 | all_fragments_off | $L2_STATUS |
| L3 | full_profile | $L3_STATUS |

> **Per HC-13:** the user script was run UNMODIFIED in every layer above.
> If the verdict is L0..L3, the fix lands on the SYSTEM SIDE.
> Only an L4-clean-VM-passes-but-L3-fails outcome warrants a conversation
> with the user about their code, and only with kernel-stack evidence.
EOF

# Exit 0 only if all non-skipped layers passed
if [[ "$VERDICT_LINE" == "ALL LAYERS PASSED"* ]]; then
    exit 0
else
    exit 1
fi
