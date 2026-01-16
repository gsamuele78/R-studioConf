#!/bin/bash
# /usr/local/bin/ttyd_login_wrapper.sh
# Wrapper to pass REMOTE_USER (set by ttyd from auth-header) to login -f

if [ -z "$REMOTE_USER" ]; then
    # Fallback to check X_FORWARDED_USER if REMOTE_USER is missing
    if [ -n "$X_FORWARDED_USER" ]; then
        REMOTE_USER="$X_FORWARDED_USER"
    else
        echo "Error: REMOTE_USER environment variable not set. Authentication header missing?" >&2
        exit 1
    fi
fi

# Execute login with the username
exec /bin/login -f "$REMOTE_USER"
