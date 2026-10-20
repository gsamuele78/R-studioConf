#!/usr/bin/env bash
set -euo pipefail
# scripts/tools/release_notes.sh
# ==============================================================================
# Reads release sections from CHANGELOG.md (ADR-0006). Used by
# .github/workflows/release.yml to tag a release and fill the GitHub Release.
#
# A release section starts with `## [YYYY.MM.N] - <date> ...`; it ends at the
# next `## [` header. `## [Unreleased]` is never a release.
#
# Usage:
#   scripts/tools/release_notes.sh --latest-version [CHANGELOG]   newest version, e.g. 2026.10.0
#   scripts/tools/release_notes.sh VERSION [CHANGELOG]            that release's notes (header excluded)
#
# Exit: 0 found | 1 no such release / no release at all | 2 invocation error
# ==============================================================================

C_RED=$'\e[31m'; C_RST=$'\e[0m'
[[ -t 2 ]] || { C_RED=; C_RST=; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

die() { printf '%sERROR%s  %s\n' "${C_RED}" "${C_RST}" "$1" >&2; exit "${2:-1}"; }

[[ $# -ge 1 && $# -le 2 ]] || die "usage: $(basename "$0") --latest-version|VERSION [CHANGELOG]" 2
command -v awk >/dev/null 2>&1 || die "awk not found" 2

MODE="$1"
CHANGELOG="${2:-${REPO_ROOT}/CHANGELOG.md}"
[[ -r "${CHANGELOG}" ]] || die "cannot read ${CHANGELOG}" 2

if [[ "${MODE}" == "--latest-version" ]]; then
    v="$(awk 'match($0, /^## \[[0-9][0-9][0-9][0-9]\.[0-9][0-9]\.[0-9]+\]/) {
                 print substr($0, 5, RLENGTH - 5); exit }' "${CHANGELOG}")"
    [[ -n "${v}" ]] || die "no release section in ${CHANGELOG}"
    printf '%s\n' "${v}"
    exit 0
fi

[[ "${MODE}" =~ ^[0-9]{4}\.[0-9]{2}\.[0-9]+$ ]] || die "not a release version: ${MODE}" 2

notes="$(awk -v hdr="## [${MODE}]" '
    index($0, "## [") == 1 { if (on) exit; if (index($0, hdr) == 1) { on = 1; next } }
    on { print }' "${CHANGELOG}")"
[[ -n "${notes//[[:space:]]/}" ]] || die "no section ## [${MODE}] in ${CHANGELOG}"
printf '%s\n' "${notes}"
