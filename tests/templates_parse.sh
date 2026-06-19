#!/usr/bin/env bash
# tests/templates_parse.sh — R-parse gate for the live Rprofile templates.
#
# WHY: scripts/50_setup_nodes.sh substitutes every %%KEY%% placeholder and then
# runs `parse(file=...)` on the dispatcher + each Rprofile_site.d fragment + the
# minimal profile BEFORE deploying them (see 50_setup_nodes.sh:1268,1361,2392) —
# precisely so an unsubstituted placeholder or a syntax slip is caught at build
# time, not at rsession boot. This test reproduces that gate in CI so a broken
# fragment is red on the PR, not discovered on a production node.
#
# Placeholders are replaced with a syntactically-neutral token (`1`, valid in
# both numeric and string contexts) — we assert SYNTAX, not values.
#
# Exit: 0 all parse | 1 at least one failed to parse | 2 invocation error.
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly TPL_DIR="${REPO_ROOT}/templates"

if [[ -t 1 ]]; then
    C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_RST=$'\e[0m'
else
    C_RED= C_GREEN= C_RST=
fi

if ! command -v Rscript >/dev/null 2>&1; then
    echo "ERROR: Rscript not found — this gate needs base R installed." >&2
    exit 2
fi

# Live templates only — NOT the archived/versioned copies (Rprofile_site*_v11* etc.).
mapfile -t targets < <(
    find "${TPL_DIR}/Rprofile_site.d" -maxdepth 1 -name '[0-9][0-9]_*.R.template' | sort
    printf '%s\n' \
        "${TPL_DIR}/Rprofile_site.R.template" \
        "${TPL_DIR}/Rprofile_site.minimal.R.template"
)

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

fail=0
checked=0
for tpl in "${targets[@]}"; do
    [[ -f "${tpl}" ]] || { echo "${C_RED}MISSING${C_RST} ${tpl#"${REPO_ROOT}/"}"; fail=1; continue; }
    rendered="${tmpdir}/$(basename "${tpl}").R"
    # Neutralize every %%PLACEHOLDER%% → 1 (syntax-safe everywhere).
    sed -E 's/%%[A-Z0-9_]+%%/1/g' "${tpl}" > "${rendered}"
    checked=$((checked + 1))
    if out="$(Rscript -e "tryCatch({parse(file='${rendered}');cat('PARSE_OK')}, error=function(e){cat('PARSE_FAIL:',conditionMessage(e));quit(status=1)})" 2>&1)"; then
        echo "${C_GREEN}OK${C_RST}    ${tpl#"${REPO_ROOT}/"}"
    else
        echo "${C_RED}FAIL${C_RST}  ${tpl#"${REPO_ROOT}/"}"
        echo "        ${out}"
        fail=1
    fi
done

echo
if [[ "${fail}" -ne 0 ]]; then
    echo "${C_RED}FAIL${C_RST} — ${checked} templates checked, at least one did not parse."
    exit 1
fi
echo "${C_GREEN}PASS${C_RST} — all ${checked} live Rprofile templates parse cleanly."
