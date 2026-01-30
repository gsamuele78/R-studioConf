# Nginx Authentication Backends (SSSD vs Samba)

## 1. Overview

The Nginx setup script (`scripts/30_install_nginx.sh`) is designed to be **Identity Provider Agnostic**. It detects and integrates with two distinct Active Directory (AD) connection methods:

1. **SSSD + Kerberos**: Optimized for high-traffic web auth (Caching).
2. **Samba + Winbind**: Optimized for environments requiring SMB/CIFS File Sharing integration.

---

## 2. Auto-Detection Logic

The script uses an "Intelligent Backend Detection" algorithm to decide which PAM module to configure.

### Detection Priority

1. **Active Services**: Checks if `sssd` or `winbind` is running via `systemctl`.
2. **Config Files**: Checks for existence of `/etc/sssd/sssd.conf` or `/etc/samba/smb.conf`.
3. **NSSwitch**: Checks `/etc/nsswitch.conf` for `sss` or `winbind` entries.
4. **PAM Stack**: Scans `/etc/pam.d/` for existing modules.

### Override

You can force a specific backend by setting the `AUTH_BACKEND` variable in `config/install_nginx.vars.conf`:

```bash
AUTH_BACKEND="SSSD"  # or "SAMBA"
```

---

## 3. Architecture Comparison

### A. SSSD + Kerberos (Recommended)

**Path**: `pam_sss.so` -> `SSSD Daemon` -> `Active Directory`

- **Pros**:
  - **Caching**: Reduces AD load significantly.
  - **Resilience**: Can auth against cached credentials if AD is temporarily unreachable (configurable).
  - **Standard**: Default for most Linux-AD setups.
- **Cons**:
  - Does not provide file sharing (SMB) capabilities alone.

### B. Samba + Winbind

**Path**: `pam_winbind.so` -> `Winbind Daemon` -> `Active Directory`

- **Pros**:
  - **Unified**: If your server is also a File Server (via `smb.conf`), this shares the same connection.
  - **Real-time**: Direct validation against AD (less caching).
- **Cons**:
  - Heavier resource usage.
  - More complex configuration (`smb.conf`).

---

## 4. Implementation Details

### PAM Service Configuration (`/etc/pam.d/nginx`)

Depending on the detected backend, `30_install_nginx.sh` generates one of the following:

**SSSD Variant**:

```pam
@include common-auth
@include common-account
session required pam_sss.so
auth    required pam_sss.so
```

**Samba Variant**:

```pam
@include common-auth
@include common-account
session required pam_winbind.so
auth    required pam_winbind.so
```

### Permissions

Nginx runs as `www-data`.

- **SSSD**: `www-data` is added to the `sasl` group to talk to the SSSD socket.
- **Samba**: `www-data` is added to the `sambashare` (and optionally `winbindd_priv`) group to talk to the Winbind pipe.

---

## 5. Troubleshooting Authentication

If `auth_pam` fails (Logon incorrect):

1. **Check the Backend logs**:
    - SSSD: `/var/log/sssd/`
    - Samba: `/var/log/samba/log.winbindd`
2. **Test PAM manually**:

    ```bash
    # Install pamtester if missing
    sudo apt-get install pamtester
    
    # Test
    pamtester nginx <username> authenticate
    ```

3. **Verify Groups**:
    - Ensure `id www-data` shows `sasl` (for SSSD) or `winbindd_priv` (for Samba).
