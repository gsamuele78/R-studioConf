# Configuration Reference

## 1. Overview

The `config/` directory contains key-value pair files (`.vars.conf`) sourced by the installation scripts.
Modifying these files allows you to customize the deployment without editing code.

## 2. Global Configuration

### `r_env_manager.conf`

Master config for the R environment.

- `CRAN_REPO_URL_BIN`: The Ubuntu binary mirror (e.g., cloud.r-project.org).
- `RSTUDIO_VERSION_FALLBACK`: Specific version to install if auto-detection fails.

## 3. Deployment Configuration

### `install_nginx.vars.conf`

Network and Domain settings.

- `DOMAIN_OR_IP`: The public DNS name (e.g., `lab.example.com`).
- `CERT_MODE`: `SELF_SIGNED` (internal) or `LETS_ENCRYPT` (public).
- `LE_EMAIL`: Email for Certbot notifications.
- `RSTUDIO_PORT`: Backend port (default 8787).
- `WEB_TERMINAL_PORT`: Backend port (default 7681).
- `Nextcloud Target URL`: If Nextcloud is external (e.g., distinct VM), set IP here.

### `join_domain_samba.vars.conf`

Active Directory Integration.

- `AD_DOMAIN_UPPER`: Realm (e.g., `EXAMPLE.COM`).
- `AD_DOMAIN_LOWER`: DNS Domain (`example.com`).
- `SAMBA_WORKGROUP`: NetBIOS name (`EXAMPLE`).
- `SAMBA_ALLOWED_GROUPS`: Comma-separated list of AD groups permitted to login (optional).

## 4. Post-Deployment Changes

To apply changes after deployment:

1. **Edit** the relevant file in `config/`.
2. **Run** the associated script again.

**Example: Changing Domain Name**

1. Edit `install_nginx.vars.conf`, change `DOMAIN_OR_IP`.
2. Run `sudo ./scripts/30_install_nginx.sh`.
    - Script extracts new domain.
    - Re-generates Nginx configs from templates.
    - Obtains new SSL certificate.
    - Restarts Nginx.
