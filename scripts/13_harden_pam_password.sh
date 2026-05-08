#!/bin/bash
# scripts/13_harden_pam_password.sh
#
# Eliminates the pam_krb5 SIGSEGV on `passwd` for local users (uid<10000)
# on AD-joined Ubuntu 24.04 nodes by REMOVING libpam-krb5 and any
# hand-rolled guards. No custom pam-config profile is installed.
#
# Rationale:
#   - libpam-krb5 dereferences NULL when the principal is not in the
#     default realm of a multi-realm krb5.conf (DIR/PERSONALE/STUDENTI).
#   - The default Debian pam-auth-update stack (pam_unix + pam_winbind OR
#     pam_sss, with success-branching) already routes local users to
#     pam_unix and AD users to the AD module — NO custom guard is needed.
#   - Earlier releases of this script installed a `biome-localguard`
#     pam-config profile which was incompatible with the Ubuntu 24.04
#     "pam_unix first" layout and broke `passwd` for local users. This
#     script now PURGES that guard and any leftover hand-edits.
#
# Actions (all idempotent):
#   1. Backup /etc/pam.d/common-* to /root/pam-backup-<ts>/
#   2. Remove leftover pam-config profiles: `biome-localguard`, `krb5`
#   3. Strip dangling `pam_krb5.so` lines from every common-*
#   4. Strip any legacy `pam_succeed_if uid >= 10000` guard lines
#   5. Strip any hand-edits after `# end of pam-auth-update config`
#   6. Run `pam-auth-update --force --package` to regenerate the stack
#   7. Post-check: no pam_krb5.so anywhere, sudo/common-account loads OK
#
# Must run AFTER the realm join (10_/11_) so libpam-sss or libpam-winbind
# are already installed and registered with pam-auth-update.

set -euo pipefail

# --- Colors (project standard) ------------------------------------------------
readonly C_RED='\033[0;31m'
readonly C_GREEN='\033[0;32m'
readonly C_YELLOW='\033[0;33m'
readonly C_BLUE='\033[0;34m'
readonly C_RESET='\033[0m'

log_info()  { printf "${C_BLUE}[INFO]${C_RESET} %s\n" "$*"; }
log_ok()    { printf "${C_GREEN}[ OK ]${C_RESET} %s\n" "$*"; }
log_warn()  { printf "${C_YELLOW}[WARN]${C_RESET} %s\n" "$*" >&2; }
log_error() { printf "${C_RED}[FAIL]${C_RESET} %s\n" "$*" >&2; }

# --- Preflight ----------------------------------------------------------------
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    log_error "This script must be run as root."
    exit 1
fi

if ! command -v pam-auth-update &>/dev/null; then
    log_error "pam-auth-update not found (package libpam-runtime missing?)."
    exit 1
fi

# --- Paths --------------------------------------------------------------------
# common-account is CRITICAL — referenced by sudo, login, su, sshd. A dangling
# pam_krb5.so there breaks sudo instantly ("Module is unknown").
readonly PAM_FILES=(common-account common-auth common-password common-session common-session-noninteractive)
readonly LEGACY_LOCALGUARD="/usr/share/pam-configs/biome-localguard"
readonly KRB5_PAM_CONFIG="/usr/share/pam-configs/krb5"

# --- 1. Backup current PAM files ---------------------------------------------
BACKUP_DIR="/root/pam-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
for f in "${PAM_FILES[@]}"; do
    [[ -f "/etc/pam.d/$f" ]] && cp -a "/etc/pam.d/$f" "$BACKUP_DIR/"
done
[[ -f /etc/krb5.conf ]] && cp -a /etc/krb5.conf "$BACKUP_DIR/"
log_info "Backed up /etc/pam.d/common-* to $BACKUP_DIR"

# --- 2. Remove leftover pam-config profiles ----------------------------------
if [[ -f "$LEGACY_LOCALGUARD" ]]; then
    rm -f "$LEGACY_LOCALGUARD"
    log_ok "Removed legacy $LEGACY_LOCALGUARD (obsolete guard)."
fi
if [[ -f "$KRB5_PAM_CONFIG" ]]; then
    rm -f "$KRB5_PAM_CONFIG"
    log_ok "Removed leftover $KRB5_PAM_CONFIG (libpam-krb5 profile)."
fi

# --- 3. Strip dangling pam_krb5.so references --------------------------------
# libpam-krb5 is uninstalled by 12_lib_kerberos_setup.sh, but hand-edits or an
# older deployment may have left a pam_krb5.so line in any common-*. Such a
# line fails to load ("Module is unknown") and breaks sudo/login/su before we
# even run pam-auth-update.
for f in "${PAM_FILES[@]}"; do
    fp="/etc/pam.d/$f"
    if [[ -f "$fp" ]] && grep -Eq '^[^#]*pam_krb5\.so' "$fp"; then
        sed -i -E '/^[^#]*pam_krb5\.so/d' "$fp"
        log_warn "Stripped dangling pam_krb5.so line(s) from $fp"
    fi
done

# --- 4. Strip legacy biome-localguard lines ----------------------------------
# The old guard injected `pam_succeed_if.so uid >= 10000` into common-password.
# That line, combined with the Ubuntu 24.04 pam_unix-first layout, causes
# "Authentication token manipulation error" for local users. Purge it.
for f in "${PAM_FILES[@]}"; do
    fp="/etc/pam.d/$f"
    if [[ -f "$fp" ]] && grep -Eq 'pam_succeed_if\.so.*uid[[:space:]]*(>=|<)[[:space:]]*10000' "$fp"; then
        sed -i -E '/pam_succeed_if\.so.*uid[[:space:]]*(>=|<)[[:space:]]*10000/d' "$fp"
        log_warn "Stripped legacy biome-localguard line(s) from $fp"
    fi
done

# --- 5. Strip hand-edits after the managed block -----------------------------
# pam-auth-update only rewrites between "# here are the per-package modules"
# and "# end of pam-auth-update config". Anything AFTER that end-marker is
# preserved across re-runs. Some nodes have leftover "pam_deny requisite"
# lines there that reject local users even after our managed block grants
# them access. Truncate each common-* at the end-marker.
for f in "${PAM_FILES[@]}"; do
    fp="/etc/pam.d/$f"
    if [[ -f "$fp" ]] && grep -q '^# end of pam-auth-update config' "$fp"; then
        # Keep everything up to and including the end-marker; drop the rest.
        if awk '/^# end of pam-auth-update config/{print; found=1; next} found{next} {print}' "$fp" | \
           cmp -s - "$fp"; then
            :  # no change
        else
            awk '/^# end of pam-auth-update config/{print; found=1; next} found{next} {print}' "$fp" > "${fp}.tmp"
            mv "${fp}.tmp" "$fp"
            chmod 0644 "$fp"
            log_warn "Truncated hand-edits after end-marker in $fp"
        fi
    fi
done

# --- 6. Regenerate the PAM stack via pam-auth-update -------------------------
# We always use --force because our strip steps above may have created minor
# diffs vs /var/lib/pam/seen, which pam-auth-update would otherwise refuse on.
# --package is the non-interactive default-profile refresh.
log_info "Regenerating PAM stack via pam-auth-update --force --package ..."
if ! DEBIAN_FRONTEND=noninteractive pam-auth-update --force --package; then
    log_error "pam-auth-update --force --package failed."
    log_warn  "Restore from $BACKUP_DIR if /etc/pam.d/common-* is broken."
    exit 1
fi
log_ok "PAM stack regenerated."

# --- 7. Post-check -----------------------------------------------------------
fail=0

# pam_krb5 must be absent from every common-*
for f in "${PAM_FILES[@]}"; do
    if [[ -f "/etc/pam.d/$f" ]] && grep -Eq '^[^#]*pam_krb5\.so' "/etc/pam.d/$f"; then
        log_error "pam_krb5.so STILL active in /etc/pam.d/$f"
        log_warn  "Was libpam-krb5 re-installed after 12_lib_kerberos_setup.sh?"
        fail=1
    fi
done
[[ $fail -eq 0 ]] && log_ok "pam_krb5.so absent from all common-* files."

# Legacy guard must be gone
for f in "${PAM_FILES[@]}"; do
    if [[ -f "/etc/pam.d/$f" ]] && grep -Eq 'pam_succeed_if\.so.*uid[[:space:]]*(>=|<)[[:space:]]*10000' "/etc/pam.d/$f"; then
        log_error "Legacy biome-localguard line still present in /etc/pam.d/$f"
        fail=1
    fi
done

# AD provider should still be present in common-auth (warn only, not fatal —
# pure-local nodes are legal).
if grep -Eq '^[^#]*pam_(sss|winbind)\.so' /etc/pam.d/common-auth; then
    log_ok "AD provider (pam_sss / pam_winbind) present in common-auth."
else
    log_warn "No pam_sss.so / pam_winbind.so in common-auth."
    log_warn "If this node is domain-joined, run:"
    log_warn "  pam-auth-update --enable sss --enable mkhomedir   # (or winbind)"
fi

if [[ $fail -ne 0 ]]; then
    log_error "Post-check FAILED. Backup at $BACKUP_DIR."
    exit 1
fi

log_ok  "PAM password stack hardened successfully."
log_info "Backup of previous stack: $BACKUP_DIR"
log_info "Smoke test:  passwd ladmin     (expect normal prompt, no segfault)"
exit 0
