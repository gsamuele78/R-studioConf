#!/bin/bash
# common_utils.sh - Common utilities for RStudio, Nginx, and SSSD setup scripts
# This script provides shared functions for logging, command execution, backups,
# file/directory manipulation, and template processing.
# It should be sourced by the main setup scripts.

# Ensure script is run with root privileges
if [[ "$(id -u)" -ne 0 ]]; then
  # Using printf for stderr is good practice
  printf "Error: This script must be run as root. Please use sudo.\n" >&2
  exit 1
fi

# --- CONFIGURATION VARIABLES (Internal to common_utils) ---
# Log file for all operations
LOG_FILE="/var/log/rstudio_nginx_sssd_setup.log"
# Base directory for configuration backups
BACKUP_DIR_BASE="/tmp/config_backups_$(date +%Y%m%d)" # Group backups by day
# --- END CONFIGURATION VARIABLES ---

# Global variable to hold the unique backup directory path for the current script execution session
CURRENT_BACKUP_DIR=""

# Logging function
# Usage: log "Your log message here"
log() {
    # Using printf for safer output, especially if $1 might contain %
    # Appends timestamp and message to LOG_FILE and prints to stdout.
    printf "%s - %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$1" | tee -a "$LOG_FILE"
}

# Function to run commands, log them, and check for errors
# Usage: run_command "your_command -with --args"
# Returns 0 on success, command's exit code on failure.
run_command() {
    local cmd="$1" # Capture command for logging and execution
    log "Executing: ${cmd}"
    # Execute command in a subshell to avoid variable conflicts and ensure clean state.
    # Redirects stdout and stderr of the command to the LOG_FILE.
    # Output is also sent to the script's stdout/stderr for real-time feedback via tee in log().
    if (bash -c "${cmd}") >>"$LOG_FILE" 2>&1; then
        log "SUCCESS: ${cmd}"
        return 0
    else
        local exit_code=$?
        log "ERROR (Exit Code: ${exit_code}): CMD FAILED: '${cmd}'. Details in ${LOG_FILE}"
        return "${exit_code}" # Return the actual exit code of the failed command
    fi
}

# Sets up a unique backup directory for the current session
# Creates a timestamped directory under BACKUP_DIR_BASE.
# This function is idempotent; it only creates the directory once per script run.
setup_backup_dir() {
    if [[ -z "$CURRENT_BACKUP_DIR" ]]; then
        # Create a unique subdirectory for this specific execution instance
        CURRENT_BACKUP_DIR="${BACKUP_DIR_BASE}/run_$(date +%Y%m%d_%H%M%S)"
        if ! mkdir -p "$CURRENT_BACKUP_DIR"; then
            log "FATAL: Could not create backup directory $CURRENT_BACKUP_DIR. Exiting."
            exit 1 # Critical failure
        fi
        log "Backup directory for this session: $CURRENT_BACKUP_DIR"
    fi
}

# Helper to backup a single item (file or directory)
# _backup_item "/path/to/source" "/path/to/backup_parent_destination"
_backup_item() {
    local src_path="$1"
    local dest_parent_dir="$2" # Parent directory within CURRENT_BACKUP_DIR
    # -a: archive mode (preserves permissions, ownership, timestamps, recursive for dirs)
    # -L: follow symbolic links for files (copies the actual file content)
    local cp_opts="-aL"

    if [[ ! -e "$src_path" ]]; then
        # log "Info: Source '${src_path}' does not exist, skipping backup of this item." # Can be verbose
        return 0 # Source doesn't exist, nothing to backup
    fi
    
    # Ensure the destination parent directory within the backup structure exists
    # This should have been created by the main backup_config function's mkdir -p calls.
    # Adding a check here for robustness.
    if ! mkdir -p "$dest_parent_dir"; then
        log "Warning: Could not create backup sub-directory '${dest_parent_dir}' for '${src_path}'"
        return 1
    fi

    # Using 2>/dev/null to suppress cp errors from appearing on stdout directly,
    # as run_command is not used here (to avoid recursive logging of cp itself).
    # The log function will report the warning.
    if ! cp ${cp_opts} "${src_path}" "${dest_parent_dir}/" 2>/dev/null; then
        log "Warning: Could not backup '${src_path}' to '${dest_parent_dir}/'"
    fi
}

# Main backup function - Call this before making significant changes.
# It defines the structure within CURRENT_BACKUP_DIR and copies files/dirs.
backup_config() {
    if [[ -z "$CURRENT_BACKUP_DIR" ]]; then
        log "Error: Backup directory not set. Call setup_backup_dir first."
        return 1
    fi
    log "Creating backup of configuration files to $CURRENT_BACKUP_DIR..."

    # Create the expected directory structure within the unique backup folder
    # This helps organize the backed-up files similar to their original locations.
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
        "$CURRENT_BACKUP_DIR/etc" \
        "$CURRENT_BACKUP_DIR/script_configs/conf" \
        "$CURRENT_BACKUP_DIR/script_configs/templates"

    # Backup specific system files and directories
    _backup_item "/etc/nginx/sites-available" "$CURRENT_BACKUP_DIR/etc/nginx"
    _backup_item "/etc/nginx/snippets" "$CURRENT_BACKUP_DIR/etc/nginx"
    _backup_item "/etc/nginx/dhparam.pem" "$CURRENT_BACKUP_DIR/etc/nginx" # Target specific file
    _backup_item "/etc/nginx/nginx.conf" "$CURRENT_BACKUP_DIR/etc/nginx"  # Target nginx.conf in /etc/nginx
    _backup_item "/etc/rstudio/rserver.conf" "$CURRENT_BACKUP_DIR/etc/rstudio"
    _backup_item "/etc/rstudio/rsession.conf" "$CURRENT_BACKUP_DIR/etc/rstudio"
    _backup_item "/etc/rstudio/logging.conf" "$CURRENT_BACKUP_DIR/etc/rstudio"
    _backup_item "/etc/rstudio/env-vars" "$CURRENT_BACKUP_DIR/etc/rstudio"
    _backup_item "/etc/R/Renviron.site" "$CURRENT_BACKUP_DIR/etc/R"
    _backup_item "/etc/R/Rprofile.site" "$CURRENT_BACKUP_DIR/etc/R"
    _backup_item "/etc/ssl/private/nginx-selfsigned.key" "$CURRENT_BACKUP_DIR/etc/ssl/private" # Example self-signed key
    _backup_item "/etc/ssl/certs/nginx-selfsigned.crt" "$CURRENT_BACKUP_DIR/etc/ssl/certs"   # Example self-signed cert
    _backup_item "/etc/profile.d/00_rstudio_user_logins.sh" "$CURRENT_BACKUP_DIR/etc/profile.d" # Example only, script uses var
    _backup_item "/etc/sssd/sssd.conf" "$CURRENT_BACKUP_DIR/etc/sssd"
    _backup_item "/etc/krb5.conf" "$CURRENT_BACKUP_DIR/etc"
    _backup_item "/etc/nsswitch.conf" "$CURRENT_BACKUP_DIR/etc"
    _backup_item "/etc/pam.d" "$CURRENT_BACKUP_DIR/etc/" # Backup entire pam.d directory

    # Backup script's own conf and template directories.
    # SCRIPT_DIR must be defined in the calling script.
    if [[ -n "$SCRIPT_DIR" ]]; then
        if [[ -d "${SCRIPT_DIR}/conf" ]]; then
            _backup_item "${SCRIPT_DIR}/conf" "$CURRENT_BACKUP_DIR/script_configs"
        fi
        if [[ -d "${SCRIPT_DIR}/templates" ]]; then
            _backup_item "${SCRIPT_DIR}/templates" "$CURRENT_BACKUP_DIR/script_configs"
        fi
    else
        log "Warning: SCRIPT_DIR not defined in calling script; cannot backup script's local conf/template dirs."
    fi

    log "Backup completed at $CURRENT_BACKUP_DIR"
}

# Helper to restore a single item (file or directory) from backup
# _restore_item "/path/in/backup/to/source_item" "/actual/system/destination_path"
_restore_item() {
    local backup_src_path="$1"
    local dest_target="$2"
    local dest_parent_dir

    if [[ ! -e "$backup_src_path" ]]; then return 0; fi # Source in backup doesn't exist

    dest_parent_dir="$(dirname "$dest_target")"
    # Ensure destination parent directory exists on the system
    if ! mkdir -p "$dest_parent_dir"; then
        log "Warning: Could not create system directory '${dest_parent_dir}' for restore."
        return 1
    fi

    # If restoring a directory, remove the existing one on the system first
    # to ensure a clean restore rather than a merge.
    if [[ -d "$backup_src_path" ]]; then # If source in backup is a directory
        if [[ -d "$dest_target" ]]; then
            if ! rm -rf "$dest_target"; then log "Warning: Could not remove existing system directory '$dest_target'"; return 1; fi
        elif [[ -f "$dest_target" ]]; then # If destination is a file but source is dir
            if ! rm -f "$dest_target"; then log "Warning: Could not remove existing system file '$dest_target'"; return 1; fi
        fi
        # Now copy the directory from backup
        if ! cp -a "$backup_src_path" "$dest_target" 2>/dev/null; then
             log "Warning: Could not restore directory '$backup_src_path' to '$dest_target'"
        fi
    else # Source in backup is a file
        # If destination is a directory but source is a file, this will error or behave unexpectedly.
        # Assume dest_target is the full path to the file.
        if ! cp -a "$backup_src_path" "$dest_target" 2>/dev/null; then
            log "Warning: Could not restore file '$backup_src_path' to '$dest_target'"
        fi
    fi
}

# Main restore function - Restores from the most recent backup.
restore_config() {
    log "Attempting to restore configuration files from backup..."
    local latest_backup
    # Find the most recent backup directory within the daily grouped folder
    latest_backup=$(ls -td "${BACKUP_DIR_BASE}"/run_* 2>/dev/null | head -1)

    if [[ -z "$latest_backup" ]]; then
        log "No backup found in ${BACKUP_DIR_BASE}/run_*. Nothing to restore."
        return 1
    fi

    read -r -p "Restore from most recent backup: $latest_backup? (y/n): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        log "Restore cancelled."
        return 0
    fi

    log "Restoring from $latest_backup..."

    # Restore system files (adjust paths as needed based on what backup_config saves)
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
    # Use actual paths from nginx_setup.vars.conf if they were customized
    _restore_item "$latest_backup/etc/ssl/private/nginx-rstudio-selfsigned.key" "/etc/ssl/private/nginx-rstudio-selfsigned.key"
    _restore_item "$latest_backup/etc/ssl/certs/nginx-rstudio-selfsigned.crt" "/etc/ssl/certs/nginx-rstudio-selfsigned.crt"
    _restore_item "$latest_backup/etc/profile.d/00_rstudio_user_logins.sh" "/etc/profile.d/00_rstudio_user_logins.sh" # Update if var used
    _restore_item "$latest_backup/etc/sssd/sssd.conf" "/etc/sssd/sssd.conf"
    _restore_item "$latest_backup/etc/krb5.conf" "/etc/krb5.conf"
    _restore_item "$latest_backup/etc/nsswitch.conf" "/etc/nsswitch.conf"
    _restore_item "$latest_backup/etc/pam.d" "/etc/pam.d" # Restores entire pam.d directory

    # Restore script's own conf and template dirs if present in backup
    # SCRIPT_DIR must be defined in the calling script.
    if [[ -n "$SCRIPT_DIR" ]]; then
        if [[ -d "$latest_backup/script_configs/conf" ]]; then
            _restore_item "$latest_backup/script_configs/conf" "${SCRIPT_DIR}/conf"
        fi
        if [[ -d "$latest_backup/script_configs/templates" ]]; then
            _restore_item "$latest_backup/script_configs/templates" "${SCRIPT_DIR}/templates"
        fi
    else
        log "Warning: SCRIPT_DIR not defined; cannot restore script's local conf/template dirs."
    fi

    log "Configuration files restored from $latest_backup."
    log "Restarting services if they are installed..."
    local -a services_to_restart=() # Use -a for array declaration
    if command -v sssd &>/dev/null && systemctl list-units --full -all | grep -q 'sssd.service'; then services_to_restart+=("sssd"); fi
    if command -v rstudio-server &>/dev/null && systemctl list-units --full -all | grep -q 'rstudio-server.service'; then services_to_restart+=("rstudio-server"); fi
    if command -v nginx &>/dev/null && systemctl list-units --full -all | grep -q 'nginx.service'; then services_to_restart+=("nginx"); fi
    
    if [[ ${#services_to_restart[@]} -gt 0 ]]; then
        for service_name in "${services_to_restart[@]}"; do
            run_command "systemctl restart ${service_name}"
        done
    else
        log "No relevant services found to restart."
    fi
    return 0
}

# Helper to add a line to a file if it's not already present (exact match)
# add_line_if_not_present "line to add" "/path/to/file"
add_line_if_not_present() {
    local line_content="$1"
    local target_file="$2"
    ensure_file_exists "$target_file" || return 1 # Ensure file and its directory exist
    # Use grep -F (fixed string), -x (exact line), -q (quiet)
    if ! grep -qFx "$line_content" "$target_file"; then
        # Shellcheck SC2028: echo may interpret backslashes in some shells, use printf.
        printf "%s\n" "$line_content" >> "$target_file"
    fi
}

# Helper to ensure a directory exists
# ensure_dir_exists "/path/to/directory"
ensure_dir_exists() {
    local dir_path="$1"
    if [[ ! -d "$dir_path" ]]; then
        # run_command handles logging of mkdir
        run_command "mkdir -p \"$dir_path\"" || return 1 # Propagate error
        # log "Ensured directory exists: $dir_path" # Can be verbose, run_command logs execution
    fi
    return 0
}

# Helper to ensure a file exists (touches it if not)
# ensure_file_exists "/path/to/file"
ensure_file_exists() {
    local file_path="$1"
    # Ensure parent directory exists first
    ensure_dir_exists "$(dirname "$file_path")" || return 1
    if [[ ! -f "$file_path" ]]; then
        run_command "touch \"$file_path\"" || return 1
        # log "Ensured file exists: $file_path" # Can be verbose
    fi
    return 0
}

# Helper function to apply multiple placeholder replacements to a string (template content)
# Usage: final_content=$(apply_replacements "$template_content" "%%KEY1%%" "$value1" "%%KEY2%%" "$value2" ...)
apply_replacements() {
    local content="$1"
    shift # Remove template content from args, leaving pairs of placeholder/value

    while [[ $# -gt 1 ]]; do
        local placeholder="$1"
        local value="$2"
        # Using bash's string replacement: ${string//pattern/replacement}
        # Ensure placeholder is treated literally, especially if it contains regex special chars.
        # For simple %%VAR%% style placeholders, direct substitution is fine.
        # If placeholders could have shell special characters, more complex quoting/escaping for the pattern might be needed.
        content="${content//${placeholder}/${value}}"
        shift 2 # Move to the next pair
    done
    printf "%s" "$content" # Output the modified content
}

# Helper function to get template content
# Usage: template_content=$(_get_template_content "template_filename.ext")
# Expects template_filename.ext to be in TEMPLATE_DIR (defined by calling script)
_get_template_content() {
    local template_name="$1"
    # TEMPLATE_DIR must be defined in the calling script and exported or available in scope
    if [[ -z "$TEMPLATE_DIR" ]]; then
        log "ERROR: TEMPLATE_DIR variable is not set. Cannot load template."
        return 1
    fi
    local template_path="${TEMPLATE_DIR}/${template_name}"
    if [[ ! -f "$template_path" ]]; then
        log "ERROR: Template file not found: $template_path"
        return 1
    fi
    cat "$template_path" # Output content to be captured by command substitution $()
    return 0 # cat will return 0 on success
}

log "common_utils.sh sourced and initialized."
