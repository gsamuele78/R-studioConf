#!/bin/bash
# /usr/local/bin/ttyd_login_wrapper.sh
# Wrapper to pass REMOTE_USER (set by ttyd from auth-header) to login -f

LOG_FILE="/tmp/ttyd_debug.log"

{
    echo "--- New Connection $(date) ---"
    echo "Running as uid: $(id -u) user: $(whoami)"
    echo "Environment REMOTE_USER: '${REMOTE_USER:-}'"
    echo "Environment X_FORWARDED_USER: '${X_FORWARDED_USER:-}'"

    if [ -z "$REMOTE_USER" ]; then
        if [ -n "$X_FORWARDED_USER" ]; then
             echo "REMOTE_USER empty, using X_FORWARDED_USER"
            REMOTE_USER="$X_FORWARDED_USER"
        else
            echo "Error: REMOTE_USER and X_FORWARDED_USER are empty."
            exit 1
        fi
    fi

    echo "Executing: /bin/login -f '$REMOTE_USER'"
} >> "$LOG_FILE" 2>&1

# Execute login (stderr also to log for visibility of login errors)
exec /bin/login -f "$REMOTE_USER" 2>>"$LOG_FILE"
