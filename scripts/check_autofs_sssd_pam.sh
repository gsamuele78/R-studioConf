#!/bin/bash
#
# Diagnostic script for autofs + sssd + pam home directory auto-mount
# Works on Ubuntu 24.04 LTS with SSH and RStudio Server (Open Source)
#

USER_TO_TEST="${1:-$(whoami)}"
HOME_PATH="/home/${USER_TO_TEST}"

echo "=== AUTOFs + SSSD + PAM Diagnostic ==="
echo "Testing for user: $USER_TO_TEST"
echo

# 1. Check running services
echo ">> Checking services..."
for svc in autofs sssd ssh rstudio-server; do
    if systemctl is-active --quiet "$svc"; then
        echo "  [OK] $svc is running"
    else
        echo "  [ERR] $svc is NOT running"
    fi
done
echo

# 2. autofs config check
echo ">> Checking autofs config..."
#grep -E "^\s*/home" /etc/auto.master* 2>/dev/null || echo "  [WARN] No direct /home mapping in auto.master"
sudo grep -r -oP "^[^#]*/home" /etc/auto.master* 2>/dev/null || echo "  [WARN] No direct /home mapping in auto.master"
grep -q "sss" /etc/nsswitch.conf && echo "  [OK] autofs integrated with SSSD in nsswitch.conf" || echo "  [ERR] autofs not integrated with SSSD"
echo

# 3. PAM configuration
echo ">> Checking PAM configuration..."
for pamfile in /etc/pam.d/common-session /etc/pam.d/common-session-noninteractive; do
    echo "  Checking $pamfile ..."
    sudo grep -q "pam_sss.so" $pamfile && echo "    [OK] pam_sss.so present" || echo "    [ERR] pam_sss.so missing"
    sudo grep -q "pam_mkhomedir.so" $pamfile && echo "    [OK] pam_mkhomedir.so present" || echo "    [WARN] pam_mkhomedir.so missing (homes may not be auto-created)"
done
echo

# 4. SSSD configuration
echo ">> Checking SSSD configuration..."
if [ -f /etc/sssd/sssd.conf ]; then
    sudo grep -q "\[domain/" /etc/sssd/sssd.conf && echo "  [OK] Domain(s) defined in sssd.conf" || echo "  [ERR] No domains found in sssd.conf"
    sudo grep -q "use_fully_qualified_names" /etc/sssd/sssd.conf && echo "  [INFO] Using FQDN for usernames" 
    sudo grep -q "fallback_homedir" /etc/sssd/sssd.conf && echo "  [OK] fallback_homedir set" || echo "  [WARN] fallback_homedir not set"
else
    echo "  [ERR] /etc/sssd/sssd.conf not found"
fi
echo

# 5. Test NSS resolution for user
echo ">> Checking NSS user lookup for $USER_TO_TEST ..."
getent passwd "$USER_TO_TEST" >/dev/null && echo "  [OK] User resolved by NSS/SSSD" || echo "  [ERR] User not found in NSS/SSSD"
echo

# 6. Test mount of home directory
echo ">> Testing autofs mount for $HOME_PATH ..."
if [ -d "$HOME_PATH" ]; then
    ls "$HOME_PATH" >/dev/null 2>&1
    if mount | grep -q "$HOME_PATH"; then
        echo "  [OK] $HOME_PATH is mounted via autofs"
    else
        echo "  [WARN] $HOME_PATH exists but is not auto-mounted"
    fi
else
    echo "  [ERR] Home path $HOME_PATH does not exist"
fi
echo

# 7. RStudio integration test
echo ">> Checking RStudio PAM integration..."
if grep -q "session.*pam_sss.so" /etc/pam.d/rstudio; then
    echo "  [OK] RStudio PAM uses pam_sss.so"
else
    echo "  [WARN] RStudio PAM may not use SSSD"
fi
echo

echo "=== Diagnostic complete ==="
