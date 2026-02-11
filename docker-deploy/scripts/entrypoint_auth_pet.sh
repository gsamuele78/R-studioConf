#!/bin/bash
# entrypoint_auth_pet.sh
# Configures container authentication based on mounted host sockets/pipes

set -e

log() {
    echo "[Entrypoint-Auth] $1"
}

log "Starting Auth Configuration..."

# 1. Check for SSSD (Socket Mount Method)
if [ -S "/var/lib/sss/pipes/nss" ]; then
    log "Detected SSSD sockets. Configuring for SSSD Passthrough..."
    
    # Enable SSS in nsswitch.conf
    if ! grep -q "sss" /etc/nsswitch.conf; then
        sed -i 's/passwd: *files/passwd:         files sss/' /etc/nsswitch.conf
        sed -i 's/group: *files/group:          files sss/' /etc/nsswitch.conf
        sed -i 's/shadow: *files/shadow:         files sss/' /etc/nsswitch.conf
    fi
    
    # Configure PAM (Ubuntu specific)
    # running pam-auth-update might fail without systemd, so we manual edit or trust pre-install
    # Ideally, we should have installed libpam-sss which adds itself via pam-auth-update in build.
    # But just in case:
    if ! grep -q "pam_sss.so" /etc/pam.d/common-auth; then
        log "WARNING: pam_sss.so not found in common-auth. Auth might fail."
    fi

# 2. Check for Winbind (Pipe Mount Method)
elif [ -S "/run/samba/winbindd/pipe" ] || [ -d "/var/run/samba/winbindd" ] || [ -d "/var/lib/samba/winbindd_privileged" ]; then
    log "Detected Winbind pipes. Configuring for Winbind Passthrough..."

    # Enable Winbind in nsswitch.conf
    if ! grep -q "winbind" /etc/nsswitch.conf; then
        sed -i 's/passwd: *files/passwd:         files winbind/' /etc/nsswitch.conf
        sed -i 's/group: *files/group:          files winbind/' /etc/nsswitch.conf
    fi

    # Ensure RStudio/User can access the privileged pipe
    # This is tricky because GIDs might not match.
    # We hope the host mounted it with permissions we can read, OR we are root.
    
    # Configure PAM
    if ! grep -q "pam_winbind.so" /etc/pam.d/common-auth; then
         log "WARNING: pam_winbind.so not found in common-auth."
    fi

else
    log "No external Auth sockets detected. Falling back to local/default."
fi

# 3. Handle Docker Socket for TTYD? (Optional)

# 4. Exec the CMD (usually /init for S6)
log "Handing off to command: $@"
exec "$@"
