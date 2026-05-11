#!/usr/bin/env bash
# tests/r_lint_test.sh — oracle differ for scripts/lib/r_lint.R
#
# For each *.R fixture under tests/fixtures/r_lint/, runs the linter and
# compares the (rule_id, severity, fixture-basename, line) tuples against
# the oracle in tests/fixtures/r_lint/expected_findings.tsv.
#
# Exit codes:
#   0 — all fixtures match oracle
#   1 — at least one fixture diverged
#   2 — invocation / environment error
#
# Flags:
#   --regenerate   Overwrite the oracle with current output (use only after
#                  a manual review confirms the new output is intentional).
#   --verbose      Print full per-fixture diff blocks.
#
# HC-13 note: the linter only DESCRIBES findings; this test asserts that
# behaviour is stable across rule edits.
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly FIXTURE_DIR="${SCRIPT_DIR}/fixtures/r_lint"
readonly ORACLE="${FIXTURE_DIR}/expected_findings.tsv"
readonly LINTER="${REPO_ROOT}/scripts/lib/r_lint.R"

# Colors (no-op if not a TTY)
if [[ -t 1 ]]; then
    C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YEL=$'\e[33m'
    C_BLUE=$'\e[34m'; C_RST=$'\e[0m'
else
    C_RED= C_GREEN= C_YEL= C_BLUE= C_RST=
fi

REGEN=0
VERBOSE=0
for arg in "$@"; do
    case "$arg" in
        --regenerate) REGEN=1 ;;
        --verbose|-v) VERBOSE=1 ;;
        -h|--help)
            sed -n '2,20p' "$0"; exit 0 ;;
        *)
            echo "${C_RED}unknown flag: $arg${C_RST}" >&2; exit 2 ;;
    esac
done

command -v Rscript >/dev/null 2>&1 || {
    echo "${C_RED}Rscript not found in PATH${C_RST}" >&2; exit 2; }

[[ -f "$LINTER" ]] || { echo "${C_RED}linter missing: $LINTER${C_RST}" >&2; exit 2; }
[[ -d "$FIXTURE_DIR" ]] || { echo "${C_RED}fixture dir missing: $FIXTURE_DIR${C_RST}" >&2; exit 2; }

# Collect fixtures (deterministic order)
mapfile -t FIXTURES < <(find "$FIXTURE_DIR" -maxdepth 1 -name '*.R' -type f | sort)
[[ ${#FIXTURES[@]} -gt 0 ]] || { echo "${C_RED}no .R fixtures found${C_RST}" >&2; exit 2; }

# Build actual TSV: rule_id<TAB>severity<TAB>fixture-basename<TAB>line
TMP_ACTUAL="$(mktemp)"
trap 'rm -f "$TMP_ACTUAL" "$TMP_EXP" "$TMP_GOT" 2>/dev/null || true' EXIT
printf 'rule_id\tseverity\tfixture\tline\n' >"$TMP_ACTUAL"

for f in "${FIXTURES[@]}"; do
    base="$(basename "$f")"
    # Linter exits 0/1/2 by severity; we don't care here, only the TSV body.
    out="$(Rscript "$LINTER" "$f" 2>/dev/null || true)"
    # Keep only data rows (rule_id matches R\d+); drop linter header & blanks.
    awk -F'\t' -v b="$base" '$1 ~ /^R[0-9]+$/ && NF>=3 {print $1"\t"$2"\t"b"\t"$3}' \
        <<<"$out" >>"$TMP_ACTUAL"
done

# Sort actual: fixture, line (numeric), rule_id
sort_tsv() {
    # keep header on top, sort body
    head -n1 "$1"
    tail -n +2 "$1" | sort -t$'\t' -k3,3 -k4,4n -k1,1
}

if [[ "$REGEN" -eq 1 ]]; then
    {
        echo "# tests/fixtures/r_lint/expected_findings.tsv"
        echo "# Oracle for tests/r_lint_test.sh — captured from a clean run of scripts/lib/r_lint.R"
        echo "# against each fixture in this directory. Regenerate with:"
        echo "#   tests/r_lint_test.sh --regenerate"
        echo "#"
        echo "# Columns: rule_id<TAB>severity<TAB>fixture<TAB>line"
        echo "# Sort order: fixture asc, line asc, rule_id asc."
        sort_tsv "$TMP_ACTUAL"
    } >"$ORACLE"
    echo "${C_YEL}oracle regenerated → $ORACLE${C_RST}"
    exit 0
fi

[[ -f "$ORACLE" ]] || { echo "${C_RED}oracle missing: $ORACLE${C_RST}" >&2; exit 2; }

# Strip comment lines from oracle and sort identically
TMP_EXP="$(mktemp)"
TMP_GOT="$(mktemp)"
{
    head -n1 "$ORACLE" 2>/dev/null  # may be a comment, will be replaced below
    grep -v '^#' "$ORACLE" | tail -n +2  # body after the header row
} >/dev/null 2>&1 || true
# Robust extraction: drop comment lines, take header + body
awk '!/^#/ {print}' "$ORACLE" >"$TMP_EXP.raw"
sort_tsv "$TMP_EXP.raw" >"$TMP_EXP"
rm -f "$TMP_EXP.raw"
sort_tsv "$TMP_ACTUAL" >"$TMP_GOT"

if diff -u "$TMP_EXP" "$TMP_GOT" >/tmp/r_lint_test.diff 2>&1; then
    n=$(($(wc -l <"$TMP_GOT") - 1))
    echo "${C_GREEN}r_lint_test: PASS${C_RST} (${#FIXTURES[@]} fixtures, $n findings match oracle)"
    exit 0
fi

echo "${C_RED}r_lint_test: FAIL${C_RST} — oracle drift detected"
echo
echo "Fixtures: ${#FIXTURES[@]}"
echo "Diff (- expected, + actual):"
echo "${C_BLUE}-------------------------------------------------------------${C_RST}"
sed -e "s/^-/${C_RED}-${C_RST}/" -e "s/^+/${C_GREEN}+${C_RST}/" /tmp/r_lint_test.diff
echo "${C_BLUE}-------------------------------------------------------------${C_RST}"
echo
echo "If the new output is intentional, regenerate the oracle:"
echo "    $(realpath --relative-to="$REPO_ROOT" "$0") --regenerate"
exit 1
