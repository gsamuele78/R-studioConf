#!/bin/bash
#
# Diagnostic script for Domain Join + Home Directory checks.
# Supports both SSSD and Samba/Winbind backends.
#
# Original name: 01_check_autofs_sssd_pam.sh
# New name: 99_check_domain_join_diagnostics.sh
#

USER_TO_TEST="${1:-$(whoami)}"
HOME_PATH="/home/${USER_TO_TEST}"

echo "=== Domain Join & Home Directory Diagnostic ==="
echo "Testing for user: $USER_TO_TEST"
echo

# Detect which service is primarily being used
HAS_SSSD=false
HAS_WINBIND=false
if systemctl is-active --quiet sssd; then HAS_SSSD=true; fi
if systemctl is-active --quiet winbind; then HAS_WINBIND=true; fi

echo ">> Detecting Active Directory Backend..."
if [ "$HAS_SSSD" = true ]; then
    echo "  [INFO] SSSD is active."
fi
if [ "$HAS_WINBIND" = true ]; then
    echo "  [INFO] Winbind is active."
fi
if [ "$HAS_SSSD" = false ] && [ "$HAS_WINBIND" = false ]; then
    echo "  [WARN] Neither SSSD nor Winbind services appear active."
fi
echo

# 1. Check running services
echo ">> Checking services..."
SERVICES_TO_CHECK="ssh rstudio-server"
if [ "$HAS_SSSD" = true ]; then SERVICES_TO_CHECK="$SERVICES_TO_CHECK sssd"; fi
if [ "$HAS_WINBIND" = true ]; then SERVICES_TO_CHECK="$SERVICES_TO_CHECK winbind"; fi

# Autofs check is optional - only report if it's installed/active or we suspect it should be
if command -v automount >/dev/null; then
    SERVICES_TO_CHECK="autofs $SERVICES_TO_CHECK"
fi

for svc in $SERVICES_TO_CHECK; do
    if systemctl is-active --quiet "$svc"; then
        echo "  [OK] $svc is running"
    else
        # Special case: Autofs might be installed but not running/used
        if [ "$svc" == "autofs" ]; then
             echo "  [INFO] autofs is installed but NOT running (OK if not using it)"
        else
             echo "  [ERR] $svc is NOT running"
        fi
    fi
done
echo

# 2. Config checks
echo ">> Checking configuration files..."
if [ "$HAS_SSSD" = true ]; then
    if [ -f /etc/sssd/sssd.conf ]; then
        sudo grep -q "\[domain/" /etc/sssd/sssd.conf && echo "  [OK] Domain(s) defined in sssd.conf" || echo "  [ERR] No domains found in sssd.conf"
    else
        echo "  [ERR] /etc/sssd/sssd.conf not found (SSSD active but no config?)"
    fi
fi

if [ "$HAS_WINBIND" = true ]; then
    if [ -f /etc/samba/smb.conf ]; then
        if sudo grep -qE "security\s*=\s*ads" /etc/samba/smb.conf; then
             echo "  [OK] smb.conf configured for AD (security = ads)"
        else
             echo "  [WARN] smb.conf may not be set to 'security = ads'"
        fi
        
        if sudo grep -q "idmap config" /etc/samba/smb.conf; then
             echo "  [OK] ID mapping appears configured in smb.conf"
        else
             echo "  [WARN] No 'idmap config' found in smb.conf"
        fi
    else
        echo "  [ERR] /etc/samba/smb.conf not found"
    fi
fi

# Autofs config check (only if autofs is active)
if systemctl is-active --quiet autofs; then
    echo "  [INFO] Autofs active, checking maps..."
    sudo grep -r -oP "^[^#]*/home" /etc/auto.master* 2>/dev/null || echo "  [WARN] No direct /home mapping in auto.master"
fi
echo

# 3. PAM configuration
echo ">> Checking PAM configuration..."

# Auth files: Check for backend (winbind/sssd) only
AUTH_PAM_FILES="/etc/pam.d/common-auth"
for pamfile in $AUTH_PAM_FILES; do
    echo "  Checking $pamfile ..."
    if [ ! -f "$pamfile" ]; then
        echo "    [WARN] $pamfile not found, skipping."
        continue
    fi
    
    FOUND_BACKEND=false
    if sudo grep -q "pam_sss.so" "$pamfile"; then
        echo "    [OK] pam_sss.so present"
        FOUND_BACKEND=true
    fi
    if sudo grep -q "pam_winbind.so" "$pamfile"; then
        echo "    [OK] pam_winbind.so present"
        FOUND_BACKEND=true
    fi
    
    if [ "$FOUND_BACKEND" = false ]; then
        echo "    [WARN] Neither pam_sss.so nor pam_winbind.so found in $pamfile"
    fi
done

# Session files: Check for backend AND mkhomedir
SESSION_PAM_FILES="/etc/pam.d/common-session"
if [ -f "/etc/pam.d/common-session-noninteractive" ]; then
    SESSION_PAM_FILES="$SESSION_PAM_FILES /etc/pam.d/common-session-noninteractive"
fi

for pamfile in $SESSION_PAM_FILES; do
    echo "  Checking $pamfile ..."
    if [ ! -f "$pamfile" ]; then
        echo "    [WARN] $pamfile not found, skipping."
        continue
    fi
    
    FOUND_BACKEND=false
    if sudo grep -q "pam_sss.so" "$pamfile"; then
        echo "    [OK] pam_sss.so present"
        FOUND_BACKEND=true
    fi
    if sudo grep -q "pam_winbind.so" "$pamfile"; then
        echo "    [OK] pam_winbind.so present"
        FOUND_BACKEND=true
    fi
    
    if [ "$FOUND_BACKEND" = false ]; then
        echo "    [WARN] Neither pam_sss.so nor pam_winbind.so found in $pamfile"
    fi

    # mkhomedir check (Session only)
    if sudo grep -q "pam_mkhomedir.so" "$pamfile"; then
        echo "    [OK] pam_mkhomedir.so present"
    else
        echo "    [WARN] pam_mkhomedir.so missing (homes may not be auto-created)"
    fi
done
echo

# 4. Test NSS resolution for user
echo ">> Checking NSS user lookup for $USER_TO_TEST ..."
if getent passwd "$USER_TO_TEST" >/dev/null; then
    echo "  [OK] User resolved by NSS"
    # Show internal ID to confirm mapping
    id "$USER_TO_TEST"
else
    echo "  [ERR] User not found in NSS (getent passwd failed)"
fi
echo

# 5. Check Home Directory
echo ">> Checking Home Directory for $USER_TO_TEST ..."
if [ -d "$HOME_PATH" ]; then
    echo "  [OK] Home directory exists: $HOME_PATH"
else
    echo "  [WARN] Home directory does not exist: $HOME_PATH"
fi
echo

# 6. RStudio integration test
echo ">> Checking RStudio PAM integration..."
if [ -f /etc/pam.d/rstudio ]; then
    RS_PAM_OK=false
    if grep -q "pam_sss.so" /etc/pam.d/rstudio; then
        echo "  [OK] RStudio PAM uses pam_sss.so"
        RS_PAM_OK=true
    fi
    if grep -q "pam_winbind.so" /etc/pam.d/rstudio; then
        echo "  [OK] RStudio PAM uses pam_winbind.so"
        RS_PAM_OK=true
    fi
    
    if [ "$RS_PAM_OK" = false ]; then
        # It might be including common-session, which is also fine
        if grep -q "@include common-session" /etc/pam.d/rstudio; then
            echo "  [OK] RStudio PAM includes common-session"
        else
            echo "  [WARN] RStudio PAM /etc/pam.d/rstudio may not be configured for AD auth"
        fi
    fi
else
    echo "  [INFO] /etc/pam.d/rstudio not found (RStudio might use default PAM or not installed)"
fi
echo

echo "=== Diagnostic complete ==="
