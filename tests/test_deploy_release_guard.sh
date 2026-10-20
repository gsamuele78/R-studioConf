#!/usr/bin/env bash
set -euo pipefail
# tests/test_deploy_release_guard.sh
# Validates lib/deploy_release.sh (ADR-0006): the deployed-release stamp that
# Step 8 of scripts/50_setup_nodes.sh writes, and the guard that refuses an
# older, diverged or locally modified checkout unless --allow-downgrade.
# Uses throwaway git repos under mktemp; touches nothing on the host.
#
# Run: bash tests/test_deploy_release_guard.sh
# Exit: 0 all pass | 1 fail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${SCRIPT_DIR}/.." && pwd)"
LIB="${REPO}/lib/deploy_release.sh"
SETUP="${REPO}/scripts/50_setup_nodes.sh"
EXIT_CODE=0

if [[ -t 1 ]]; then
    C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_BOLD=$'\e[1m'; C_RST=$'\e[0m'
else
    C_RED=; C_GREEN=; C_BOLD=; C_RST=
fi
ok()   { printf "  %sPASS%s  %s\n" "${C_GREEN}" "${C_RST}" "$1"; }
fail() { printf "  %sFAIL%s  %s\n" "${C_RED}" "${C_RST}" "$1"; EXIT_CODE=1; }

command -v git >/dev/null 2>&1 || { echo "git not found" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# shellcheck source=../lib/deploy_release.sh disable=SC1091
source "${LIB}"

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
CO="${TMP}/checkout"
STAMP="${TMP}/etc/deployed_release"
LOG="${TMP}/guard.log"
g() { git -C "${CO}" "$@" >/dev/null 2>&1; }

mkdir -p "${CO}/templates" "${CO}/config"
git init -q -b main "${CO}"
echo v1 > "${CO}/templates/a.template"; echo site=1 > "${CO}/config/x.vars.conf"
g add -A; g commit -qm c1; g tag v2026.10.0
C1="$(git -C "${CO}" rev-parse HEAD)"
echo v2 > "${CO}/templates/a.template"; g commit -qam c2
C2="$(git -C "${CO}" rev-parse HEAD)"

# guard ALLOW -> sets RC, captures stderr log
run_guard() { RC=0; biome_release_guard "${CO}" "${STAMP}" "${1:-false}" 2>"${LOG}" || RC=$?; }

echo "${C_BOLD}== deploy_release.sh test suite ==${C_RST}"

run_guard
[[ "${RC}" == 0 ]] && grep -q 'first stamped deploy' "${LOG}" \
    && ok "D1: no stamp -> deploy with a warning" || fail "D1: rc=${RC} $(cat "${LOG}")"

biome_release_write_stamp "${CO}" "${STAMP}" 12.11 false 2>/dev/null
if [[ "$(biome_release_field "${STAMP}" commit)" == "${C2}" \
   && "$(biome_release_field "${STAMP}" release)" == "v2026.10.0-1-g${C2:0:7}" \
   && "$(biome_release_field "${STAMP}" branch)" == "main" \
   && "$(biome_release_field "${STAMP}" templates_clean)" == "true" \
   && "$(biome_release_field "${STAMP}" rprofile_version)" == "12.11" \
   && "$(biome_release_field "${STAMP}" override)" == "false" \
   && "$(biome_release_field "${STAMP}" previous_commit)" == "none" \
   && "$(wc -l < "${STAMP}.history")" -eq 1 ]]; then
    ok "D2: stamp records release, commit, branch, Rprofile version; history has 1 line"
else
    fail "D2: stamp: $(cat "${STAMP}")"
fi
[[ -z "$(find "${TMP}/etc" -name 'deployed_release.??????')" ]] \
    && ok "D3: atomic write leaves no temp file" || fail "D3: temp file left"

run_guard
[[ "${RC}" == 0 ]] && grep -q 'redeploying the deployed commit' "${LOG}" \
    && ok "D4: same commit -> deploy" || fail "D4: rc=${RC}"

echo v3 > "${CO}/templates/a.template"; g commit -qam c3
C3="$(git -C "${CO}" rev-parse HEAD)"
run_guard
[[ "${RC}" == 0 ]] && grep -q 'upgrade' "${LOG}" \
    && ok "D5: newer commit on the same history -> deploy" || fail "D5: rc=${RC}"

biome_release_write_stamp "${CO}" "${STAMP}" 12.11 false 2>/dev/null
g checkout -q v2026.10.0
run_guard
[[ "${RC}" == 1 ]] && grep -q 'OLDER than the deployed' "${LOG}" && grep -q 'allow-downgrade' "${LOG}" \
    && ok "D6: older tag -> refused, message names --allow-downgrade" || fail "D6: rc=${RC} $(cat "${LOG}")"

run_guard true
[[ "${RC}" == 3 ]] && grep -q 'overridden' "${LOG}" \
    && ok "D7: older tag + --allow-downgrade -> deploy (rc 3)" || fail "D7: rc=${RC}"

biome_release_write_stamp "${CO}" "${STAMP}" 12.11 true 2>/dev/null
if [[ "$(biome_release_field "${STAMP}" commit)" == "${C1}" \
   && "$(biome_release_field "${STAMP}" override)" == "true" \
   && "$(biome_release_field "${STAMP}" previous_commit)" == "${C3}" \
   && "$(biome_release_field "${STAMP}" branch)" == "(detached)" \
   && "$(wc -l < "${STAMP}.history")" -eq 3 ]] && grep -q 'override=true' "${STAMP}.history"; then
    ok "D8: rollback stamp records override=true and the commit it replaced"
else
    fail "D8: stamp: $(cat "${STAMP}")"
fi

g checkout -q main
run_guard
[[ "${RC}" == 0 ]] && ok "D9: after a rollback, main is an upgrade again" || fail "D9: rc=${RC}"

g checkout -q -b stale "${C1}"
echo stale > "${CO}/templates/b.template"; g add -A; g commit -qm stale
biome_release_write_stamp "${CO}" "${STAMP}" 12.11 true 2>/dev/null   # deployed = stale branch tip
g checkout -q main
g checkout -q -b other "${C1}"; echo o > "${CO}/templates/c.template"; g add -A; g commit -qm other
run_guard
[[ "${RC}" == 1 ]] && grep -q 'diverged' "${LOG}" \
    && ok "D10: diverged branch (calc04 case) -> refused" || fail "D10: rc=${RC} $(cat "${LOG}")"
g checkout -q main

printf 'commit=%s\n' "$(printf 'f%.0s' {1..40})" > "${STAMP}"
run_guard
[[ "${RC}" == 1 ]] && grep -q 'git fetch' "${LOG}" \
    && ok "D11: deployed commit unknown to the checkout -> refused, hint git fetch" || fail "D11: rc=${RC}"

printf 'release=x\n' > "${STAMP}"
run_guard
[[ "${RC}" == 1 ]] && grep -q 'no valid commit' "${LOG}" \
    && ok "D12: stamp without a commit -> refused" || fail "D12: rc=${RC}"

biome_release_write_stamp "${CO}" "${STAMP}" 12.11 false 2>/dev/null
echo local > "${CO}/templates/a.template"
run_guard
[[ "${RC}" == 1 ]] && grep -q 'templates/ has local changes' "${LOG}" \
    && ok "D13: modified template -> refused" || fail "D13: rc=${RC}"
g checkout -- templates/a.template

echo new > "${CO}/templates/untracked.template"
run_guard
[[ "${RC}" == 1 ]] && ok "D14: untracked file under templates/ -> refused" || fail "D14: rc=${RC}"
rm -f "${CO}/templates/untracked.template"

chmod +x "${CO}/templates/a.template"
echo site=2 > "${CO}/config/x.vars.conf"
run_guard
[[ "${RC}" == 0 ]] && ok "D15: mode-only template change and local config values -> deploy" \
    || fail "D15: rc=${RC} $(cat "${LOG}")"
biome_release_write_stamp "${CO}" "${STAMP}" 12.11 false 2>/dev/null
[[ "$(biome_release_field "${STAMP}" release)" == *-dirty \
   && "$(biome_release_field "${STAMP}" templates_clean)" == "true" ]] \
    && ok "D16: local config values show as -dirty, templates_clean=true" || fail "D16: $(cat "${STAMP}")"
chmod -x "${CO}/templates/a.template"; g checkout -- config/x.vars.conf

mkdir -p "${TMP}/notgit"
RC=0; biome_release_guard "${TMP}/notgit" "${STAMP}" false 2>"${LOG}" || RC=$?
[[ "${RC}" == 1 ]] && grep -q 'not a git checkout' "${LOG}" \
    && ok "D17: not a git checkout -> refused" || fail "D17: rc=${RC}"

out="$(biome_release_show "${CO}" "${STAMP}" 2>&1)"
grep -q '= deployed \[OK\]' <<<"${out}" && ok "D18: show: checkout matches the stamp" || fail "D18: ${out}"
echo v4 > "${CO}/templates/a.template"; g commit -qam c4
out="$(biome_release_show "${CO}" "${STAMP}" 2>&1)"
grep -q 'differs from deployed' <<<"${out}" && ok "D19: show: checkout ahead of the stamp" || fail "D19: ${out}"
out="$(biome_release_show "${CO}" "${TMP}/none" 2>&1)"
grep -q 'no stamp' <<<"${out}" && ok "D20: show: no stamp" || fail "D20: ${out}"

# Wiring in scripts/50_setup_nodes.sh (static: the script needs root + a real host).
body="$(awk '/^setup_nodes_config_files\(\) \{/,/^}$/' "${SETUP}")"
first_guard="$(grep -n 'setup_nodes_release_guard' <<<"${body}" | head -1 | cut -d: -f1 || true)"
first_write="$(grep -n 'run_cmd' <<<"${body}" | head -1 | cut -d: -f1 || true)"
last_stamp="$(grep -n 'biome_release_write_stamp' <<<"${body}" | tail -1 | cut -d: -f1 || true)"
last_cmd="$(grep -n 'run_cmd' <<<"${body}" | tail -1 | cut -d: -f1 || true)"
[[ -n "${first_guard}" && -n "${first_write}" && "${first_guard}" -lt "${first_write}" ]] \
    && ok "D21: Step 8 runs the guard before its first write" || fail "D21: guard=${first_guard} write=${first_write}"
[[ -n "${last_stamp}" && "${last_stamp}" -gt "${last_cmd}" ]] \
    && ok "D22: Step 8 writes the stamp after its last write" || fail "D22: stamp=${last_stamp} last=${last_cmd}"
grep -q -- '--allow-downgrade) ALLOW_DOWNGRADE=true' "${SETUP}" \
    && ok "D23: --allow-downgrade flag parsed" || fail "D23: flag missing"
for opt in 1 O; do
    awk -v o="  ${opt})" '$0==o {on=1; next} on && /;;/ {exit} on' "${SETUP}" | grep -q 'setup_nodes_release_guard' \
        && ok "D24: menu option ${opt} runs the guard before its first step" || fail "D24: option ${opt}"
done

exit "${EXIT_CODE}"
