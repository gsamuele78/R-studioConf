# Nginx Dual Authentication Backend Support - Complete Implementation Guide

## Overview

The updated Nginx setup script (`05_nginx_setup_dual_auth.sh`) now supports **two distinct authentication backends** for AD integration with PAM-based Nginx authentication:

1. **SSSD + Kerberos** - User/group caching with reduced AD load
2. **Samba + Kerberos** - Direct AD authentication with SMB/CIFS support

---

## Authentication Backend Comparison

### SSSD + Kerberos (Recommended for Most Deployments)

**Architecture:**
```
Nginx PAM Request
    ↓
pam_sss.so (libpam-sss)
    ↓
SSSD Daemon (cached user/group database)
    ↓
Active Directory
```

**Key Characteristics:**
- **Caching**: Local cache reduces AD queries
- **Performance**: Faster lookups for repeated users
- **AD Load**: Reduced direct queries to AD
- **Group Handling**: Via SSSD cache
- **Package**: `libpam-sss` (included with `sssd-ad`)
- **PAM Module**: `pam_sss.so`
- **NSSwitch Entries**: `sssd`
- **Group Permission**: `usermod -a -G sasl www-data`
- **Configuration**: `/etc/sssd/sssd.conf`

**Best For:**
- High-traffic Nginx deployments
- Environments with many concurrent users
- Where reducing AD server load is important
- Standard corporate AD environments

---

### Samba + Kerberos (Direct AD Authentication)

**Architecture:**
```
Nginx PAM Request
    ↓
pam_winbind.so (libpam-winbind)
    ↓
Winbind Daemon (real-time AD lookups)
    ↓
Active Directory
```

**Key Characteristics:**
- **Real-time**: Direct AD lookups for each request
- **SMB/CIFS**: Can also serve file shares
- **Kerberos**: Direct Kerberos authentication
- **On-Demand**: No caching delays
- **Package**: `libpam-winbind` (included with `samba`)
- **PAM Module**: `pam_winbind.so`
- **NSSwitch Entries**: `winbind`
- **Group Permission**: `usermod -a -G sambashare www-data`
- **Configuration**: `/etc/samba/smb.conf`

**Best For:**
- Environments needing SMB/CIFS file shares
- Direct Kerberos authentication preferred
- Systems with low-latency AD connectivity
- Multi-service deployments (file sharing + web auth)

---

## Configuration

### Extended Configuration File (nginx_setup_extended.vars.conf)

The new configuration file includes sections for both backends:

```bash
# --- Authentication Backend Configuration (NEW)
AUTH_BACKEND="SSSD"  # or "SAMBA"

# --- Active Directory Domain Configuration ---
AD_DOMAIN_LOWER="example.com"
AD_DOMAIN_UPPER="EXAMPLE.COM"
AD_REALM="${AD_DOMAIN_UPPER}"

# --- SSSD-Specific Configuration
SSSD_CONFIG_DIR="/etc/sssd"
SSSD_ALLOWED_GROUPS=""
SSSD_CACHE_TIMEOUT="3600"

# --- Samba/Winbind-Specific Configuration
SAMBA_CONFIG_PATH="/etc/samba/smb.conf"
SAMBA_WORKGROUP="WORKGROUP"
SAMBA_ALLOWED_GROUPS=""
IDMAP_RANGE_LOW="10000"
IDMAP_RANGE_HIGH="999999"
TEMPLATE_HOMEDIR="/nfs/home/%U"

# --- PAM Service Configuration
PAM_NGINX_SERVICE_NAME="nginx"
PAM_AUTH_MESSAGE="Secure Area - Active Directory Credentials Required"
```

---

## Implementation Details

### Step 1: Authentication Backend Selection

During setup, the script prompts for backend choice:

```bash
Authentication Backend (SSSD/SAMBA): SSSD
```

The selected backend determines:
- Which packages are installed
- How NSSwitch is configured
- Which PAM module is used
- Group membership handling

### Step 2: Package Installation (Backend-Specific)

**For SSSD:**
```bash
sssd-ad sssd-tools krb5-user libpam-sss libpam-krb5 libnss-sss
```

**For Samba:**
```bash
samba winbind krb5-user krb5-clients libpam-winbind libnss-winbind
```

### Step 3: NSSwitch Configuration

**For SSSD** (`/etc/nsswitch.conf`):
```
passwd:  files systemd sssd
shadow:  files sssd
group:   files systemd sssd
```

**For Samba** (`/etc/nsswitch.conf`):
```
passwd:  files winbind
group:   files winbind
```

### Step 4: PAM Service File Creation

**For SSSD** (`/etc/pam.d/nginx`):
```
auth    sufficient      pam_sss.so
auth    required        pam_unix.so try_first_pass nullok
account sufficient      pam_sss.so
account required        pam_unix.so
session optional        pam_sss.so
session required        pam_unix.so
```

**For Samba** (`/etc/pam.d/nginx`):
```
auth    sufficient      pam_winbind.so use_first_pass try_first_pass
auth    required        pam_unix.so try_first_pass nullok
account sufficient      pam_winbind.so
account required        pam_unix.so
password        optional        pam_winbind.so
session required        pam_unix.so
session optional        pam_winbind.so
```

### Step 5: Web Server Permissions

**For SSSD:**
```bash
usermod -a -G sasl www-data
```

**For Samba:**
```bash
usermod -a -G sambashare www-data
```

---

## Nginx Configuration Integration

Both backends work identically at the Nginx level. The PAM authentication in Nginx location blocks remains unchanged:

```nginx
location /terminal/ {
    auth_pam "Secure Terminal - AD Credentials Required";
    auth_pam_service_name "nginx";
    proxy_pass http://127.0.0.1:2222/;
    # ... other directives
}

location /files/ {
    auth_pam "Secure Files - AD Credentials Required";
    auth_pam_service_name "nginx";
    proxy_pass http://127.0.0.1:2223/;
    # ... other directives
}
```

The backend (SSSD or Samba) is transparent to Nginx - both use the same PAM interface.

---

## Usage Instructions

### 1. Update Configuration

Choose your preferred backend in `nginx_setup_extended.vars.conf`:

```bash
# For SSSD (cached authentication)
AUTH_BACKEND="SSSD"

# Or for Samba (direct AD with SMB/CIFS support)
AUTH_BACKEND="SAMBA"
```

### 2. Run Setup Script

```bash
sudo ./05_nginx_setup_dual_auth.sh -c /path/to/nginx_setup_extended.vars.conf
```

### 3. Interactive Menu

```
=== Nginx Setup Menu (Dual Auth Backend) ===
1) Install/Configure Nginx (with Auth Backend)
U) Uninstall Nginx and restore system
R) Restore configurations from most recent backup
4) Exit

Choice: 1
```

### 4. Answer Prompts

The script will prompt for:
- Authentication Backend selection
- Certificate mode (Self-Signed or Let's Encrypt)
- Domain/IP configuration
- Service ports
- AD domain configuration
- Backend-specific settings (groups, workgroup, etc.)

### 5. Verification

After installation, verify authentication:

**For SSSD:**
```bash
# Check SSSD status
sudo systemctl status sssd

# Test user lookup
getent passwd username
id username
```

**For Samba:**
```bash
# Check Winbind status
sudo systemctl status winbind

# Test user lookup
wbinfo -u | grep username
id username
```

---

## Key Differences for Administrators

| Aspect | SSSD | Samba |
|--------|------|-------|
| **User Caching** | Automatic local cache | On-demand lookups |
| **AD Queries** | Reduced via cache | Direct per-request |
| **SMB/CIFS Shares** | Requires separate setup | Native support |
| **Setup Complexity** | Simpler | More involved |
| **Memory Footprint** | Lower | Medium-higher |
| **Recommended For** | Most deployments | Multi-protocol sites |
| **Failover Behavior** | Uses cache if AD down | Immediate failure |

---

## Troubleshooting

### Testing PAM Authentication

After setup, test the PAM service manually:

```bash
# Test nginx PAM service
sudo /usr/sbin/pamtester nginx username authenticate

# Check PAM logs
sudo journalctl -u sshd -f  # For SSH (similar PAM stack)
```

### Checking User Resolution

**For SSSD:**
```bash
# Should show AD user details
getent passwd username

# Should show AD groups
getent group
```

**For Samba:**
```bash
# Should show AD user details
wbinfo -i username

# List AD users
wbinfo -u

# List AD groups
wbinfo -g
```

### Common Issues

**Issue**: Users not found by PAM
- **SSSD**: Check `/etc/sssd/sssd.conf`, verify SSSD service is running
- **Samba**: Check `/etc/samba/smb.conf`, verify Winbind service is running

**Issue**: Nginx auth_pam directive not found
- Ensure `nginx-full` package is installed (must be built with PAM module support)

**Issue**: Group membership not recognized
- **SSSD**: Check SSSD cache, may need to restart `sudo systemctl restart sssd`
- **Samba**: Verify group names with `getent group` or `wbinfo -g`

---

## New Functions in 05_nginx_setup_dual_auth.sh

### validate_auth_backend()
Validates that AUTH_BACKEND is either SSSD or SAMBA

### setup_auth_backend_sssd()
Installs SSSD packages and configures SSSD+Kerberos integration

### setup_auth_backend_samba()
Installs Samba packages and configures Samba+Kerberos integration

### configure_nsswitch_sssd()
Updates /etc/nsswitch.conf for SSSD resolution

### configure_nsswitch_samba()
Updates /etc/nsswitch.conf for Winbind resolution

### create_pam_service_nginx_sssd()
Creates /etc/pam.d/nginx with SSSD PAM stack

### create_pam_service_nginx_samba()
Creates /etc/pam.d/nginx with Winbind PAM stack

---

## Integration with Samba Setup Script

The new Nginx script can work alongside `02_samba_kerberos_setup.sh`:

1. **Use Samba Setup** to:
   - Join domain with realm
   - Generate/deploy smb.conf
   - Test Samba/Winbind installation

2. **Use Nginx Setup** to:
   - Choose Samba auth backend
   - Configure PAM for Nginx
   - Deploy Nginx reverse proxy

Both scripts share:
- Common utilities from `common_utils.sh`
- Configuration templates in `templates/`
- Backup/restore functionality
- Interactive menu systems

---

## Files Provided

1. **05_nginx_setup_dual_auth.sh** - Main script with dual auth backend support
2. **nginx_setup_extended.vars.conf** - Extended configuration with backend-specific settings
3. **This Documentation** - Complete implementation guide

---

## Directory Structure

```
.../
├── scripts/
│   └── 05_nginx_setup_dual_auth.sh
│   └── 02_samba_kerberos_setup.sh (existing)
├── lib/
│   └── common_utils.sh
├── config/
│   └── nginx_setup_extended.vars.conf
└── templates/
    ├── nginx_ssl_params.conf.template
    ├── nginx_ssl_certificate.conf.template
    ├── nginx_proxy_location.conf.template
    └── nginx_site.conf.template
```

---

## Recommendation

**For most deployments**: Use **SSSD + Kerberos** backend
- Better performance with caching
- Reduced AD server load
- Simpler troubleshooting
- Recommended by most enterprise environments

**For integrated file sharing**: Use **Samba + Kerberos** backend
- Native SMB/CIFS support
- Direct Kerberos authentication
- Multi-protocol service consolidation

---

## Summary

The dual authentication backend support in Nginx setup now provides flexibility to choose the authentication method that best fits your infrastructure:

- **SSSD**: Optimized for web services with AD caching
- **Samba**: Optimized for integrated services with file sharing

Both provide secure PAM-based authentication to Nginx protected locations, seamlessly integrating with Active Directory environments.
