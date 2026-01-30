# Installation & Deployment Guide

## 1. Prerequisites

- **OS**: Ubuntu 22.04 LTS / Debian 12 (bookworm).
- **Network**: Public IP or Internal IP accessible by clients.
- **Privileges**: Root access (`sudo`).
- **Dependencies**: `nginx`, `rstudio-server` (Pro or Open), `ttyd`.

---

## 2. Deployment Scripts

The installation is automated via a set of numbered bash scripts in `scripts/`.

### 2.1 Core Installation Order

1. **System Prep**:

    ```bash
    sudo ./scripts/01_optimize_system.sh
    sudo ./scripts/02_configure_time_sync.sh
    ```

2. **Domain Join (Optional but Recommended)**:
    - If using Active Directory authentication:

    ```bash
    sudo ./scripts/11_join_domain_samba.sh
    ```

3. **Install Services**:

    ```bash
    sudo ./scripts/20_configure_rstudio.sh  # Installs/Configures RStudio
    sudo ./scripts/30_install_nginx.sh      # Installs Nginx + PAM Auth
    ```

4. **Deploy Portal**:

    ```bash
    sudo ./scripts/31_setup_web_portal.sh
    ```

    - *Action*: Generates HTML from templates.
    - *Action*: Replaces placeholders (`%%CURRENT_YEAR%%`) with live values.
    - *Action*: Deploys wrappers (`rstudio_wrapper.html`, etc.) to `/var/www/html/`.

---

## 3. Configuration Variables

All scripts read from configuration files in `config/`.
**Key Files**:

- `config/nginx_setup.vars.conf`: Ports, SSL paths, Domain names.
- `config/configure_rstudio.vars.conf`: RStudio version, License key.

**Modifying Configs**:
Edit these files *before* running the scripts. The scripts source these variables at runtime.

---

## 4. Verification

After running `31_setup_web_portal.sh`:

1. Navigate to `https://YOUR_SERVER_IP/`.
2. You should see the "Botanical Big Data Calculus" portal.
3. Click "Secure Access" and test credentials.

---

## 5. Updates

To update the portal (e.g., after CSS changes):

1. Edit `templates/portal_index.html.template` or `css`.
2. Re-run:

    ```bash
    sudo ./scripts/31_setup_web_portal.sh
    ```

    This simply overwrites the live files in `/var/www/html/` with the new versions. No service restart required.
