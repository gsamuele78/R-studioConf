#!/bin/bash
# /usr/local/bin/ttyd-login-wrapper.sh (DEBUG VERSION)

# This script logs the environment variables it receives from ttyd
# before attempting to execute the login command.

LOG_FILE="/tmp/ttyd_debug.log"

echo "--- TTYD WRAPPER SCRIPT TRIGGERED AT $(date) ---" >> "$LOG_FILE"

# Log the specific variable we are looking for.
# The header 'X-Forwarded-User' is converted by ttyd to an uppercase
# environment variable with dashes replaced by underscores.
echo "Value of X_FORWARDED_USER: [${X_FORWARDED_USER}]" >> "$LOG_FILE"

# Log all environment variables for complete context.
echo "--- ALL ENVIRONMENT VARIABLES ---" >> "$LOG_FILE"
printenv >> "$LOG_FILE"
echo "---------------------------------" >> "$LOG_FILE"

# Now, attempt the original logic.
TARGET_USER="${X_FORWARDED_USER}"

if [ -z "$TARGET_USER" ]; then
    echo "Authentication error: No X_FORWARDED_USER environment variable found." >> "$LOG_FILE"
    # This message will appear in the user's browser
    echo "Authentication error: Header not received from proxy." >&2
    exit 1
fi

# Use 'exec' to replace this script's process with the 'login' process.
exec /bin/login -f "$TARGET_USER"