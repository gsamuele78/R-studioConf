#!/bin/bash
# /usr/local/bin/ttyd_login_wrapper.sh
# Wrapper to pass REMOTE_USER (set by ttyd from auth-header) to login -f

# Log everything to Standard Error (captured by systemd in /var/log/ttyd.error.log)
{
    echo "--- New Connection $(date) ---"
    echo "Running as uid: $(id -u) user: $(whoami)"
    echo "--- Environment Dump ---"
    printenv
    echo "------------------------"

    if [ -z "$REMOTE_USER" ]; then
        # Sometimes ttyd might set REMOTE_USER_VAR? Check specifically.
        if [ -n "$X_FORWARDED_USER" ]; then
            REMOTE_USER="$X_FORWARDED_USER"
        else
            echo "Error: REMOTE_USER is empty. Checking keys..."
             # Fallback attempt: Look for any var with the email
             DETECTED_USER=$(printenv | grep -E 'gianfranco|administrator' | head -n 1 | cut -d= -f2)
             if [ -n "$DETECTED_USER" ]; then
                 echo "WARN: Found user in other var, using: $DETECTED_USER"
                 REMOTE_USER="$DETECTED_USER"
             else
                 echo "FATAL: Could not find username in environment."
                 exit 1
             fi
        fi
    fi

    echo "Executing: /bin/login -f '$REMOTE_USER'"
} >&2

# Execute login
exec /bin/login -f "$REMOTE_USER"
