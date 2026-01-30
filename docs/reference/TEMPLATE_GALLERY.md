# Template Gallery

## 1. Overview

The `templates/` directory contains "Skeleton" files. Scripts use `sed` or `envsubst` to replace placeholders (like `%%DOMAIN%%` or `{{PORT}}`) with actual values from the `config/` directory.

## 2. Infrastructure Templates

### Nginx

- **`nginx_site.conf.template`**: The main HTTP/HTTPS server block handling the domain.
- **`nginx_proxy_location.conf.template`**: **CRITICAL**. The logic center.
  - Contains the `location /` blocks.
  - Defines the Reverse Proxy rules, Header Injection (`X-Forwarded-User`), and Auth Rewrites.
- **`nginx_ssl_params.conf.template`**: Modern SSL cipher suites and HSTS settings.

### Authentication & Domain

- **`krb5.conf.template`**: Kerberos configuration for AD Auth.
- **`smb.conf.template`**: Samba configuration for Winbind networking.
- **`sssd.conf.template`**: SSSD config (alternate join method).

### Service Configs

- **`ttyd.service.override.template`**: Systemd override for TTYD.
  - Injects the custom start command that trusts `X-Forwarded-User`.
- **`chrony.conf.template`**: NTP daemon config.

## 3. Frontend Templates (The Portal)

### Logic & Layout

- **`portal_index.html.template`**: The Single Page Application (SPA) source.
  - Contains the JavaScript for Auto-Login (`handleConnect`).
  - Contains the HTML structure.
- **`portal_style.css.template`**: The look-and-feel (CSS).
  - Glassmorphism styles, Responsive Grid.

### Wrappers

These are minimal HTML files served to wrap the backend services (which run in `_blank` tabs usually, but these provide a "Home" button or styling frame).

- **`rstudio_wrapper.html.template`**: Wraps RStudio.
- **`terminal_wrapper.html.template`**: Wraps TTYD.
- **`nextcloud_wrapper.html.template`**: Wraps Nextcloud.

## 4. Developer Insight

- **Why Templates?**: This avoids hardcoding IP addresses or Ports in the scripts. It allows the same codebase to deploy to Dev (localhost) and Prod (public domain) just by changing the `config/` file.
