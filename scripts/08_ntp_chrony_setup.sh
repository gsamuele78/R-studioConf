#!/bin/bash
# 08_ntp_chrony_setup.sh - Unified NTP/chrony setup script
# Installs, configures, and restarts chrony/ntp/systemd-timesyncd as needed
# Uses process_template and backup logic from common_utils.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
UTILS_SCRIPT_PATH="${SCRIPT_DIR}/../lib/common_utils.sh"
CONF_VARS_FILE="${SCRIPT_DIR}/../config/ntp_chrony_setup.vars.conf"
TEMPLATE_DIR="${SCRIPT_DIR}/../templates"
CHRONY_CONF_PATH="/etc/chrony/chrony.conf"

if [[ ! -f "$UTILS_SCRIPT_PATH" ]]; then
    printf "Error: common_utils.sh not found at %s\n" "$UTILS_SCRIPT_PATH" >&2
    exit 1
fi
source "$UTILS_SCRIPT_PATH"

if [[ -f "$CONF_VARS_FILE" ]]; then
    log "Sourcing NTP/chrony configuration variables from $CONF_VARS_FILE"
    source "$CONF_VARS_FILE"
else
    log "Warning: NTP/chrony vars file not found; using embedded defaults."
    NTP_PREFERRED_CLIENT="chrony"
    CHRONY_CONF_PATH="/etc/chrony/chrony.conf"
    CHRONY_LOG_DIR="/var/log/chrony"
    CHRONY_DRIFTFILE="/var/lib/chrony/chrony.drift"
    CHRONY_MAKESTEP="1.0 3"
    CHRONY_RTC_SYNC="yes"
    CHRONY_FALLBACK_POOLS=("pool 2.debian.pool.ntp.org iburst")
    SYSTEMD_FALLBACK_NTP="0.debian.pool.ntp.org 1.debian.pool.ntp.org 2.debian.pool.ntp.org 3.debian.pool.ntp.org"
    NTP_CONF_PATH="/etc/ntp.conf"
    NTP_FALLBACK_SERVERS=("0.debian.pool.ntp.org" "1.debian.pool.ntp.org" "2.debian.pool.ntp.org" "3.debian.pool.ntp.org")
fi

install_ntp_client() {
    case "$NTP_PREFERRED_CLIENT" in
        chrony)
            run_command "apt-get update -y && apt-get install -y chrony" || return 1
            ;;
        ntp)
            run_command "apt-get update -y && apt-get install -y ntp" || return 1
            ;;
        systemd-timesyncd)
            run_command "systemctl enable systemd-timesyncd"
            run_command "systemctl start systemd-timesyncd"
            ;;
        *)
            log "ERROR: Unknown NTP client: $NTP_PREFERRED_CLIENT"
            return 1
            ;;
    esac
    return 0
}

generate_chrony_conf() {
    local out_var="$1"
    local fallback_pools_line=""
    if [[ -n "${CHRONY_FALLBACK_POOLS[*]}" ]]; then
        for pool in "${CHRONY_FALLBACK_POOLS[@]}"; do
            fallback_pools_line+="$pool\n"
        done
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
    run_command "chown root:root ${dest_path}" || true
    run_command "chmod 644 ${dest_path}" || true
    log "Chrony config deployed. Restarting chrony..."
    run_command "systemctl restart chrony" || log "Warning: restart may have failed; check service status"
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
    run_command "systemctl stop chrony ntp systemd-timesyncd" &>/dev/null || true
    run_command "systemctl disable chrony ntp systemd-timesyncd" &>/dev/null || true
    log "Removing packages..."
    local -a packages_to_remove=( chrony ntp systemd-timesyncd )
    local -a actually_installed_for_removal=()
    for pkg in "${packages_to_remove[@]}"; do
        if dpkg -s "$pkg" &>/dev/null; then
            actually_installed_for_removal+=("$pkg")
        fi
    done
    if [[ ${#actually_installed_for_removal[@]} -gt 0 ]]; then
        run_command "DEBIAN_FRONTEND=noninteractive apt-get remove --purge -y ${actually_installed_for_removal[*]}" && \
        run_command "DEBIAN_FRONTEND=noninteractive apt-get autoremove -y"
        log "Packages removed: ${actually_installed_for_removal[*]}"
    fi
    log "Cleaning chrony/ntp configs (backups kept in session backup dir)..."
    run_command "rm -rf /etc/chrony /etc/ntp.conf /etc/systemd/timesyncd.conf" || true
    log "Uninstall attempt complete. Review logs and backups in $CURRENT_BACKUP_DIR to restore if needed."
}

log "=== NTP/Chrony Setup Script Started ==="
main_menu
log "=== NTP/Chrony Setup Script Finished ==="
