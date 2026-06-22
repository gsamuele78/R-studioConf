#!/usr/bin/env bash
set -uo pipefail
# tests/test_pr1_critical_fixes.sh
# Proves the PR-1 §1 fixes (T1 audit / triage items 1-4). Self-contained:
# writes only under a mktemp dir, never invokes real apt/systemctl/services.
# Run: bash tests/test_pr1_critical_fixes.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
REPO="$(cd "${SCRIPT_DIR}/.." && pwd)"
export LOG_FILE=/dev/null MAIN_LOG_FILE=/dev/null
FAILS=0
ok(){ printf '  PASS  %s\n' "$1"; }
no(){ printf '  FAIL  %s\n' "$1"; FAILS=$((FAILS+1)); }

# shellcheck source=../lib/common_utils.sh disable=SC1091
source "${REPO}/lib/common_utils.sh" >/dev/null 2>&1

echo "## Item 2 — run_command preserves the caller's pipefail"
( set -o pipefail; run_command "noop" "true" >/dev/null 2>&1; [[ -o pipefail ]] ) \
  && ok "pipefail ON stays ON after run_command" || no "pipefail ON was clobbered"
( set +o pipefail; run_command "noop" "true" >/dev/null 2>&1; [[ -o pipefail ]] && exit 1 || exit 0 ) \
  && ok "pipefail OFF stays OFF after run_command" || no "pipefail OFF was clobbered"

echo "## Item 1 — failures propagate (not masked as success)"
MAX_RETRIES=1 run_command "expect-fail" "false" >/dev/null 2>&1 && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] && ok "run_command 'false' returns non-zero ($rc)" || no "run_command masked a failure as 0"
# Static regression guard: the masking idiom must be gone.
if grep -q 'run_command "${description}" "$part" || return \$?' "${REPO}/lib/common_utils.sh" \
   && ! grep -Pzoq 'if ! run_command "\$\{description\}" "\$part"; then\s*\n\s*return \$\?' "${REPO}/lib/common_utils.sh"; then
  ok "composite-apt recursion uses '|| return \$?' (no negated-test masking)"
else
  no "composite-apt masking pattern still present"
fi

echo "## Item 3 — restore_config actually restores (into a scratch root)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
BACKUP_DIR_BASE="${TMP}/backups"
bk="${BACKUP_DIR_BASE}/run_20260101_000000"
# Mirror a path that resolves UNDER $TMP (dest = "/" + path-relative-to-backup).
mkdir -p "${bk}/${TMP#/}/etc"
printf 'RESTORED_CONTENT\n' > "${bk}/${TMP#/}/etc/biome_test.conf"
dest="${TMP}/etc/biome_test.conf"
# Stub service detection so the restart branch can never touch real services.
command(){ if [[ "${1:-}" == "-v" ]]; then return 1; else builtin command "$@"; fi; }

# 3a: DRY_RUN must not write
DRY_RUN=true restore_config <<<"y" >/dev/null 2>&1
[[ ! -e "$dest" ]] && ok "DRY_RUN restore writes nothing" || no "DRY_RUN restore wrote to disk"
# 3b: real restore writes the file with correct content
printf 'y\n' | restore_config >/dev/null 2>&1
if [[ -f "$dest" && "$(cat "$dest")" == "RESTORED_CONTENT" ]]; then
  ok "restore_config restored the file with correct content"
else
  no "restore_config did NOT restore the file (regression to no-op?)"
fi
# 3c: declining leaves system untouched
rm -f "$dest"
printf 'n\n' | restore_config >/dev/null 2>&1
[[ ! -e "$dest" ]] && ok "declining the prompt restores nothing" || no "restore ran despite 'n'"
# 3d: large backup — streaming restore handles many files; listing is capped
BACKUP_DIR_BASE="${TMP}/backups_big"
bkb="${BACKUP_DIR_BASE}/run_20260102_000000"
mkdir -p "${bkb}/${TMP#/}/big/etc"
for i in $(seq 1 25); do printf 'c%s\n' "$i" > "${bkb}/${TMP#/}/big/etc/f${i}.conf"; done
out="$(printf 'y\n' | restore_config 2>&1)"
n=$(find "${TMP}/big/etc" -type f 2>/dev/null | wc -l)
[[ "$n" -eq 25 ]] && ok "streaming restore handled all 25 files" || no "expected 25 restored, got ${n}"
grep -q 'and 5 more' <<<"$out" && ok "target listing capped (shows '… and 5 more')" || no "sample cap not applied"
# 3e: no backup dir → non-zero
BACKUP_DIR_BASE="${TMP}/does_not_exist"; restore_config <<<"y" >/dev/null 2>&1 && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] && ok "missing backup returns non-zero" || no "missing backup returned success"
unset -f command

echo "## Item 4 — uninstall no longer crashes on undefined state (static + set -u guard)"
grep -q 'readonly R_ENV_STATE_FILE=' "${REPO}/r_env_manager.sh" \
  && ok "R_ENV_STATE_FILE is defined" || no "R_ENV_STATE_FILE still undefined"
grep -q 'local -a INSTALLED_CRAN_PACKAGES=() INSTALLED_GITHUB_PACKAGES=()' "${REPO}/r_env_manager.sh" \
  && ok "uninstall arrays defaulted empty (guards set -u)" || no "uninstall arrays not defaulted"
# Replicate the guarded reference under `set -u` — must not abort.
( set -u; declare -a INSTALLED_CRAN_PACKAGES=() INSTALLED_GITHUB_PACKAGES=()
  if [[ ${#INSTALLED_CRAN_PACKAGES[@]} -gt 0 || ${#INSTALLED_GITHUB_PACKAGES[@]} -gt 0 ]]; then :; fi ) \
  && ok "empty-array reference is set -u safe" || no "empty-array reference aborts under set -u"

echo
if [[ "$FAILS" -eq 0 ]]; then echo "ALL PR-1 TESTS PASSED"; else echo "${FAILS} TEST(S) FAILED"; fi
exit "$FAILS"
