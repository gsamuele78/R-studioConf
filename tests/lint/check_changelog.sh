#!/usr/bin/env bash
# tests/lint/check_changelog.sh
set -euo pipefail
# ==============================================================================
# CHANGELOG.md structure gate (adapted from gsamuele78/Proxmox_biome_log_collector
# tests/lint/check-changelog.sh, MIT):
#   - "## [Unreleased]" exists and is the first "## [" section;
#   - release headings are "## [X.Y.Z] - YYYY-MM-DD", newest first, no duplicates;
#   - every vX.Y.Z git tag has its section (release.yml publishes it as notes).
#
# Usage: tests/lint/check_changelog.sh [--tag vX.Y.Z]
#   --tag  check only that tag's section instead of every tag (release.yml: an
#          older tag's CHANGELOG cannot contain sections for later tags).
# The R-runtime log (docs/reference/Rprofile_site.CHANGELOG.md) has its own
# format and its own gate (make doc-coherence, HC-14).
# ==============================================================================
RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'

ONLY_TAG=""
case "${1:-}" in
    --tag) ONLY_TAG="${2:?--tag needs a value}" ;;
    "")    ;;
    *)     echo "usage: $0 [--tag vX.Y.Z]" >&2; exit 2 ;;
esac

cd "$(dirname "$0")/../.."
status=0
err() { echo -e "${RED}CHANGELOG.md: $*${NC}" >&2; status=1; }

mapfile -t headings < <(grep -E '^## \[' CHANGELOG.md)
[[ "${headings[0]:-}" == "## [Unreleased]" ]] || err "first section must be '## [Unreleased]'"

versions=()
for h in "${headings[@]:1}"; do
    if [[ "$h" =~ ^##\ \[([0-9]+\.[0-9]+\.[0-9]+)\]\ -\ [0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        versions+=("${BASH_REMATCH[1]}")
    else
        err "malformed release heading: '${h}' (want '## [X.Y.Z] - YYYY-MM-DD')"
    fi
done

if (( ${#versions[@]} > 1 )); then
    [[ "$(printf '%s\n' "${versions[@]}" | sort -rV)" == "$(printf '%s\n' "${versions[@]}")" ]] \
        || err "release sections are not newest-first: ${versions[*]}"
    [[ "$(printf '%s\n' "${versions[@]}" | sort -u | wc -l)" -eq ${#versions[@]} ]] \
        || err "duplicate release section"
fi

while read -r tag; do
    [[ -n "$tag" ]] || continue
    printf '%s\n' "${versions[@]}" | grep -qxF "${tag#v}" || err "tag ${tag} has no '## [${tag#v}]' section"
done < <(if [[ -n "$ONLY_TAG" ]]; then echo "$ONLY_TAG"; else git tag -l 'v[0-9]*.[0-9]*.[0-9]*'; fi)

(( status == 0 )) && echo -e "${GREEN}CHANGELOG.md: OK (${#versions[@]} releases)${NC}"
exit "$status"
