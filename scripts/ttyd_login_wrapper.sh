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
        if [ -n "$TTYD_USER" ]; then
             echo "Using TTYD_USER: $TTYD_USER"
             REMOTE_USER="$TTYD_USER"
        elif [ -n "$X_FORWARDED_USER" ]; then
             echo "Using X_FORWARDED_USER: $X_FORWARDED_USER"
            REMOTE_USER="$X_FORWARDED_USER"
        else
            echo "Error: REMOTE_USER, TTYD_USER, and X_FORWARDED_USER are empty."
            exit 1
        fi
    fi

    # Fix unbound variable errors in user profile
    export XDG_DATA_DIRS="${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
    export LC_BYOBU="${LC_BYOBU:-0}"
    
    echo "Executing: /bin/login -f '$REMOTE_USER'"
} >&2

# Execute login
exec /bin/login -f "$REMOTE_USER"
