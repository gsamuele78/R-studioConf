#!/bin/bash
# /usr/local/bin/ttyd-login-wrapper.sh

# This script acts as a bridge between ttyd and the system's login program.
# ttyd will pass the 'X-Forwarded-User' header as an environment variable.

# The header 'X-Forwarded-User' is converted by ttyd to 'HTTP_X_FORWARDED_USER'
# and then to uppercase 'X_FORWARDED_USER' for the shell script.
# We must use the full User Principal Name for 'login -f' to work with SSSD.
TARGET_USER="${X_FORWARDED_USER}"

if [ -z "$TARGET_USER" ]; then
    echo "Authentication error: No user specified by the proxy." >&2
    exit 1
fi

# Use 'exec' to replace this script's process with the 'login' process.
# This is more efficient and ensures signals are handled correctly.
# The '-f' flag tells login to perform a seamless login without a password prompt.
exec /bin/login -f "$TARGET_USER"