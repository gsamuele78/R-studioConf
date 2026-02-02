#!/bin/bash
# 15_setup_nginx_cleanup.sh
# Deploys a daily cron job to clean Nginx temporary body files.
# Includes disk usage safety check.
#
# Usage: ./15_setup_nginx_cleanup.sh
# Standardized to use common_utils.sh

# =====================================================================
# LOAD COMMON UTILITIES
# =====================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
UTILS_SCRIPT_PATH="${SCRIPT_DIR}/../lib/common_utils.sh"
TEMPLATE_DIR="${SCRIPT_DIR}/../templates"

if [[ ! -f "$UTILS_SCRIPT_PATH" ]]; then
    echo "ERROR: common_utils.sh not found at $UTILS_SCRIPT_PATH" >&2
    exit 1
fi
source "$UTILS_SCRIPT_PATH"

check_root

log INFO "=== Setting up Nginx Cleanup Cron Job ==="

CRON_FILE="/etc/cron.daily/nginx_cleanup"
LOG_FILE="/var/log/nginx/cleanup.log"

# Define the cron script content
# Note: We write this content directly to the file, but we use run_command to ensure logging.
# Constructing the script content first.
cron_script_content='#!/bin/bash
# Nginx Temp File Cleanup
# Deletes stale client body temp files to prevent disk exhaustion.

LOG_FILE="/var/log/nginx/cleanup.log"
target_dir="/var/lib/nginx/body"

log() {
    echo "[$(date +'\''%Y-%m-%d %H:%M:%S'\'')] $1" >> "$LOG_FILE"
}

if [[ ! -d "$target_dir" ]]; then
    # Silent exit if dir doesnt exist yet
    exit 0
fi

# Disk Usage Check
# Get usage percentage of the partition holding /var/lib/nginx
usage=$(df --output=pcent "$target_dir" | tail -n 1 | tr -dc '\''0-9'\'')

log "Starting cleanup. Disk usage is ${usage}%."

if [[ "$usage" -gt 95 ]]; then
    log "WARNING: Disk usage critical (>95%). Executing EMERGENCY cleanup (files > 60 mins)."
    find "$target_dir" -type f -mmin +60 -delete -print > /tmp/nginx_deleted_files
    count=$(wc -l < /tmp/nginx_deleted_files)
    log "Emergency cleanup deleted $count files."
else
    log "Executing standard cleanup (files > 24 hours)."
    find "$target_dir" -type f -mmin +1440 -delete -print > /tmp/nginx_deleted_files
    count=$(wc -l < /tmp/nginx_deleted_files)
    log "Standard cleanup deleted $count files."
fi

rm -f /tmp/nginx_deleted_files
'

# Create Log File
if [[ ! -f "$LOG_FILE" ]]; then
    run_command "Create log file" "touch \"$LOG_FILE\" && chmod 644 \"$LOG_FILE\""
fi

# Write Cron Script using bash redirection inside sudo (handled by manual run_command equivalent logic or just direct write since we are root)
# Using printf to handle the variable content safely
log INFO "Writing cron script to $CRON_FILE"
printf "%s" "$cron_script_content" > "$CRON_FILE"

if [[ -f "$CRON_FILE" ]]; then
    run_command "Make cron script executable" "chmod +x \"$CRON_FILE\""
    log INFO "Cron job setup successful."
else
    log ERROR "Failed to create cron file."
    exit 1
fi

log INFO "Running initial test of cleanup script..."
if "$CRON_FILE"; then
    log INFO "Test run completed successfully. Check $LOG_FILE."
else
    log WARN "Test run encountered issues."
fi

log INFO "Setup Complete."
