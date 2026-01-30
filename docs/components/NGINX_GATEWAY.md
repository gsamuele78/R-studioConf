# Nginx Gateway Documentation

## 1. Overview

Nginx configured via `nginx_proxy_location.conf.template` is the **Control Plane** of the architecture. It handles routing, security, and authentication enforcement.

---

## 2. Authentication Strategy (`auth_pam`)

We use the `ngx_http_auth_pam_module` to interface directly with the system's PAM stack (which in turn talks to SSSD/Active Directory).

**Configuration**:

```nginx
auth_pam "Secure Terminal - AD Credentials Required";
auth_pam_service_name "nginx";
```

- **Protected Paths**:
  - `/terminal-inner/`: The actual WebSocket connection to `ttyd`.
  - `/auth-check`: The validation endpoint used by the Portal.
- **Unprotected Paths**:
  - `/`: The Portal itself (public access to login screen).
  - `/rstudio-inner/`: RStudio handles its own auth (cookies).
  - `/files-inner/`: Nextcloud handles its own auth (cookies/tokens).

---

## 3. Path Rewriting & Proxying

The system maps backend services running on `localhost` ports to public URL sub-paths.

### 3.1 RStudio Mapping

- **Public**: `/rstudio-inner/`
- **Backend**: `http://127.0.0.1:8787/` (Root)
- **Trick**: We must set `X-RStudio-Root-Path /rstudio-inner` so RStudio knows it is proxied and generates correct links.
- **Cookie Fix**: `proxy_cookie_path` is usually not needed if `www-root-path` is set correctly in RStudio config, but Nginx handles cookie passing explicitly.

### 3.2 Terminal Mapping

- **Public**: `/terminal-inner/`
- **Backend**: `http://127.0.0.1:7681/`
- **Identity**: We pass `X-Forwarded-User $remote_user` to the backend. `ttyd` reads this header to spawn the shell as the correct user (SSO).

### 3.3 Nextcloud Mapping

- **Public**: `/files-inner/`
- **Backend**: `http://NEXTCLOUD_IP/`
- **Config**: Nextcloud's `overwritewebroot` parameter MUST be set to `/files-inner` matches this proxy path.

---

## 4. Important Security Headers

To make the "New Tab" strategy work while staying secure:

- **Wrapper Iframe**:
  - `proxy_hide_header X-Frame-Options`: We hide the backend's frame denial to allow embedding in our wrappers.
- **CSRF Spoofing**:
  - `proxy_set_header Origin $scheme://$host:443`: We tell RStudio the request comes from the HTTPS host, not localhost.
  - `proxy_set_header Referer ...`: We spoof the referer during login to satisfy strict checks.

## 5. Troubleshooting Headers

If services fail to load, check these headers in the browser network tab:

- **X-RStudio-Root-Path**: Must be present for RStudio resources.
- **X-Forwarded-User**: Must be present for Terminal websocket.
- **Connect-Src**: If using CSP, ensure Websockets (`wss://`) are allowed.
