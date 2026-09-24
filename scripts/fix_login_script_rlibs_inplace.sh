#!/usr/bin/env bash
set -euo pipefail
# scripts/fix_login_script_rlibs_inplace.sh
#
# ONE-SHOT HOTFIX for nodes whose deployed RStudio login script
# (/etc/profile.d/00_rstudio_user_logins.sh, rendered by 20_configure_rstudio.sh
# from templates/rstudio_user_login_script.sh.template) still writes
# R_LIBS_USER into every user's ~/.Renviron.
#
# Why: /etc/R/Renviron.site (50_setup_nodes.sh) owns R_LIBS_USER. ~/.Renviron
# is read after it, so the login script's copy overrides the local-disk
# library path once ENABLE_R_LIBS_LOCAL=true, and it re-adds the line that
# 50_setup_nodes.sh Step 9 / 99_check_user_renviron_overrides.sh remove.
# The template is fixed in the repo; this script applies the same one-line
# change to the deployed file WITHOUT re-running 20_configure_rstudio.sh
# (its options 1/3 also re-chown the home root — do not use them on a
# populated node until that is refactored).
#
# What it changes (nothing else is touched):
#   * the single  ["R_LIBS_USER"]=...  entry of renviron_settings in the
#     deployed login script is replaced by a comment. Existing R_LIBS_USER
#     lines in users' ~/.Renviron are left alone (with ENABLE_R_LIBS_LOCAL=false
#     they equal R's built-in default and have no effect).
#
# Safety:
#   * dry-run by default (prints the diff); --commit applies.
#   * refuses a file that is not the rendered template, or that has more
#     than one matching line.
#   * refuses when the login script's USER_PROJECTS_BASE_DIR differs from
#     NFS_HOME in config/setup_nodes.vars.conf: only there is the R default
#     library (~/R/...) the same directory the script used to point at.
#     --force overrides after you have checked it yourself.
#   * backup (cp -p) in ${BACKUP_ROOT}/login-script-hotfix-<ts>/ BEFORE the swap.
#   * new file built in the same directory under a name that does not end
#     in .sh (never sourced), checked with bash -n, owner/mode copied from
#     the original (failure → exit 1), then swapped with a single mv.
#   * the ORIGINAL mtime is kept: the login script skips work while a user's
#     /tmp/.biome_rstudio_login_stamp_<user> is newer than it, so no user
#     re-runs it because of this hotfix (it applies at their next natural
#     run, e.g. after a reboot). --rerun-logins stamps it "now" instead:
#     every user then re-runs the whole login script at their next login.
#   * no service restart; running sessions are not affected.
#
# Usage:
#   sudo bash scripts/fix_login_script_rlibs_inplace.sh                 # dry-run
#   sudo bash scripts/fix_login_script_rlibs_inplace.sh --commit        # apply
#   sudo bash scripts/fix_login_script_rlibs_inplace.sh --rollback DIR  # restore a backup dir
#   Options: --target PATH (default /etc/profile.d/00_rstudio_user_logins.sh)
#            --force  --rerun-logins  -h|--help
#   Env:     FIX_LOGIN_BACKUP_ROOT (default /root)
#            FIX_LOGIN_VARS_CONF   (default <repo>/config/setup_nodes.vars.conf)
#
# Exit codes:
#   0 applied, already applied, or dry-run shows a change
#   1 refused or failed (nothing swapped unless stated)
#   2 usage error

readonly C_RED='\033[0;31m'
readonly C_GREEN='\033[0;32m'
readonly C_YELLOW='\033[0;33m'
readonly C_BLUE='\033[0;34m'
readonly C_BOLD='\033[1m'
readonly C_RESET='\033[0m'

log_info()  { printf '%b[INFO]%b %s\n' "$C_BLUE" "$C_RESET" "$*"; }
log_ok()    { printf '%b[ OK ]%b %s\n' "$C_GREEN" "$C_RESET" "$*"; }
log_warn()  { printf '%b[WARN]%b %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
log_error() { printf '%b[FAIL]%b %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
log_head()  { printf '\n%b== %s ==%b\n' "$C_BOLD" "$*" "$C_RESET"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly MATCH_RE='^[[:space:]]*\[[[:space:]]*"R_LIBS_USER"[[:space:]]*\][[:space:]]*='
readonly TEMPLATE_MARK='generated from a template: templates/rstudio_user_login_script.sh.template'

TARGET="/etc/profile.d/00_rstudio_user_logins.sh"
BACKUP_ROOT="${FIX_LOGIN_BACKUP_ROOT:-/root}"
VARS_CONF="${FIX_LOGIN_VARS_CONF:-${REPO_DIR}/config/setup_nodes.vars.conf}"
MODE="dry-run"
ROLLBACK_DIR=""
FORCE=false
KEEP_MTIME=true
TMP_FILE=""

usage() { awk 'NR > 2 && /^#/ { sub(/^# ?/, ""); print; next } NR > 2 { exit }' "${BASH_SOURCE[0]}"; }

cleanup() {
    if [[ -n "$TMP_FILE" && -e "$TMP_FILE" ]]; then rm -f -- "$TMP_FILE"; fi
}
trap cleanup EXIT

while [[ $# -gt 0 ]]; do
    case "$1" in
        --commit)       MODE="commit"; shift ;;
        --rollback)
            [[ $# -ge 2 ]] || { log_error "--rollback needs a backup directory"; exit 2; }
            MODE="rollback"; ROLLBACK_DIR="$2"; shift 2 ;;
        --target)
            [[ $# -ge 2 ]] || { log_error "--target needs a path"; exit 2; }
            TARGET="$2"; shift 2 ;;
        --force)        FORCE=true; shift ;;
        --rerun-logins) KEEP_MTIME=false; shift ;;
        -h|--help)      usage; exit 0 ;;
        *) log_error "unknown argument: $1 (see --help)"; exit 2 ;;
    esac
done

# swap_in SRC — install SRC over TARGET atomically, owner/mode from TARGET.
# Caller decides the mtime of SRC beforehand.
swap_in() {
    local src="$1" dir base
    dir="$(dirname "$TARGET")"; base="$(basename "$TARGET")"
    TMP_FILE="$(mktemp "${dir}/.${base%.sh}.hotfix.XXXXXX")"
    cp -p -- "$src" "$TMP_FILE"
    chown --reference="$TARGET" "$TMP_FILE" || { log_error "chown --reference=${TARGET} failed — nothing swapped"; exit 1; }
    chmod --reference="$TARGET" "$TMP_FILE" || { log_error "chmod --reference=${TARGET} failed — nothing swapped"; exit 1; }
    touch -r "$src" "$TMP_FILE"
    mv -f -- "$TMP_FILE" "$TARGET"
    TMP_FILE=""
}

[[ -f "$TARGET" && ! -L "$TARGET" && -r "$TARGET" ]] || { log_error "not a readable regular file: ${TARGET}"; exit 1; }
if [[ "$MODE" != "dry-run" && ( ! -w "$TARGET" || ! -w "$(dirname "$TARGET")" ) ]]; then
    log_error "no write access to ${TARGET} or its directory (run with sudo)"; exit 1
fi

# ── Rollback ──────────────────────────────────────────────────────────────
if [[ "$MODE" == "rollback" ]]; then
    log_head "Rollback ${TARGET}"
    src="${ROLLBACK_DIR%/}/$(basename "$TARGET")"
    [[ -f "$src" ]] || { log_error "no backup file ${src}"; exit 1; }
    bash -n "$src" || { log_error "backup ${src} does not pass bash -n — refusing"; exit 1; }
    swap_in "$src"
    log_ok "restored ${TARGET} from ${src} (original mtime kept)"
    exit 0
fi

log_head "Login script R_LIBS_USER hotfix (${MODE})"
log_info "target: ${TARGET}"

grep -qF "$TEMPLATE_MARK" "$TARGET" || {
    log_error "${TARGET} is not rendered from templates/rstudio_user_login_script.sh.template — refusing"
    exit 1
}

n_match="$(grep -cE "$MATCH_RE" "$TARGET" || true)"
if [[ "$n_match" -eq 0 ]]; then
    log_ok "already applied: the login script does not write R_LIBS_USER"
    exit 0
fi
if [[ "$n_match" -ne 1 ]]; then
    log_error "${n_match} R_LIBS_USER entries found (expected 1) — hand-edited file? refusing"
    grep -nE "$MATCH_RE" "$TARGET" >&2 || true
    exit 1
fi

# USER_PROJECTS_BASE_DIR vs NFS_HOME: the removed line pointed at
# ${USER_PROJECTS_BASE_DIR}/<user>/R/...; R's default is ${HOME}/R/...
proj_root="$(grep -m1 -E '^USER_PROJECTS_BASE_DIR=' "$TARGET" | cut -d= -f2- | tr -d '"' || true)"
nfs_home=""
if [[ -r "$VARS_CONF" ]]; then
    nfs_home="$(grep -E '^[[:space:]]*NFS_HOME=' "$VARS_CONF" | tail -n1 | cut -d= -f2- | tr -d '"' | sed 's/[[:space:]]*#.*$//' || true)"
fi
log_info "USER_PROJECTS_BASE_DIR=${proj_root:-<unset>}  NFS_HOME=${nfs_home:-<unknown: ${VARS_CONF} unreadable>}"
if [[ -z "$proj_root" || -z "$nfs_home" || "${proj_root%/}" != "${nfs_home%/}" ]]; then
    if [[ "$FORCE" != true ]]; then
        log_error "cannot confirm that <projects root>/<user> is each user's \$HOME"
        log_error "  after the hotfix R uses \$HOME/R/x86_64-pc-linux-gnu-library/<ver> for users without an R_LIBS_USER line"
        log_error "  check a user's home (getent passwd <user>) and re-run with --force if they match"
        exit 1
    fi
    log_warn "--force: projects root / NFS_HOME check overridden"
fi

stage="$(mktemp)"
trap 'rm -f -- "$stage"; cleanup' EXIT
HOTFIX_RE="$MATCH_RE" HOTFIX_DATE="$(date +%Y-%m-%d)" awk '
    $0 ~ ENVIRON["HOTFIX_RE"] {
        match($0, /^[[:space:]]*/)
        printf "%s# [hotfix %s] R_LIBS_USER entry removed: /etc/R/Renviron.site owns it (fix_login_script_rlibs_inplace.sh)\n", substr($0, 1, RLENGTH), ENVIRON["HOTFIX_DATE"]
        next
    }
    { print }
' "$TARGET" > "$stage"

bash -n "$stage" || { log_error "patched file does not pass bash -n — nothing changed"; exit 1; }
[[ "$(grep -cE "$MATCH_RE" "$stage" || true)" -eq 0 ]] || { log_error "patch did not remove the entry — nothing changed"; exit 1; }
[[ "$(wc -l < "$stage")" -eq "$(wc -l < "$TARGET")" ]] || { log_error "line count changed unexpectedly — nothing changed"; exit 1; }

printf '\n'
diff -u --label "${TARGET} (deployed)" --label "${TARGET} (hotfix)" "$TARGET" "$stage" || true
printf '\n'

if [[ "$MODE" == "dry-run" ]]; then
    log_info "DRY-RUN — nothing changed. Apply: sudo bash ${BASH_SOURCE[0]} --commit"
    exit 0
fi

ts="$(date +%Y%m%d-%H%M%S)"
bdir="${BACKUP_ROOT%/}/login-script-hotfix-${ts}"
mkdir -p -- "$bdir" || { log_error "cannot create backup dir ${bdir} — nothing changed"; exit 1; }
cp -p -- "$TARGET" "${bdir}/" || { log_error "backup to ${bdir} failed — nothing changed"; exit 1; }
log_ok "backup: ${bdir}/$(basename "$TARGET")"

if [[ "$KEEP_MTIME" == true ]]; then
    touch -r "$TARGET" "$stage"
else
    touch "$stage"
fi
swap_in "$stage"

if [[ "$(grep -cE "$MATCH_RE" "$TARGET" || true)" -ne 0 ]] || ! bash -n "$TARGET"; then
    log_error "post-check failed on ${TARGET} — restore: sudo bash ${BASH_SOURCE[0]} --rollback ${bdir}"
    exit 1
fi
log_ok "applied: the login script no longer writes R_LIBS_USER"
if [[ "$KEEP_MTIME" == true ]]; then
    log_info "mtime kept: users pick it up at their next natural run (stamp in /tmp expires, e.g. reboot)"
else
    log_info "mtime is now: every user re-runs the login script at their next login"
fi
log_info "rollback: sudo bash ${BASH_SOURCE[0]} --rollback ${bdir}"
log_info "templates/rstudio_user_login_script.sh.template carries the same change: a later redeploy keeps the fix"
exit 0
