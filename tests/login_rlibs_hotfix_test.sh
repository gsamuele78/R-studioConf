#!/usr/bin/env bash
set -uo pipefail
# tests/login_rlibs_hotfix_test.sh
# Regression gate for scripts/fix_login_script_rlibs_inplace.sh and for the
# login template change it mirrors (R_LIBS_USER no longer written to ~/.Renviron).
#
# Fixtures: the REAL templates/rstudio_user_login_script.sh.template rendered
# with lib/common_utils.sh process_template (same keys as 20_configure_rstudio.sh);
# the pre-fix deployed file is that render with the old renviron_settings entry
# re-inserted. The rendered login script is also EXECUTED for a user name that
# does not exist, so `~user` stays literal and every write lands under the
# mktemp dir. Never touches /etc, /root or the real home.
# Run: bash tests/login_rlibs_hotfix_test.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
REPO="$(cd "${SCRIPT_DIR}/.." && pwd)"
SUT="${REPO}/scripts/fix_login_script_rlibs_inplace.sh"
TPL="${REPO}/templates/rstudio_user_login_script.sh.template"

FAILS=0
ok() { printf '  PASS  %s\n' "$1"; }
no() { printf '  FAIL  %s\n' "$1"; FAILS=$((FAILS + 1)); }
check() { if eval "$1"; then ok "$2"; else no "$2"; fi; }

TMPROOT="$(mktemp -d)"
GHOST="biome_hotfix_ghost_$$"
cleanup() { rm -rf "$TMPROOT"; rm -f "/tmp/.biome_rstudio_login_stamp_${GHOST}"; }
trap cleanup EXIT

PROJ="$TMPROOT/nfs/home"
mkdir -p "$PROJ" "$TMPROOT/logs" "$TMPROOT/backup" "$TMPROOT/profile.d"
printf 'NFS_HOME="%s"\n' "$PROJ" > "$TMPROOT/vars.conf"

rendered="$TMPROOT/rendered.sh"
if ! ( export LOG_FILE="$TMPROOT/cu.log"
       # shellcheck source=../lib/common_utils.sh disable=SC1091
       source "${REPO}/lib/common_utils.sh" >/dev/null 2>&1
       out=""
       process_template "$TPL" out RSTUDIO_PROFILE_SCRIPT_PATH=/etc/profile.d/00_rstudio_user_logins.sh \
           R_PROJECTS_ROOT="$PROJ" USER_LOGIN_LOG_ROOT="$TMPROOT/logs" \
           DEFAULT_PYTHON_VERSION_LOGIN_SCRIPT=3.12 DEFAULT_PYTHON_PATH_LOGIN_SCRIPT=/usr/bin/python3 || exit 1
       printf '%s' "$out" > "$rendered" ); then
    echo "FAIL: process_template could not render ${TPL}"; exit 1
fi

# The pre-fix deployed file: same render, old entry back in place, and no final
# newline — 20_configure_rstudio.sh writes it with printf "%s".
mk_old() {
    awk '{ print } /^[[:space:]]*renviron_settings=\($/ { print "        [\"R_LIBS_USER\"]=\"\\\"${user_r_libs_dir}\\\"\"" }' \
        "$rendered" > "$1"
    truncate -s -1 "$1"
    chmod 0754 "$1"
    touch -d '2026-01-02 03:04:05' "$1"
}
# shellcheck disable=SC2034  # read inside eval'd check strings
run_sut() { OUT="$(FIX_LOGIN_BACKUP_ROOT="$TMPROOT/backup" FIX_LOGIN_VARS_CONF="${VARS:-$TMPROOT/vars.conf}" \
                   bash "$SUT" "$@" 2>&1)"; RC=$?; }
has() { grep -qF -- "$1" <<< "$OUT"; }

# run_login FILE — execute a rendered login script for $GHOST; prints the resulting ~/.Renviron
run_login() {
    local wd="$TMPROOT/run.$RANDOM"
    mkdir -p "$wd/~${GHOST}"
    rm -f "/tmp/.biome_rstudio_login_stamp_${GHOST}"
    ( cd "$wd" && env -i PATH="$PATH" USER="$GHOST" HOME="$wd/~${GHOST}" bash "$1" >/dev/null 2>&1 ) || true
    cat "$wd/~${GHOST}/.Renviron" 2>/dev/null || true
}

echo "## 1. template + render"
check 'bash -n "$TPL"' "template passes bash -n"
check '! grep -qE "\[[[:space:]]*\"R_LIBS_USER\"[[:space:]]*\]" "$rendered"' "rendered login script has no R_LIBS_USER entry"
if command -v R >/dev/null 2>&1; then
    old="$TMPROOT/old_exec.sh"; mk_old "$old"
    # shellcheck disable=SC2034  # read inside eval'd check strings
    renv_old="$(run_login "$old")"
    # shellcheck disable=SC2034  # read inside eval'd check strings
    renv_new="$(run_login "$rendered")"
    check 'grep -q "^R_LIBS_USER=" <<< "$renv_old"' "control: pre-fix login script appends R_LIBS_USER"
    check '! grep -q "^R_LIBS_USER=" <<< "$renv_new" && grep -q "^XDG_DATA_HOME=" <<< "$renv_new"' \
          "fixed login script: no R_LIBS_USER, XDG_* still written"
    check '[[ -d "$PROJ/$GHOST/R/x86_64-pc-linux-gnu-library" ]]' "user R library directory still created"
else
    echo "  SKIP  login-script execution (R not on PATH)"
fi

echo "## 2. hotfix: refusals"
T="$TMPROOT/profile.d/00_rstudio_user_logins.sh"
printf '#!/bin/bash\n    renviron_settings=(\n        ["R_LIBS_USER"]="x"\n    )\n' > "$T"
run_sut --commit --target "$T"
check '[[ $RC -eq 1 ]] && has "is not rendered from"' "foreign file → refused (exit 1)"

mk_old "$T"; sed -i 's|^\([[:space:]]*\["XDG_DATA_HOME"\]\)|        ["R_LIBS_USER"]="y"\n\1|' "$T"
sum_before="$(md5sum < "$T")"
run_sut --commit --target "$T"
check '[[ $RC -eq 1 ]] && has "2 R_LIBS_USER entries" && [[ "$(md5sum < "$T")" == "$sum_before" ]]' \
      "two entries → refused, file untouched"

mk_old "$T"; printf 'NFS_HOME="/somewhere/else"\n' > "$TMPROOT/vars_other.conf"
sum_before="$(md5sum < "$T")"
VARS="$TMPROOT/vars_other.conf" run_sut --commit --target "$T"
check '[[ $RC -eq 1 ]] && has "cannot confirm" && [[ "$(md5sum < "$T")" == "$sum_before" ]]' \
      "projects root ≠ NFS_HOME → refused, file untouched"
VARS="$TMPROOT/vars_other.conf" run_sut --commit --force --target "$T"
check '[[ $RC -eq 0 ]] && has "--force"' "--force overrides the projects-root check"

run_sut --bogus
check '[[ $RC -eq 2 ]]' "unknown argument → exit 2"

echo "## 3. hotfix: dry-run, commit, idempotence, rollback"
mk_old "$T"
# shellcheck disable=SC2034  # read inside eval'd check strings
sum_before="$(md5sum < "$T")"
# shellcheck disable=SC2034  # read inside eval'd check strings
mt_before="$(stat -c %Y "$T")"
# shellcheck disable=SC2034  # read inside eval'd check strings
lc_before="$(wc -l < "$T")"
run_sut --target "$T"
check '[[ $RC -eq 0 ]] && has "DRY-RUN" && has "+        # [hotfix" && [[ "$(md5sum < "$T")" == "$sum_before" ]]' \
      "dry-run shows the diff, changes nothing"

run_sut --commit --target "$T"
check '[[ $RC -eq 0 ]] && has "applied"' "commit → exit 0"
check '! grep -qE "\[[[:space:]]*\"R_LIBS_USER\"[[:space:]]*\]" "$T" && grep -q "# \[hotfix " "$T"' "entry replaced by the hotfix comment"
check 'bash -n "$T"' "patched file passes bash -n"
bdir="$(find "$TMPROOT/backup" -maxdepth 1 -name 'login-script-hotfix-*' | sort | tail -n1)"
check '[[ "$(wc -l < "$T")" -eq "$lc_before" && "$(diff "$bdir/00_rstudio_user_logins.sh" "$T" | grep -c "^[<>]")" -eq 2 ]]' \
      "exactly one line replaced (line count kept)"
check '[[ -n "$(tail -c1 "$T")" ]]' "no final newline added (matches how 20_configure_rstudio.sh writes it)"
check '[[ "$(stat -c %Y "$T")" == "$mt_before" ]]' "mtime kept (no mass re-run of the login script)"
check '[[ "$(stat -c %a "$T")" == "754" ]]' "mode copied from the original"
check '! ls -A "$TMPROOT/profile.d" | grep -q "hotfix"' "no temp file left in the target directory"
check '[[ -n "$bdir" && "$(md5sum < "$bdir/00_rstudio_user_logins.sh")" == "$sum_before" ]]' "backup holds the original"
if command -v R >/dev/null 2>&1; then
    # shellcheck disable=SC2034  # read inside eval'd check strings
    renv_fix="$(run_login "$T")"
    check '! grep -q "^R_LIBS_USER=" <<< "$renv_fix" && grep -q "^XDG_CONFIG_HOME=" <<< "$renv_fix"' \
          "hotfixed file, executed: no R_LIBS_USER, XDG_* still written"
fi

run_sut --commit --target "$T"
check '[[ $RC -eq 0 ]] && has "already applied"' "second run → already applied (exit 0)"

run_sut --rollback "$bdir" --target "$T"
check '[[ $RC -eq 0 && "$(md5sum < "$T")" == "$sum_before" && "$(stat -c %Y "$T")" == "$mt_before" ]]' \
      "rollback restores content and mtime"

mk_old "$T"
run_sut --commit --rerun-logins --target "$T"
check '[[ $RC -eq 0 && "$(stat -c %Y "$T")" -gt "$mt_before" ]]' "--rerun-logins bumps the mtime"

echo
if [[ $FAILS -eq 0 ]]; then echo "ALL PASS"; exit 0; fi
echo "${FAILS} FAILURE(S)"; exit 1
