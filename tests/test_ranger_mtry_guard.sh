#!/usr/bin/env bash
# tests/test_ranger_mtry_guard.sh
# Validates the dispatcher v12.11-fix2 ranger mtry guard: a clear error
# instead of "User interrupt or internal error.", in the session and in
# PSOCK workers, without ever changing mtry.
#
# Run: bash tests/test_ranger_mtry_guard.sh
# Exit: 0 all pass | 1 fail | 2 invocation error (Rscript or ranger missing)
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

DISPATCHER="${REPO}/templates/Rprofile_site.R.template"
TEST_R="${REPO}/tests/fixtures/test_ranger_mtry_guard.R"
for f in "${DISPATCHER}" "${TEST_R}"; do
    [[ -f "${f}" ]] || { echo "${C_RED}ERROR${C_RST}  missing file: ${f}" >&2; exit 2; }
done

echo "${C_BOLD}== ranger mtry guard test suite ==${C_RST}"

info "S: Static checks on the dispatcher"
guard_line="$(grep -n '# >>> biome_ranger_mtry_guard' "${DISPATCHER}" | cut -d: -f1 || true)"
worker_line="$(grep -n '^if (nzchar(Sys.getenv("BIOME_WORKER_MODE"' "${DISPATCHER}" | cut -d: -f1 || true)"
if [[ -n "${guard_line}" && -n "${worker_line}" && "${guard_line}" -lt "${worker_line}" ]]; then
    ok "S1: guard is installed before the worker/full-profile branch (covers both)"
else
    fail "S1: guard missing or placed after the worker branch"
fi
if sed -n '/# >>> biome_ranger_mtry_guard/,/# <<< biome_ranger_mtry_guard/p' "${DISPATCHER}" \
     | grep -qE '^[[:space:]]*mtry[[:space:]]*(<-|<<-|=)[^=]|assign\("mtry"'; then
    fail "S2: guard assigns mtry (it must only check, never change it — HC-17)"
else
    ok "S2: guard never assigns mtry"
fi

info "G: Behavioural checks with the real ranger package"
set +e
(cd "${REPO}" && "${R_BIN}" --vanilla "${TEST_R}")
rc=$?
set -e
case "${rc}" in
    0) ok "G: guard behaviour" ;;
    2) echo "${C_RED}ERROR${C_RST}  ranger not installed" >&2; exit 2 ;;
    *) fail "G: guard behaviour" ;;
esac

exit "${EXIT_CODE}"
