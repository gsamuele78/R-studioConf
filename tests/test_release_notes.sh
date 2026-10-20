#!/usr/bin/env bash
set -euo pipefail
# tests/test_release_notes.sh
# Validates scripts/tools/release_notes.sh (ADR-0006), which the release
# workflow uses to pick the tag and the GitHub Release notes.
#
# Run: bash tests/test_release_notes.sh
# Exit: 0 all pass | 1 fail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${SCRIPT_DIR}/.." && pwd)"
TOOL="${REPO}/scripts/tools/release_notes.sh"
EXIT_CODE=0

if [[ -t 1 ]]; then
    C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_BOLD=$'\e[1m'; C_RST=$'\e[0m'
else
    C_RED=; C_GREEN=; C_BOLD=; C_RST=
fi
ok()   { printf "  %sPASS%s  %s\n" "${C_GREEN}" "${C_RST}" "$1"; }
fail() { printf "  %sFAIL%s  %s\n" "${C_RED}" "${C_RST}" "$1"; EXIT_CODE=1; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

cat > "${TMP}/CHANGELOG.md" <<'EOF'
# Changelog

## [Unreleased]

### Added
- not released yet

## [2026.11.1] - 2026-11-20 — Rprofile v12.12

- **Deploy:** option 3.

### Fixed
- second

## [2026.11.0] - 2026-11-02 — Rprofile v12.12

### Fixed
- first
EOF

echo "${C_BOLD}== release_notes.sh test suite ==${C_RST}"

out="$(bash "${TOOL}" --latest-version "${TMP}/CHANGELOG.md")"
[[ "${out}" == "2026.11.1" ]] && ok "R1: latest version skips [Unreleased]" || fail "R1: got '${out}'"

out="$(bash "${TOOL}" 2026.11.1 "${TMP}/CHANGELOG.md")"
if grep -q -- '- second' <<<"${out}" && ! grep -q -- '- first' <<<"${out}" \
   && ! grep -q '^## ' <<<"${out}" && grep -q 'Deploy' <<<"${out}"; then
    ok "R2: section stops at the next release header, header excluded"
else
    fail "R2: wrong section: ${out}"
fi

out="$(bash "${TOOL}" 2026.11.0 "${TMP}/CHANGELOG.md")"
grep -q -- '- first' <<<"${out}" && ok "R3: last section runs to end of file" || fail "R3: ${out}"

rc=0; bash "${TOOL}" 2026.09.0 "${TMP}/CHANGELOG.md" >/dev/null 2>&1 || rc=$?
[[ "${rc}" -eq 1 ]] && ok "R4: missing release exits 1" || fail "R4: exit ${rc}"

rc=0; bash "${TOOL}" Unreleased "${TMP}/CHANGELOG.md" >/dev/null 2>&1 || rc=$?
[[ "${rc}" -eq 2 ]] && ok "R5: non-version argument exits 2" || fail "R5: exit ${rc}"

printf '# Changelog\n\n## [Unreleased]\n\n- x\n' > "${TMP}/empty.md"
rc=0; bash "${TOOL}" --latest-version "${TMP}/empty.md" >/dev/null 2>&1 || rc=$?
[[ "${rc}" -eq 1 ]] && ok "R6: no release at all exits 1" || fail "R6: exit ${rc}"

# The real CHANGELOG must always have a readable newest release.
v="$(bash "${TOOL}" --latest-version)"
notes="$(bash "${TOOL}" "${v}")"
if [[ -n "${notes}" ]] && grep -q 'Deploy' <<<"${notes}"; then
    ok "R7: CHANGELOG.md newest release ${v} has notes with a Deploy line"
else
    fail "R7: CHANGELOG.md newest release '${v}' has no usable notes"
fi

if [[ "${EXIT_CODE}" -eq 0 ]]; then echo "  ALL RELEASE NOTES TESTS PASSED"; fi
exit "${EXIT_CODE}"
