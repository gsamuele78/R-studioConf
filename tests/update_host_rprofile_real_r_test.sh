#!/usr/bin/env bash
set -uo pipefail
# tests/update_host_rprofile_real_r_test.sh
# update_host.sh --component rprofile with a REAL R (CI job "R runtime static").
# tests/update_host_test.sh covers the flow with an Rscript stub; this one proves
# that the start-up check really loads the rendered profile and fragments, and
# that a fragment failing at run time (not at parse time) is caught before the swap.
# Fake root (HU_ROOT), runs as the current user. Never touches /etc.
# Run: bash tests/update_host_rprofile_real_r_test.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
REPO="$(cd "${SCRIPT_DIR}/.." && pwd)"

command -v Rscript >/dev/null 2>&1 || { echo "Rscript not found: this test needs R"; exit 1; }

FAILS=0
ok() { printf '  PASS  %s\n' "$1"; }
no() { printf '  FAIL  %s\n' "$1"; FAILS=$((FAILS + 1)); }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/root" "$T/fragerr"

run() { OUT="$(HU_ROOT="$T/root" HU_NO_SYSLOG=1 HU_SKIP_ROOT_CHECK=1 HU_R_SMOKE_USER="" \
               HU_FRAG_ERR_DIR=/tmp LOG_FILE="$T/cu.log" \
               bash "$1" --component rprofile "${@:2}" 2>&1)"; RC=$?; }

echo "== 1. Fresh apply with real R: staged and deployed start-up both pass"
run "${REPO}/scripts/update_host.sh" --apply --allow-untagged
if [[ $RC -eq 0 ]] && grep -q "start-up OK" <<< "$OUT"; then ok "apply exit 0, start-up OK"; else no "apply (rc=$RC)"; printf '%s\n' "$OUT" | tail -n 20; fi
if [[ -s "$T/root/etc/R/Rprofile_site.d/.compiled/bundle.Rc" ]]; then ok "bundle compiled by real R"; else no "bundle missing"; fi
if [[ "$(grep -c 'original_fn(dir)' "$T/root/etc/R/Rprofile_site.d/60_safe_setwd.R")" -eq 1 ]]; then ok "setwd fix deployed"; else no "setwd fix missing"; fi

echo "== 2. Idempotence with real R"
run "${REPO}/scripts/update_host.sh" --plan
if [[ $RC -eq 0 ]]; then ok "plan after apply: exit 0"; else no "plan after apply (rc=$RC)"; printf '%s\n' "$OUT" | grep -E 'CHANGED|NEW|REBUILD'; fi

echo "== 3. A fragment that fails at run time is rejected before the swap"
mkdir -p "$T/repo"
cp -a "${REPO}/scripts" "${REPO}/lib" "${REPO}/templates" "${REPO}/config" "$T/repo/"
echo 'stop("biome_runtime_failure_probe")' >> "$T/repo/templates/Rprofile_site.d/60_safe_setwd.R.template"
before="$(cd "$T/root" && find etc/R -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum)"
run "$T/repo/scripts/update_host.sh" --apply --allow-untagged
if [[ $RC -eq 1 ]] && grep -q "biome_runtime_failure_probe" <<< "$OUT"; then ok "runtime failure caught: exit 1, error shown"; else no "runtime failure not caught (rc=$RC)"; printf '%s\n' "$OUT" | tail -n 10; fi
after="$(cd "$T/root" && find etc/R -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum)"
if [[ "$before" == "$after" ]]; then ok "deployed files untouched"; else no "deployed files changed"; fi

echo
if (( FAILS )); then echo "update_host_rprofile_real_r_test: ${FAILS} FAILED"; exit 1; fi
echo "update_host_rprofile_real_r_test: all checks passed"
