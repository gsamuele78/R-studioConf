#!/bin/bash
# scripts/fix_pam_segfault_inplace.sh
#
# ONE-SHOT RETROFIT for nodes already deployed with an older R-studioConf
# release that shipped libpam-krb5 and/or the now-obsolete `biome-localguard`
# pam-config profile.
#
# This script:
#   1. Detects the current PAM configuration (krb5 profile, pam_krb5.so lines,
#      biome-localguard guard lines, hand-edits, AD provider).
#   2. Prints a dry-run diagnosis (use --check to stop after this step).
#   3. Applies the minimal set of changes to eliminate the SIGSEGV on
#      `passwd` for local users (uid < 10000) AND to remove the bogus
#      biome-localguard that breaks `passwd` on Ubuntu 24.04.
#
# Changes applied (all idempotent, all reversible):
#   a. Backup /etc/pam.d/common-* + /etc/krb5.conf to /root/pam-backup-<ts>/
#   b. Uninstall libpam-krb5 (apt-get purge, only if installed).
#   c. Remove /usr/share/pam-configs/krb5 and /usr/share/pam-configs/biome-localguard
#      if they linger.
#   d. Strip any dangling `pam_krb5.so` lines from every common-*.
#   e. Strip any legacy `pam_succeed_if uid >= 10000` guard lines.
#   f. Truncate hand-edits AFTER `# end of pam-auth-update config` in every
#      common-* (this is where the rogue `pam_deny requisite` tends to hide).
#   g. `pam-auth-update --force --package` to regenerate the managed block.
#   h. Post-check: pam_krb5.so absent from every common-*, AD provider still
#      present in common-auth, no legacy guard lines remain.
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
readonly LEGACY_LOCALGUARD="/usr/share/pam-configs/biome-localguard"
readonly KRB5_PAM_CONFIG="/usr/share/pam-configs/krb5"
readonly BACKUP_ROOT="/root"
readonly LAST_BACKUP_LINK="${BACKUP_ROOT}/pam-backup-latest"
# NOTE: common-account is CRITICAL — it is included by /etc/pam.d/sudo, login,
# su, sshd, etc. A dangling pam_krb5.so reference there breaks sudo with
# "sudo: PAM account management error: Module is unknown".
readonly PAM_FILES=(common-account common-auth common-password common-session common-session-noninteractive)

MODE="apply"     # apply | check | rollback

# --- Arg parsing -------------------------------------------------------------
for arg in "$@"; do
    case "$arg" in
        --check)    MODE="check" ;;
        --rollback) MODE="rollback" ;;
        -h|--help)
            sed -n '2,44p' "$0"
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
    log_warn "Note: libpam-krb5 package is NOT reinstalled by rollback."
    log_warn "If you truly need it back, run: apt-get install libpam-krb5"
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

has_legacy_guard_profile="no"
[[ -f "$LEGACY_LOCALGUARD" ]] && has_legacy_guard_profile="yes"
log_info "Legacy biome-localguard profile present: $has_legacy_guard_profile"

pam_krb5_hits=0
for f in "${PAM_FILES[@]}"; do
    if [[ -f "/etc/pam.d/$f" ]] && grep -Eq '^[^#]*pam_krb5\.so' "/etc/pam.d/$f"; then
        pam_krb5_hits=$((pam_krb5_hits + 1))
        log_warn "pam_krb5.so active in /etc/pam.d/$f"
    fi
done
log_info "Active pam_krb5.so lines: $pam_krb5_hits"

legacy_guard_hits=0
for f in "${PAM_FILES[@]}"; do
    if [[ -f "/etc/pam.d/$f" ]] && grep -Eq 'pam_succeed_if\.so.*uid[[:space:]]*(>=|<)[[:space:]]*10000' "/etc/pam.d/$f"; then
        legacy_guard_hits=$((legacy_guard_hits + 1))
        log_warn "Legacy biome-localguard line in /etc/pam.d/$f"
    fi
done
log_info "Legacy guard (pam_succeed_if uid>=10000) lines: $legacy_guard_hits"

handedit_hits=0
for f in "${PAM_FILES[@]}"; do
    fp="/etc/pam.d/$f"
    if [[ -f "$fp" ]] && grep -q '^# end of pam-auth-update config' "$fp"; then
        # count non-blank, non-comment lines AFTER the end-marker
        after=$(awk '/^# end of pam-auth-update config/{flag=1; next} flag && $0 !~ /^[[:space:]]*(#|$)/ {c++} END{print c+0}' "$fp")
        if [[ "$after" -gt 0 ]]; then
            handedit_hits=$((handedit_hits + 1))
            log_warn "Hand-edits found after end-marker in $fp ($after active lines)"
        fi
    fi
done
log_info "Common-* files with hand-edits after end-marker: $handedit_hits"

ad_provider="none"
if dpkg -s libpam-winbind &>/dev/null; then
    ad_provider="winbind"
elif dpkg -s libpam-sss &>/dev/null; then
    ad_provider="sss"
fi
log_info "AD PAM provider detected: $ad_provider"

# --- Diagnosis ---------------------------------------------------------------
log_head "Diagnosis"
needs_fix="no"
if [[ "$has_libpam_krb5" == "yes" || "$has_krb5_profile" == "yes" || "$pam_krb5_hits" -gt 0 ]]; then
    log_warn "Node IS affected by the pam_krb5 segfault risk."
    needs_fix="yes"
fi
if [[ "$has_legacy_guard_profile" == "yes" || "$legacy_guard_hits" -gt 0 ]]; then
    log_warn "Node has the obsolete biome-localguard — will cause 'passwd' failures."
    needs_fix="yes"
fi
if [[ "$handedit_hits" -gt 0 ]]; then
    log_warn "Node has hand-edits after pam-auth-update end-marker — must be pruned."
    needs_fix="yes"
fi
if [[ "$ad_provider" == "none" ]]; then
    log_warn "No AD PAM provider found — is this node actually joined?"
    log_warn "Proceeding anyway; cleanup is safe on a pure-local box."
fi
if [[ "$needs_fix" == "no" ]]; then
    log_ok "Node already clean. Nothing to do."
    exit 0
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

# (c) Remove leftover pam-config profiles
if [[ -f "$KRB5_PAM_CONFIG" ]]; then
    rm -f "$KRB5_PAM_CONFIG"
    log_ok "Removed leftover $KRB5_PAM_CONFIG"
fi
if [[ -f "$LEGACY_LOCALGUARD" ]]; then
    rm -f "$LEGACY_LOCALGUARD"
    log_ok "Removed obsolete $LEGACY_LOCALGUARD"
fi

# (d) Strip dangling pam_krb5.so lines from common-*.
for f in "${PAM_FILES[@]}"; do
    fp="/etc/pam.d/$f"
    if [[ -f "$fp" ]] && grep -Eq '^[^#]*pam_krb5\.so' "$fp"; then
        sed -i -E '/^[^#]*pam_krb5\.so/d' "$fp"
        log_ok "Stripped pam_krb5.so line(s) from $fp"
    fi
done

# (e) Strip legacy biome-localguard lines (pam_succeed_if uid>=10000)
for f in "${PAM_FILES[@]}"; do
    fp="/etc/pam.d/$f"
    if [[ -f "$fp" ]] && grep -Eq 'pam_succeed_if\.so.*uid[[:space:]]*(>=|<)[[:space:]]*10000' "$fp"; then
        sed -i -E '/pam_succeed_if\.so.*uid[[:space:]]*(>=|<)[[:space:]]*10000/d' "$fp"
        log_ok "Stripped legacy biome-localguard line(s) from $fp"
    fi
done

# (f) Truncate hand-edits after `# end of pam-auth-update config`.
# pam-auth-update only manages the region between "# here are the per-package
# modules" and "# end of pam-auth-update config". Anything after the end-marker
# survives pam-auth-update runs — including rogue `pam_deny requisite` lines
# that reject local users. Drop everything past the end-marker.
for f in "${PAM_FILES[@]}"; do
    fp="/etc/pam.d/$f"
    if [[ -f "$fp" ]] && grep -q '^# end of pam-auth-update config' "$fp"; then
        awk '/^# end of pam-auth-update config/{print; found=1; next} found{next} {print}' "$fp" > "${fp}.tmp"
        if ! cmp -s "${fp}.tmp" "$fp"; then
            mv "${fp}.tmp" "$fp"
            chmod 0644 "$fp"
            log_ok "Truncated hand-edits after end-marker in $fp"
        else
            rm -f "${fp}.tmp"
        fi
    fi
done

# (g) Regenerate PAM stack
# We always use --force because the strip+truncate steps above created diffs
# vs /var/lib/pam/seen, which pam-auth-update would otherwise refuse on with
# "Local modifications to /etc/pam.d/common-*, not updating.".
log_info "Running pam-auth-update --force --package ..."
if ! DEBIAN_FRONTEND=noninteractive pam-auth-update --force --package; then
    log_error "pam-auth-update --force --package failed."
    log_warn  "Restore from $BACKUP_DIR if /etc/pam.d/common-* is broken."
    exit 1
fi
log_ok "PAM stack regenerated with --force."

# --- Post-check --------------------------------------------------------------
log_head "Post-check"
fail=0

# pam_krb5 absent everywhere
for f in "${PAM_FILES[@]}"; do
    if [[ -f "/etc/pam.d/$f" ]] && grep -Eq '^[^#]*pam_krb5\.so' "/etc/pam.d/$f"; then
        log_error "pam_krb5.so still active in /etc/pam.d/$f"
        fail=1
    fi
done
[[ $fail -eq 0 ]] && log_ok "pam_krb5.so absent from all common-* files (incl. common-account)."

# Legacy guard gone
for f in "${PAM_FILES[@]}"; do
    if [[ -f "/etc/pam.d/$f" ]] && grep -Eq 'pam_succeed_if\.so.*uid[[:space:]]*(>=|<)[[:space:]]*10000' "/etc/pam.d/$f"; then
        log_error "Legacy biome-localguard line still in /etc/pam.d/$f"
        fail=1
    fi
done

# Sanity: sudo must still work (it loads common-account).
if command -v sudo &>/dev/null; then
    if sudo -n true 2>/dev/null || [[ $EUID -eq 0 ]]; then
        log_ok "sudo/common-account loads cleanly."
    else
        sudo_err="$(sudo -n true 2>&1 || true)"
        if grep -q 'Module is unknown\|PAM.*error' <<<"$sudo_err"; then
            log_error "sudo PAM broken: $sudo_err"
            fail=1
        fi
    fi
fi

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
log_ok  "PAM stack cleaned in-place. Local-user 'passwd' is safe now."
log_info "Smoke test:   passwd ladmin               (expect normal prompt, no segfault)"
log_info "Smoke test:   sudo -u ladmin -i           (expect no 'Module is unknown')"
log_info "Rollback:     $0 --rollback"
log_info "Backup dir:   $BACKUP_DIR"
exit 0
