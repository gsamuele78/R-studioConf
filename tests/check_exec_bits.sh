#!/usr/bin/env bash
# tests/check_exec_bits.sh — assert deploy-critical scripts are committed +x.
#
# WHY: r_env_manager.sh surfaces numbered phase scripts in its menu only when
# they are executable (it filters on `-executable`). A script committed as git
# mode 100644 is therefore INVISIBLE in the launcher even though it exists on
# disk — exactly the audit's "15_/40_ invisible" regression
# (docs/audits/T1_HOST_DEPLOYMENT_AUDIT.md §3). init.sh papers over it with a
# chmod loop, but only when the operator enters through init.sh. This guard
# pins the git mode so the regression cannot return.
#
# Checks the git index mode (100755), not the working-tree bit, so it is
# deterministic in CI regardless of the checkout's umask.
#
# Exit: 0 all good | 1 at least one file is not 100755 | 2 invocation error.
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

if [[ -t 1 ]]; then
    C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_RST=$'\e[0m'
else
    C_RED= C_GREEN= C_RST=
fi

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "ERROR: not inside a git work tree (this guard reads the git index mode)." >&2
    exit 2
fi

# Files that MUST be committed executable.
#   - every numbered phase / diagnostic script: scripts/NN_*.sh
#   - the two entry points and the standalone launchers operators run directly
mapfile -t required < <(
    git ls-files 'scripts/[0-9][0-9]_*.sh'
    printf '%s\n' init.sh r_env_manager.sh \
        scripts/pin_r_version.sh scripts/r_minimal.sh
)

fail=0
for f in "${required[@]}"; do
    [[ -n "${f}" ]] || continue
    mode="$(git ls-files -s -- "${f}" | awk '{print $1}')"
    if [[ -z "${mode}" ]]; then
        echo "${C_RED}MISSING${C_RST} ${f} (expected tracked + executable)"
        fail=1
        continue
    fi
    if [[ "${mode}" != "100755" ]]; then
        echo "${C_RED}NOT +x${C_RST} ${f} (git mode ${mode}, expected 100755)"
        fail=1
    fi
done

if [[ "${fail}" -ne 0 ]]; then
    echo
    echo "${C_RED}FAIL${C_RST} — fix with: git update-index --chmod=+x <file>  (or chmod +x then git add)"
    exit 1
fi

echo "${C_GREEN}PASS${C_RST} — all ${#required[@]} deploy-critical scripts are committed 100755."
