#!/bin/bash
# 02_configure_time_sync.sh - Unified NTP/chrony setup script
# FIXED VERSION: Corrects newline handling in pool directive generation
# Installs, configures, and restarts chrony/ntp/systemd-timesyncd as needed
# Uses process_template and backup logic from common_utils.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
UTILS_SCRIPT_PATH="${SCRIPT_DIR}/../lib/common_utils.sh"

TEMPLATE_DIR="${SCRIPT_DIR}/../templates"
CHRONY_CONF_PATH="/etc/chrony/chrony.conf"

if [[ ! -f "$UTILS_SCRIPT_PATH" ]]; then
    printf "Error: common_utils.sh not found at %s\n" "$UTILS_SCRIPT_PATH" >&2
    exit 1
fi
source "$UTILS_SCRIPT_PATH"

# Docker Deploy: Source .env instead of legacy config
if [ -f "${SCRIPT_DIR}/../.env" ]; then
    log "INFO" "Sourcing configuration from .env..."
    set -a
    source "${SCRIPT_DIR}/../.env"
    set +a
else
    log "WARN" ".env file not found at ${SCRIPT_DIR}/../.env"
fi

# Set defaults if not present in .env
NTP_PREFERRED_CLIENT="${NTP_PREFERRED_CLIENT:-chrony}"
CHRONY_CONF_PATH="/etc/chrony/chrony.conf"
CHRONY_LOG_DIR="/var/log/chrony"
CHRONY_DRIFTFILE="/var/lib/chrony/chrony.drift"
CHRONY_MAKESTEP="${CHRONY_MAKESTEP:-1.0 3}"
CHRONY_RTC_SYNC="${CHRONY_RTC_SYNC:-yes}"

# Handle CHRONY_FALLBACK_POOLS (string in .env, array in script)
if [[ -n "$CHRONY_FALLBACK_POOLS" ]]; then
    IFS=' ' read -r -a CHRONY_FALLBACK_POOLS_ARRAY <<< "$CHRONY_FALLBACK_POOLS"
else
    CHRONY_FALLBACK_POOLS_ARRAY=("pool 2.debian.pool.ntp.org iburst")
fi

# FIXED: Separate apt-get commands instead of using && operators
# The run_command() function is designed for single apt operations
# Compound commands with && break the dpkg options parsing
install_ntp_client() {
    case "$NTP_PREFERRED_CLIENT" in
        chrony)
            log "Updating package lists..."
            run_command "Update package lists" "apt-get update" || return 1
            log "Installing chrony..."
            run_command "Install chrony" "apt-get install -y chrony" || return 1
            ;;
        ntp)
            log "Updating package lists..."
            run_command "Update package lists" "apt-get update" || return 1
            log "Installing ntp..."
            run_command "Install ntp" "apt-get install -y ntp" || return 1
            ;;
        systemd-timesyncd)
            log "Enabling systemd-timesyncd..."
            run_command "Enable systemd-timesyncd" "systemctl enable systemd-timesyncd" || return 1
            log "Starting systemd-timesyncd..."
            run_command "Start systemd-timesyncd" "systemctl start systemd-timesyncd" || return 1
            ;;
        *)
            log "ERROR: Unknown NTP client: $NTP_PREFERRED_CLIENT"
            return 1
            ;;
    esac
    return 0
}

# FIXED v2: Correct newline handling with $'\n' (ANSI-C quoting)
# This ensures pool directives are on separate lines, not as literal "\n"
generate_chrony_conf() {
    local out_var="$1"
    local fallback_pools_line=""
    
    # FIXED: Use $'\n' to create ACTUAL newlines, not literal "\n" characters
    if [[ -n "${CHRONY_FALLBACK_POOLS_ARRAY[*]}" ]]; then
        for pool in "${CHRONY_FALLBACK_POOLS_ARRAY[@]}"; do
            # Use $'\n' for real newline character (ANSI-C quoting)
            fallback_pools_line+="$pool"$'\n'
        done
        # Remove trailing newline to avoid extra blank line at end
        fallback_pools_line="${fallback_pools_line%$'\n'}"
    fi
    
    if ! process_template "${TEMPLATE_DIR}/chrony.conf.template" "$out_var" \
        DRIFTFILE="${CHRONY_DRIFTFILE}" \
        MAKESTEP="${CHRONY_MAKESTEP}" \
        RTC_SYNC="${CHRONY_RTC_SYNC}" \
        LOGDIR="${CHRONY_LOG_DIR}" \
        FALLBACK_POOLS="${fallback_pools_line}"; then
        log "ERROR: process_template failed for chrony.conf"
        return 1
    fi
    return 0
}

deploy_chrony_conf() {
    local content_var_name="$1"
    local dest_path="${CHRONY_CONF_PATH}"
    log "Deploying chrony config to ${dest_path} (backup existing if present)"
    if [[ -f "$dest_path" ]]; then
        _backup_item "$dest_path" "$CURRENT_BACKUP_DIR/etc/chrony" || log "Warning: failed to backup existing chrony.conf"
    fi
    if ! printf "%s" "${!content_var_name}" > "$dest_path"; then
        log "ERROR: Failed to write ${dest_path}"
        return 1
    fi
    run_command "Set chrony.conf ownership" "chown root:root ${dest_path}" || true
    run_command "Set chrony.conf permissions" "chmod 644 ${dest_path}" || true
    log "Chrony config deployed. Restarting chrony..."
    run_command "Restart chrony service" "systemctl restart chrony" || log "Warning: restart may have failed; check service status"
}

main_menu() {
    setup_backup_dir
    printf "\n=== NTP/Chrony Setup Menu ===\n"
    printf "1) Install preferred NTP client (%s)\n" "$NTP_PREFERRED_CLIENT"
    printf "2) Generate and deploy chrony.conf (from template)\n"
    printf "3) Full: install, generate & deploy chrony.conf\n"
    printf "U) Uninstall NTP/chrony configuration\n"
    printf "R) Restore configurations from most recent backup\n"
    printf "4) Exit\n"
    read -r -p "Choice: " choice
    local final_chrony=""
    case "$choice" in
        1)
            backup_config && install_ntp_client
            ;;
        2)
            generate_chrony_conf final_chrony || exit 1
            deploy_chrony_conf final_chrony
            ;;
        3)
            backup_config && install_ntp_client && generate_chrony_conf final_chrony && deploy_chrony_conf final_chrony
            ;;
        U|u)
            uninstall_ntp_chrony
            ;;
        R|r)
            restore_config
            ;;
        *)
            log "Exiting NTP/Chrony Setup."; return 0 ;;
    esac
}

uninstall_ntp_chrony() {
    log "Starting NTP/Chrony Uninstallation..."
    backup_config
    local confirm_uninstall
    read -r -p "This will remove chrony/ntp packages and clean configs. Continue? (y/n): " confirm_uninstall
    if [[ "$confirm_uninstall" != "y" && "$confirm_uninstall" != "Y" ]]; then
        log "Uninstallation cancelled."
        return 0
    fi
    log "Stopping NTP/chrony services..."
    run_command "Stop chrony/ntp services" "systemctl stop chrony ntp systemd-timesyncd" &>/dev/null || true
    run_command "Disable chrony/ntp services" "systemctl disable chrony ntp systemd-timesyncd" &>/dev/null || true
    
    log "Removing packages..."
    local -a packages_to_remove=( chrony ntp systemd-timesyncd )
    local -a actually_installed_for_removal=()
    for pkg in "${packages_to_remove[@]}"; do
        if dpkg -s "$pkg" &>/dev/null; then
            actually_installed_for_removal+=("$pkg")
        fi
    done
    
    if [[ ${#actually_installed_for_removal[@]} -gt 0 ]]; then
        log "Removing NTP/chrony packages: ${actually_installed_for_removal[*]}"
        run_command "Remove NTP/chrony packages" "apt-get remove --purge -y ${actually_installed_for_removal[*]}" && \
        run_command "Auto-remove unused dependencies" "apt-get autoremove -y"
        log "Packages removed: ${actually_installed_for_removal[*]}"
    fi
    
    log "Cleaning chrony/ntp configs (backups kept in session backup dir)..."
    run_command "Remove chrony/ntp config files" "rm -rf /etc/chrony /etc/ntp.conf /etc/systemd/timesyncd.conf" || true
    log "Uninstall attempt complete. Review logs and backups in $CURRENT_BACKUP_DIR to restore if needed."
}

log "=== NTP/Chrony Setup Script Started ==="
main_menu
