#!/usr/bin/env bash
# tests/test_parquet_sidecar_gate.sh
# Validates fragment 50 v12.11-fix2: read.csv/fread never return a stale or
# argument-incompatible .parquet sidecar.
#
# Run: bash tests/test_parquet_sidecar_gate.sh
# Exit: 0 all pass | 1 fail | 2 invocation error
set -euo pipefail

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

R_BIN="${RSCRIPT:-Rscript}"
command -v "${R_BIN}" &>/dev/null || { echo "${C_RED}ERROR${C_RST}  ${R_BIN} not found" >&2; exit 2; }

FRAGMENT="${REPO}/templates/Rprofile_site.d/50_pkg_hooks.R.template"
TEST_R="${REPO}/tests/fixtures/test_parquet_sidecar_gate.R"
for f in "${FRAGMENT}" "${TEST_R}"; do
    [[ -f "${f}" ]] || { echo "${C_RED}ERROR${C_RST}  missing file: ${f}" >&2; exit 2; }
done

echo "${C_BOLD}== parquet sidecar gate test suite ==${C_RST}"

info "S: Static checks on fragment 50"
if [[ "$(grep -c '\.sidecar <- \.biome_parquet_sidecar' "${FRAGMENT}")" -eq 2 ]]; then
    ok "S1: read.csv and fread wrappers both route through the sidecar gate"
else
    fail "S1: a Smart I/O wrapper bypasses .biome_parquet_sidecar"
fi
if grep -qE 'file\.exists\(pq\) && interactive\(\)' "${FRAGMENT}"; then
    fail "S2: ungated sidecar check (file.exists(pq) && interactive()) still present"
else
    ok "S2: no ungated sidecar check left"
fi

info "P: Behavioural checks on the gate"
if (cd "${REPO}" && "${R_BIN}" --vanilla "${TEST_R}"); then
    ok "P: gate behaviour"
else
    fail "P: gate behaviour"
fi

exit "${EXIT_CODE}"
