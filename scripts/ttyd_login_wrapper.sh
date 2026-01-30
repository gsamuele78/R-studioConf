#!/bin/bash
# /usr/local/bin/ttyd_login_wrapper.sh

# DEBUGGING: Log to /tmp which is universally writable
LOG_FILE="/tmp/ttyd_debug.log"

# Log header
{
    echo "============================================"
    echo "Timestamp: $(date)"
    echo "Running as: $(id)"
    echo "--- ENV VARS START ---"
    printenv
    echo "--- ENV VARS END ---"
} >> "$LOG_FILE" 2>&1

# Logic to find the username
if [ -z "$REMOTE_USER" ]; then
    if [ -n "$TTYD_USER" ]; then
         echo "Using TTYD_USER: $TTYD_USER" >> "$LOG_FILE"
         REMOTE_USER="$TTYD_USER"
    elif [ -n "$X_FORWARDED_USER" ]; then
         echo "Using X_FORWARDED_USER: $X_FORWARDED_USER" >> "$LOG_FILE"
        REMOTE_USER="$X_FORWARDED_USER"
    else
        echo "CRITICAL: No username found in env vars." >> "$LOG_FILE"
        # Dump to stderr as well just in case
        echo "Error: REMOTE_USER, TTYD_USER, and X_FORWARDED_USER are empty." >&2
        exit 1
    fi
fi

echo "Attempting login for: '$REMOTE_USER'" >> "$LOG_FILE"

# WORKAROUND: TTYD 32-char limit bypass.
# Nginx strips the domain. We re-append it here.
if [[ "$REMOTE_USER" != *"@"* ]]; then
    # Default domain fallback
    DOMAIN_SUFFIX="@unibo.it"
    echo "Appending domain suffix: $DOMAIN_SUFFIX" >> "$LOG_FILE"
    REMOTE_USER="${REMOTE_USER}${DOMAIN_SUFFIX}"
fi

# Fix unbound variable errors
export XDG_DATA_DIRS="${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
export LC_BYOBU="${LC_BYOBU:-0}"

# Execute login
exec /bin/login -f "$REMOTE_USER"
