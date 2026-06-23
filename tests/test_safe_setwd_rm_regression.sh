#!/usr/bin/env bash
# tests/test_safe_setwd_rm_regression.sh
# Validates fragment 60 fix: safe_setwd survives rm(list=ls(all.names=TRUE))
#
# Run: bash tests/test_safe_setwd_rm_regression.sh
# Exit: 0 all pass | 1 critical fail | 2 invocation error
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
REPO="$(cd "${SCRIPT_DIR}/.." && pwd)"
EXIT_CODE=0

if [[ -t 1 ]]; then
    C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_BOLD=$'\e[1m'; C_RST=$'\e[0m'
else
    C_RED=; C_GREEN=; C_YELLOW=; C_BOLD=; C_RST=
fi

ok()   { printf "  ${C_GREEN}PASS${C_RST}  %s\n" "$1"; }
fail() { printf "  ${C_RED}FAIL${C_RST}  %s\n" "$1"; EXIT_CODE=1; }
info() { printf "  ${C_YELLOW}INFO${C_RST}  %s\n" "$1"; }

# ── Pre-flight checks ──────────────────────────────────────────────────────
R_BIN="${RSCRIPT:-Rscript}"
if ! command -v "${R_BIN}" &>/dev/null; then
    echo "${C_RED}ERROR${C_RST}  ${R_BIN} not found on PATH" >&2
    exit 2
fi

FRAGMENT="${REPO}/templates/Rprofile_site.d/60_safe_setwd.R.template"
TEST_R="${REPO}/tests/fixtures/test_safe_setwd_rm_regression.R"
TEST_WRAP_R="${REPO}/tests/fixtures/test_wrapper_rm_survival.R"

for f in "${FRAGMENT}" "${TEST_R}" "${TEST_WRAP_R}"; do
    [[ -f "${f}" ]] || { echo "${C_RED}ERROR${C_RST}  missing file: ${f}" >&2; exit 2; }
done

echo "${C_BOLD}== safe_setwd rm-regression test suite ==${C_RST}"
echo

# ── Test A: Template parse gate ─────────────────────────────────────────────
info "A: Template parse gate (reproduces templates_parse.sh)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT
rendered="${tmpdir}/60_safe_setwd.R"
sed -E 's/%%[A-Z0-9_]+%%/1/g' "${FRAGMENT}" > "${rendered}"
if "${R_BIN}" -e "tryCatch({parse(file='${rendered}');cat('PARSE_OK')}, error=function(e){cat('PARSE_FAIL:',conditionMessage(e));quit(status=1)})" &>/dev/null; then
    ok "A1: Fragment parses with neutralized placeholders"
else
    fail "A1: Fragment parse FAILED"
fi

# ── Test B: Static regression — original_fn used, not .biome_original_setwd ─
info "B: Static code check — safe_setwd closure uses original_fn"
if grep -q 'original_fn(dir)' "${FRAGMENT}" && ! grep -q '\.biome_original_setwd(dir)' "${FRAGMENT}"; then
    ok "B1: safe_setwd calls original_fn(dir), not .biome_original_setwd(dir)"
else
    fail "B1: safe_setwd still references .biome_original_setwd(dir)"
fi

# Verify .biome_original_setwd is still saved to globalenv for 80_tools_ext
if grep -q 'assign.*\.biome_original_setwd.*globalenv' "${FRAGMENT}"; then
    ok "B2: .biome_original_setwd still assigned to globalenv (80_tools_ext consumer)"
else
    fail "B2: .biome_original_setwd globalenv assignment missing"
fi

# ── Test C: R runtime regression suite ───────────────────────────────────────
info "C: R runtime regression suite (T1-T9)"
# Run from repo root so relative path to template resolves
cd "${REPO}"
if "${R_BIN}" "${TEST_R}" 2>&1; then
    ok "C1: All R runtime tests passed"
else
    rc=$?
    fail "C1: R runtime tests FAILED (exit ${rc})"
fi

# ── Test D: Verification that existing tests still pass (parse gate) ────────
info "D: Full template parse gate"
if bash "${REPO}/tests/templates_parse.sh" 2>&1; then
    ok "D1: All templates parse cleanly"
else
    fail "D1: Template parse gate found errors"
fi

# ── Test E: Cross-fragment wrapper rm-survival (W1-W4) ──────────────────────
info "E: Cross-fragment wrapper rm-survival (setwd/detectCores/options/compileNimble)"
if "${R_BIN}" "${TEST_WRAP_R}" 2>&1; then
    ok "E1: All wrapper rm-survival tests passed"
else
    rc=$?
    fail "E1: Wrapper rm-survival tests FAILED (exit ${rc})"
fi

echo
if [[ "${EXIT_CODE}" -eq 0 ]]; then
    echo "${C_GREEN}ALL TESTS PASSED${C_RST} — safe_setwd rm-regression fix verified."
else
    echo "${C_RED}SOME TESTS FAILED${C_RST} — review output above."
fi
exit "${EXIT_CODE}"
