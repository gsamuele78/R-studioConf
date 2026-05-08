#!/bin/bash
# scripts/fix_pam_segfault_inplace.sh
#
# ONE-SHOT RETROFIT for nodes already deployed with an older R-studioConf
# release that shipped libpam-krb5 and the 'krb5' pam-config profile.
#
# This script:
#   1. Detects the current PAM configuration (krb5 profile, pam_krb5.so lines,
#      installed pam modules, winbind vs sss provider).
#   2. Prints a dry-run diagnosis (use --check to stop after this step).
#   3. Applies the minimal set of changes to eliminate the SIGSEGV on `passwd`
#      for local users (uid < 10000) WITHOUT re-running the realm join, the
#      full 10_/11_ scripts, or re-installing anything that might disturb AD
#      operation.
#
# Changes applied (all idempotent, all reversible):
#   a. Backup /etc/pam.d/common-* and /etc/krb5.conf to /root/pam-backup-<ts>/
#   b. Uninstall libpam-krb5 (apt-get purge, only if installed).
#   c. Remove /usr/share/pam-configs/krb5 if it lingers after purge.
#   d. Install /usr/share/pam-configs/biome-localguard from the repo template.
#   e. Run `pam-auth-update --package` to regenerate common-auth/password/session.
#   f. Post-check: pam_krb5.so absent from every common-* file, guard present
#      in common-password, AD provider (winbind or sss) still in the stack.
#
# Nothing else is touched: krb5.conf, sssd.conf, smb.conf, realm membership,
# keytabs, NSS, home-mount scripts — all left exactly as they are.
#
# Usage:
#   sudo ./scripts/fix_pam_segfault_inplace.sh            # apply fix
#   sudo ./scripts/fix_pam_segfault_inplace.sh --check    # diagnose only
#   sudo ./scripts/fix_pam_segfault_inplace.sh --rollback # restore last backup
#
# Exit codes:
#   0 success (or nothing to do)
#   1 generic failure / pre-check failed
#   2 rollback failure
#   3 post-check failed (PAM possibly in bad state; restore from backup)

set -euo pipefail

# --- Colors (project standard) -----------------------------------------------
readonly C_RED='\033[0;31m'
readonly C_GREEN='\033[0;32m'
readonly C_YELLOW='\033[0;33m'
readonly C_BLUE='\033[0;34m'
readonly C_BOLD='\033[1m'
readonly C_RESET='\033[0m'

log_info()  { printf "${C_BLUE}[INFO]${C_RESET} %s\n" "$*"; }
log_ok()    { printf "${C_GREEN}[ OK ]${C_RESET} %s\n" "$*"; }
log_warn()  { printf "${C_YELLOW}[WARN]${C_RESET} %s\n" "$*" >&2; }
log_error() { printf "${C_RED}[FAIL]${C_RESET} %s\n" "$*" >&2; }
log_head()  { printf "\n${C_BOLD}== %s ==${C_RESET}\n" "$*"; }

# --- Paths -------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
readonly SCRIPT_DIR
readonly REPO_ROOT="$(cd "$SCRIPT_DIR/.." &>/dev/null && pwd)"
readonly TEMPLATE_SRC="${REPO_ROOT}/templates/pam-configs/biome-localguard.template"
readonly PAM_CONFIG_DST="/usr/share/pam-configs/biome-localguard"
readonly KRB5_PAM_CONFIG="/usr/share/pam-configs/krb5"
readonly BACKUP_ROOT="/root"
readonly LAST_BACKUP_LINK="${BACKUP_ROOT}/pam-backup-latest"
readonly PAM_FILES=(common-auth common-password common-session common-session-noninteractive)

MODE="apply"     # apply | check | rollback

# --- Arg parsing -------------------------------------------------------------
for arg in "$@"; do
    case "$arg" in
        --check)    MODE="check" ;;
        --rollback) MODE="rollback" ;;
        -h|--help)
            sed -n '2,40p' "$0"
            exit 0
            ;;
        *)
            log_error "Unknown argument: $arg"
            exit 1
            ;;
    esac
done

# --- Preflight ---------------------------------------------------------------
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    log_error "This script must be run as root."
    exit 1
fi

# --- Rollback branch ---------------------------------------------------------
if [[ "$MODE" == "rollback" ]]; then
    log_head "Rollback mode"
    if [[ ! -L "$LAST_BACKUP_LINK" && ! -d "$LAST_BACKUP_LINK" ]]; then
        log_error "No previous backup found at $LAST_BACKUP_LINK"
        exit 2
    fi
    TARGET_BACKUP="$(readlink -f "$LAST_BACKUP_LINK")"
    log_info "Restoring from $TARGET_BACKUP"
    for f in "${PAM_FILES[@]}"; do
        if [[ -f "$TARGET_BACKUP/$f" ]]; then
            install -m 0644 -o root -g root "$TARGET_BACKUP/$f" "/etc/pam.d/$f"
            log_ok "Restored /etc/pam.d/$f"
        fi
    done
    if [[ -f "$PAM_CONFIG_DST" ]]; then
        rm -f "$PAM_CONFIG_DST"
        log_ok "Removed $PAM_CONFIG_DST"
    fi
    log_warn "Note: libpam-krb5 package itself is NOT reinstalled by rollback."
    log_warn "If you truly need it back, run: apt-get install libpam-krb5 && pam-auth-update --package"
    log_ok   "Rollback complete."
    exit 0
fi

# --- Detection ---------------------------------------------------------------
log_head "Detection"

detect_os=""
if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    detect_os="${PRETTY_NAME:-unknown}"
fi
log_info "OS: ${detect_os:-unknown}"

has_libpam_krb5="no"
if dpkg -s libpam-krb5 &>/dev/null; then
    has_libpam_krb5="yes"
fi
log_info "libpam-krb5 installed: $has_libpam_krb5"

has_krb5_profile="no"
[[ -f "$KRB5_PAM_CONFIG" ]] && has_krb5_profile="yes"
log_info "Profile $KRB5_PAM_CONFIG present: $has_krb5_profile"

has_localguard="no"
[[ -f "$PAM_CONFIG_DST" ]] && has_localguard="yes"
log_info "biome-localguard profile present: $has_localguard"

pam_krb5_hits=0
for f in "${PAM_FILES[@]}"; do
    if [[ -f "/etc/pam.d/$f" ]] && grep -Eq '^[^#]*pam_krb5\.so' "/etc/pam.d/$f"; then
        pam_krb5_hits=$((pam_krb5_hits + 1))
        log_warn "pam_krb5.so active in /etc/pam.d/$f"
    fi
done
log_info "Active pam_krb5.so lines: $pam_krb5_hits"

ad_provider="none"
if dpkg -s libpam-winbind &>/dev/null; then
    ad_provider="winbind"
elif dpkg -s libpam-sss &>/dev/null; then
    ad_provider="sss"
fi
log_info "AD PAM provider detected: $ad_provider"

guard_present="no"
if [[ -f /etc/pam.d/common-password ]] && \
   grep -Eq 'pam_succeed_if\.so.*uid[[:space:]]*>=[[:space:]]*10000' /etc/pam.d/common-password; then
    guard_present="yes"
fi
log_info "uid>=10000 guard in common-password: $guard_present"

# --- Diagnosis ---------------------------------------------------------------
log_head "Diagnosis"
needs_fix="no"
if [[ "$has_libpam_krb5" == "yes" || "$has_krb5_profile" == "yes" || "$pam_krb5_hits" -gt 0 ]]; then
    log_warn "Node IS affected by the pam_krb5 segfault risk."
    needs_fix="yes"
fi
if [[ "$guard_present" == "no" ]]; then
    log_warn "biome-localguard not in effect on common-password."
    needs_fix="yes"
fi
if [[ "$ad_provider" == "none" ]]; then
    log_warn "No AD PAM provider found — is this node actually joined?"
    log_warn "Proceeding anyway; guard is still safe on a pure-local box."
fi
if [[ "$needs_fix" == "no" ]]; then
    log_ok "Node already hardened. Nothing to do."
    exit 0
fi

if ! [[ -f "$TEMPLATE_SRC" ]]; then
    log_error "Template not found: $TEMPLATE_SRC"
    log_error "Run this from inside the R-studioConf repo checkout."
    exit 1
fi

if ! command -v pam-auth-update &>/dev/null; then
    log_error "pam-auth-update not found (libpam-runtime missing?)."
    exit 1
fi

if [[ "$MODE" == "check" ]]; then
    log_head "Dry-run mode (--check): no changes applied"
    log_info "Re-run without --check to apply the fix."
    exit 0
fi

# --- Apply -------------------------------------------------------------------
log_head "Applying fix"

# (a) Backup
BACKUP_DIR="${BACKUP_ROOT}/pam-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
for f in "${PAM_FILES[@]}"; do
    [[ -f "/etc/pam.d/$f" ]] && cp -a "/etc/pam.d/$f" "$BACKUP_DIR/"
done
[[ -f /etc/krb5.conf ]] && cp -a /etc/krb5.conf "$BACKUP_DIR/"
ln -sfn "$BACKUP_DIR" "$LAST_BACKUP_LINK"
log_ok "Backup: $BACKUP_DIR  (symlink: $LAST_BACKUP_LINK)"

# (b) Purge libpam-krb5 if installed
if [[ "$has_libpam_krb5" == "yes" ]]; then
    log_info "Purging libpam-krb5..."
    if ! DEBIAN_FRONTEND=noninteractive apt-get purge -y libpam-krb5; then
        log_error "apt-get purge libpam-krb5 failed."
        exit 1
    fi
    log_ok "libpam-krb5 purged."
fi

# (c) Remove leftover krb5 pam-config
if [[ -f "$KRB5_PAM_CONFIG" ]]; then
    rm -f "$KRB5_PAM_CONFIG"
    log_ok "Removed leftover $KRB5_PAM_CONFIG"
fi

# (d) Install biome-localguard profile
install -m 0644 -o root -g root "$TEMPLATE_SRC" "$PAM_CONFIG_DST"
log_ok "Installed $PAM_CONFIG_DST"

# (e) Regenerate PAM stack
log_info "Running pam-auth-update --package ..."
if ! DEBIAN_FRONTEND=noninteractive pam-auth-update --package; then
    log_error "pam-auth-update --package failed."
    log_warn  "Restore from $BACKUP_DIR if /etc/pam.d/common-* is broken."
    exit 1
fi
log_ok "PAM stack regenerated."

# --- Post-check --------------------------------------------------------------
log_head "Post-check"
fail=0

# Guard present
if grep -Eq 'pam_succeed_if\.so.*uid[[:space:]]*>=[[:space:]]*10000' /etc/pam.d/common-password; then
    log_ok "common-password contains 'pam_succeed_if uid >= 10000' guard."
else
    log_error "Guard NOT present in /etc/pam.d/common-password."
    fail=1
fi

# pam_krb5 absent everywhere
for f in "${PAM_FILES[@]}"; do
    if [[ -f "/etc/pam.d/$f" ]] && grep -Eq '^[^#]*pam_krb5\.so' "/etc/pam.d/$f"; then
        log_error "pam_krb5.so still active in /etc/pam.d/$f"
        fail=1
    fi
done
[[ $fail -eq 0 ]] && log_ok "pam_krb5.so absent from all common-* files."

# AD provider still present in auth stack
case "$ad_provider" in
    winbind)
        if grep -Eq '^[^#]*pam_winbind\.so' /etc/pam.d/common-auth; then
            log_ok "pam_winbind.so still in common-auth."
        else
            log_warn "pam_winbind.so missing from common-auth — AD logins may break."
            log_warn "Run: pam-auth-update --enable winbind  (then re-run this script)"
        fi
        ;;
    sss)
        if grep -Eq '^[^#]*pam_sss\.so' /etc/pam.d/common-auth; then
            log_ok "pam_sss.so still in common-auth."
        else
            log_warn "pam_sss.so missing from common-auth — AD logins may break."
            log_warn "Run: pam-auth-update --enable sss  (then re-run this script)"
        fi
        ;;
    none)
        log_info "(No AD provider to re-check.)"
        ;;
esac

if [[ $fail -ne 0 ]]; then
    log_error "Post-check FAILED. Backup at $BACKUP_DIR — restore with: $0 --rollback"
    exit 3
fi

log_head "Done"
log_ok  "PAM password stack hardened in-place. Local-user 'passwd' is safe now."
log_info "Smoke test:   sudo -u ladmin passwd     (expect normal prompt, no segfault)"
log_info "Rollback:     $0 --rollback"
log_info "Backup dir:   $BACKUP_DIR"
exit 0
