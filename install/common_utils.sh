#!/bin/bash
# common_utils.sh - Common utilities for RStudio, Nginx, and SSSD setup scripts

# Ensure script is run with root privileges
if [[ "$(id -u)" -ne 0 ]]; then
  echo "This script must be run as root. Please use sudo." >&2
  exit 1
fi

# --- CONFIGURATION VARIABLES ---
LOG_FILE="/var/log/rstudio_nginx_sssd_setup.log"
BACKUP_DIR_BASE="/tmp/config_backups"
# --- END CONFIGURATION VARIABLES ---

CURRENT_BACKUP_DIR="" # Holds unique backup path for current script execution

# Logging function
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Function to run commands, log them, and check for errors
run_command() {
    local cmd="$1" # Capture command for logging
    log "Executing: ${cmd}"
    # Execute command, append stdout and stderr to LOG_FILE
    # Command output also goes to script's stdout/stderr for real-time feedback
    if bash -c "${cmd}" >>"$LOG_FILE" 2>&1; then
        log "SUCCESS: ${cmd}"
        return 0
    else
        local exit_code=$?
        log "ERROR (Exit Code: ${exit_code}): CMD FAILED: '${cmd}'. Details in ${LOG_FILE}"
        return "${exit_code}"
    fi
}

# Sets up a unique backup directory for the current session
setup_backup_dir() {
    if [[ -z "$CURRENT_BACKUP_DIR" ]]; then # Only set it up once per script run
        CURRENT_BACKUP_DIR="${BACKUP_DIR_BASE}_$(date +%Y%m%d_%H%M%S)"
        if ! mkdir -p "$CURRENT_BACKUP_DIR"; then
            log "FATAL: Could not create backup directory $CURRENT_BACKUP_DIR. Exiting."
            exit 1 # Critical failure
        fi
        log "Backup directory for this session: $CURRENT_BACKUP_DIR"
    fi
}

# Helper to backup a single item (file or directory)
_backup_item() {
    local src_path="$1"
    local dest_parent_dir="$2" # Parent directory within CURRENT_BACKUP_DIR
    local cp_opts="-aL"        # Archive mode, follow symlinks for files to get actual content

    if [[ ! -e "$src_path" ]]; then
        return 0 # Source doesn't exist, nothing to backup
    fi
    
    if ! cp ${cp_opts} "${src_path}" "${dest_parent_dir}/" 2>/dev/null; then # Capture errors
        log "Warning: Could not backup '${src_path}' to '${dest_parent_dir}/'"
    fi
}

# Main backup function
backup_config() {
    if [[ -z "$CURRENT_BACKUP_DIR" ]]; then
        log "Error: Backup directory not set. Call setup_backup_dir first."
        return 1
    fi
    log "Creating backup of configuration files to $CURRENT_BACKUP_DIR..."

    mkdir -p \
        "$CURRENT_BACKUP_DIR/etc/nginx/sites-available" \
        "$CURRENT_BACKUP_DIR/etc/nginx/snippets" \
        "$CURRENT_BACKUP_DIR/etc/rstudio" \
        "$CURRENT_BACKUP_DIR/etc/R" \
        "$CURRENT_BACKUP_DIR/etc/ssl/private" \
        "$CURRENT_BACKUP_DIR/etc/ssl/certs" \
        "$CURRENT_BACKUP_DIR/etc/profile.d" \
        "$CURRENT_BACKUP_DIR/etc/sssd" \
        "$CURRENT_BACKUP_DIR/etc/pam.d" \
        "$CURRENT_BACKUP_DIR/etc"

    _backup_item "/etc/nginx/sites-available" "$CURRENT_BACKUP_DIR/etc/nginx"
    _backup_item "/etc/nginx/snippets" "$CURRENT_BACKUP_DIR/etc/nginx"
    _backup_item "/etc/nginx/dhparam.pem" "$CURRENT_BACKUP_DIR/etc/nginx"
    _backup_item "/etc/nginx/nginx.conf" "$CURRENT_BACKUP_DIR/etc/nginx"
    _backup_item "/etc/rstudio/rserver.conf" "$CURRENT_BACKUP_DIR/etc/rstudio"
    _backup_item "/etc/rstudio/rsession.conf" "$CURRENT_BACKUP_DIR/etc/rstudio"
    _backup_item "/etc/rstudio/logging.conf" "$CURRENT_BACKUP_DIR/etc/rstudio"
    _backup_item "/etc/rstudio/env-vars" "$CURRENT_BACKUP_DIR/etc/rstudio"
    _backup_item "/etc/R/Renviron.site" "$CURRENT_BACKUP_DIR/etc/R"
    _backup_item "/etc/R/Rprofile.site" "$CURRENT_BACKUP_DIR/etc/R"
    _backup_item "/etc/ssl/private/nginx-selfsigned.key" "$CURRENT_BACKUP_DIR/etc/ssl/private"
    _backup_item "/etc/ssl/certs/nginx-selfsigned.crt" "$CURRENT_BACKUP_DIR/etc/ssl/certs"
    _backup_item "/etc/profile.d/00_rstudio_user_logins.sh" "$CURRENT_BACKUP_DIR/etc/profile.d"
    _backup_item "/etc/sssd/sssd.conf" "$CURRENT_BACKUP_DIR/etc/sssd"
    _backup_item "/etc/krb5.conf" "$CURRENT_BACKUP_DIR/etc"
    _backup_item "/etc/nsswitch.conf" "$CURRENT_BACKUP_DIR/etc"
    _backup_item "/etc/pam.d" "$CURRENT_BACKUP_DIR/etc/"

    log "Backup completed at $CURRENT_BACKUP_DIR"
}

_restore_item() {
    local backup_src_path="$1"
    local dest_target="$2"
    local dest_parent_dir

    if [[ ! -e "$backup_src_path" ]]; then return 0; fi

    if [[ -d "$backup_src_path" ]]; then
        dest_parent_dir="$(dirname "$dest_target")"
        mkdir -p "$dest_parent_dir"
        if [[ -d "$dest_target" ]]; then rm -rf "$dest_target"; elif [[ -f "$dest_target" ]]; then rm -f "$dest_target"; fi
        if ! cp -a "$backup_src_path" "$dest_target" 2>/dev/null; then
             log "Warning: Could not restore directory '$backup_src_path' to '$dest_target'"
        fi
    else # Source is a file
        dest_parent_dir="$(dirname "$dest_target")"
        mkdir -p "$dest_parent_dir"
        if ! cp -a "$backup_src_path" "$dest_target" 2>/dev/null; then
            log "Warning: Could not restore file '$backup_src_path' to '$dest_target'"
        fi
    fi
}

restore_config() {
    log "Attempting to restore configuration files from backup..."
    local latest_backup
    latest_backup=$(ls -td "${BACKUP_DIR_BASE}_"* 2>/dev/null | head -1)

    if [[ -z "$latest_backup" ]]; then log "No backup found in $BACKUP_DIR_BASE. Nothing to restore."; return 1; fi

    read -r -p "Restore from most recent backup: $latest_backup? (y/n): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then log "Restore cancelled."; return 0; fi

    log "Restoring from $latest_backup..."
    _restore_item "$latest_backup/etc/nginx/sites-available" "/etc/nginx/sites-available"
    _restore_item "$latest_backup/etc/nginx/snippets" "/etc/nginx/snippets"
    _restore_item "$latest_backup/etc/nginx/dhparam.pem" "/etc/nginx/dhparam.pem"
    _restore_item "$latest_backup/etc/nginx/nginx.conf" "/etc/nginx/nginx.conf"
    _restore_item "$latest_backup/etc/rstudio/rserver.conf" "/etc/rstudio/rserver.conf"
    _restore_item "$latest_backup/etc/rstudio/rsession.conf" "/etc/rstudio/rsession.conf"
    _restore_item "$latest_backup/etc/rstudio/logging.conf" "/etc/rstudio/logging.conf"
    _restore_item "$latest_backup/etc/rstudio/env-vars" "/etc/rstudio/env-vars"
    _restore_item "$latest_backup/etc/R/Renviron.site" "/etc/R/Renviron.site"
    _restore_item "$latest_backup/etc/R/Rprofile.site" "/etc/R/Rprofile.site"
    _restore_item "$latest_backup/etc/ssl/private/nginx-selfsigned.key" "/etc/ssl/private/nginx-selfsigned.key"
    _restore_item "$latest_backup/etc/ssl/certs/nginx-selfsigned.crt" "/etc/ssl/certs/nginx-selfsigned.crt"
    _restore_item "$latest_backup/etc/profile.d/00_rstudio_user_logins.sh" "/etc/profile.d/00_rstudio_user_logins.sh"
    _restore_item "$latest_backup/etc/sssd/sssd.conf" "/etc/sssd/sssd.conf"
    _restore_item "$latest_backup/etc/krb5.conf" "/etc/krb5.conf"
    _restore_item "$latest_backup/etc/nsswitch.conf" "/etc/nsswitch.conf"
    _restore_item "$latest_backup/etc/pam.d" "/etc/pam.d"

    log "Configuration files restored from $latest_backup."
    log "Restarting services if they are installed..."
    local services_to_restart=()
    if command -v sssd &>/dev/null && systemctl list-units --full -all | grep -q 'sssd.service'; then services_to_restart+=("sssd"); fi
    if command -v rstudio-server &>/dev/null && systemctl list-units --full -all | grep -q 'rstudio-server.service'; then services_to_restart+=("rstudio-server"); fi
    if command -v nginx &>/dev/null && systemctl list-units --full -all | grep -q 'nginx.service'; then services_to_restart+=("nginx"); fi
    
    if [[ ${#services_to_restart[@]} -gt 0 ]]; then
        for service_name in "${services_to_restart[@]}"; do
            run_command "systemctl restart ${service_name}"
        done
    else log "No relevant services found to restart."; fi
    return 0
}

add_line_if_not_present() {
    local line_content="$1"
    local target_file="$2"
    ensure_file_exists "$target_file" || return 1
    # Use F grep for fixed string, x for exact line match, q for quiet
    if ! grep -qxF "$line_content" "$target_file"; then
        # Shellcheck SC2028: echo may interpret backslashes, use printf.
        printf "%s\n" "$line_content" >> "$target_file"
    fi
}

ensure_dir_exists() {
    local dir_path="$1"
    if [[ ! -d "$dir_path" ]]; then
        run_command "mkdir -p \"$dir_path\"" || return 1
        log "Ensured directory exists: $dir_path"
    fi
    return 0
}

ensure_file_exists() {
    local file_path="$1"
    ensure_dir_exists "$(dirname "$file_path")" || return 1
    if [[ ! -f "$file_path" ]]; then
        run_command "touch \"$file_path\"" || return 1
        log "Ensured file exists: $file_path"
    fi
    return 0
}
