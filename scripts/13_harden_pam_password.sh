#!/bin/bash
# scripts/13_harden_pam_password.sh
#
# Hardens /etc/pam.d/common-password to prevent SIGSEGV on `passwd` for
# local users and removes pam_krb5 from the PAM stack.
#
# Actions (all idempotent):
#   1. Install biome-localguard pam-config (guards AD password stack for uid<10000)
#   2. Disable the 'krb5' pam-config profile if present (shipped by libpam-krb5)
#   3. Disable the 'ccreds' profile (optional; keeps libpam-ccreds installed for
#      'action=store' use via other profiles if any). Kept ENABLED by default
#      since ccreds non-primary modules do not crash.
#   4. Re-run `pam-auth-update --package` to regenerate common-auth/password/session
#
# This script is safe to re-run and is invoked automatically after
# 10_join_domain_sssd.sh or 11_join_domain_samba.sh. It must run AFTER the
# realm join so that libpam-sss / libpam-winbind are already installed.

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

# --- Paths --------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
readonly SCRIPT_DIR
readonly TEMPLATE_SRC="${SCRIPT_DIR}/../templates/pam-configs/biome-localguard.template"
readonly PAM_CONFIG_DST="/usr/share/pam-configs/biome-localguard"
readonly KRB5_PAM_CONFIG="/usr/share/pam-configs/krb5"

# --- Preflight ----------------------------------------------------------------
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    log_error "This script must be run as root."
    exit 1
fi

if ! command -v pam-auth-update &>/dev/null; then
    log_error "pam-auth-update not found (package libpam-runtime missing?)."
    exit 1
fi

if [[ ! -f "$TEMPLATE_SRC" ]]; then
    log_error "Template not found: $TEMPLATE_SRC"
    exit 1
fi

# --- 1. Backup current PAM files ---------------------------------------------
# NOTE: common-account MUST be included. It is referenced by /etc/pam.d/sudo,
# login, su, sshd — a dangling pam_krb5.so line there breaks sudo instantly
# ("PAM account management error: Module is unknown").
readonly PAM_FILES=(common-account common-auth common-password common-session common-session-noninteractive)
BACKUP_DIR="/root/pam-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
for f in "${PAM_FILES[@]}"; do
    if [[ -f "/etc/pam.d/$f" ]]; then
        cp -a "/etc/pam.d/$f" "$BACKUP_DIR/"
    fi
done
log_info "Backed up /etc/pam.d/common-* to $BACKUP_DIR"

# --- 1b. Pre-emptively strip dangling pam_krb5.so references -----------------
# libpam-krb5 is uninstalled by 12_lib_kerberos_setup.sh, but if hand-edits
# or an older deployment left a pam_krb5.so line in any common-*, the module
# load now fails ("Module is unknown"), breaking sudo/login/su before we even
# get to pam-auth-update. Strip such lines first.
for f in "${PAM_FILES[@]}"; do
    fp="/etc/pam.d/$f"
    if [[ -f "$fp" ]] && grep -Eq '^[^#]*pam_krb5\.so' "$fp"; then
        sed -i -E '/^[^#]*pam_krb5\.so/d' "$fp"
        log_warn "Stripped dangling pam_krb5.so from $fp"
    fi
done

# --- 2. Install biome-localguard profile --------------------------------------
log_info "Installing biome-localguard pam-config profile..."
install -m 0644 -o root -g root "$TEMPLATE_SRC" "$PAM_CONFIG_DST" || {
    log_error "Failed to install $PAM_CONFIG_DST"
    exit 1
}
log_ok "Installed $PAM_CONFIG_DST"

# --- 3. Remove pam_krb5 profile if present (segfault risk) --------------------
# libpam-krb5 should already be uninstalled by 12_lib_kerberos_setup.sh, but
# the /usr/share/pam-configs/krb5 file can linger. Remove it defensively.
if [[ -f "$KRB5_PAM_CONFIG" ]]; then
    log_warn "Found leftover $KRB5_PAM_CONFIG (libpam-krb5 pam-config)."
    log_info "Removing to prevent re-enable on pam-auth-update runs."
    rm -f "$KRB5_PAM_CONFIG"
    log_ok  "Removed $KRB5_PAM_CONFIG"
fi

# --- 4. Regenerate the PAM stack ---------------------------------------------
# --package: non-interactive default-profile refresh
# The ordering in the Primary block will become:
#   Priority 900: biome-localguard (uid>=10000 guard)
#   Priority 704: winbind  (if installed)
#   Priority 252: sss      (if installed)
#   Priority 256: unix     (always)
#
# pam-auth-update REFUSES to regenerate /etc/pam.d/common-* if it detects
# manual edits ("Local modifications to /etc/pam.d/common-*, not updating.").
# We capture stderr and, if we see that refusal, retry with --force after an
# extra backup. --force is safe here because we just installed the
# biome-localguard profile; the regenerated files will contain it.
PAU_ERR="$(mktemp)"
trap 'rm -f "$PAU_ERR"' EXIT
log_info "Regenerating PAM stack via pam-auth-update --package ..."
if ! DEBIAN_FRONTEND=noninteractive pam-auth-update --package 2> >(tee "$PAU_ERR" >&2); then
    log_error "pam-auth-update --package failed."
    log_warn  "Restore from $BACKUP_DIR if /etc/pam.d/common-* is broken."
    exit 1
fi

if grep -q 'Local modifications' "$PAU_ERR"; then
    log_warn "pam-auth-update refused: manual edits detected in /etc/pam.d/common-*."
    log_warn "Retrying with --force (extra backup already in $BACKUP_DIR)."
    if ! DEBIAN_FRONTEND=noninteractive pam-auth-update --force --package; then
        log_error "pam-auth-update --force --package failed."
        log_warn  "Restore from $BACKUP_DIR if /etc/pam.d/common-* is broken."
        exit 1
    fi
    log_ok "PAM stack regenerated with --force."
else
    log_ok "PAM stack regenerated."
fi

# --- 5. Sanity check ----------------------------------------------------------
# Verify the guard line was injected into common-password
if grep -Eq 'pam_succeed_if\.so.*uid[[:space:]]*>=[[:space:]]*10000' /etc/pam.d/common-password; then
    log_ok "common-password contains 'pam_succeed_if uid >= 10000' guard."
else
    log_error "Guard NOT present in /etc/pam.d/common-password after pam-auth-update."
    log_warn  "Check /usr/share/pam-configs/ for conflicting profiles."
    exit 1
fi

# Verify pam_krb5 is NOT in ANY common-* (crash risk + sudo breakage risk)
for f in "${PAM_FILES[@]}"; do
    if [[ -f "/etc/pam.d/$f" ]] && grep -Eq '^[^#]*pam_krb5\.so' "/etc/pam.d/$f"; then
        log_error "pam_krb5.so is STILL active in /etc/pam.d/$f"
        log_warn  "Was libpam-krb5 re-installed after 12_lib_kerberos_setup.sh?"
        exit 1
    fi
done
log_ok "pam_krb5.so is absent from all common-* files (incl. common-account)."

log_ok "PAM password stack hardened successfully."
log_info "Backup of previous stack: $BACKUP_DIR"
exit 0
