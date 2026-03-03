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

---

## 6. Configuration Rationale & Sysadmin Optimizations

The Nginx Gateway includes advanced tuning deployed by the system administrator to resolve specific architectural constraints of the RStudio/TTYD stack:

### 6.1 JSON RPC Buffer Tuning (RStudio)

RStudio Server relies heavily on JSON RPC calls that can produce massive header/payload combinations when serializing large datatables or deep workspace objects.

- **Problem**: Default Nginx proxy buffers are too small, leading to `502 Bad Gateway` errors due to "upstream sent too big header while reading response header from upstream".
- **Solution**: We explicitly inflate `proxy_buffer_size`, `proxy_buffers`, and `large_client_header_buffers` purely for the `/rstudio-inner/` location context to digest RPC blobs seamlessly.

### 6.2 Synchronized Timeouts

Long-running R commands or large package compilations can cause silent connection drops if the proxy timeout falls short of the application timeout limit.

- **Problem**: Nginx default timeout is 60s. RStudio might take 10+ minutes to compile a package.
- **Solution**: The `proxy_read_timeout` and `proxy_send_timeout` are strictly aligned with the RStudio configuration (e.g., dynamically matched during deployment) ensuring developers don't experience spurious disconnects.

### 6.3 Graceful IPv6 / IPv4 Dual-Stack Handling

Many enterprise VPNs or institutional networks drop or mangle IPv6 packets, causing `apt` updates and subsequent Nginx socket bindings to hang.

- **Problem**: Forcing IPv6 on an IPv4-only routed infrastructure creates catastrophic failures.
- **Solution**: The deployment script (`30_install_nginx.sh`) implements a "detect and recover" logic. If IPv6 is unsupported, rather than aborting, the Gateway logic strips all `[::]:80` bindings and reconfigures `sysctl` dynamically, ensuring Nginx acts as a bulletproof IPv4 termination gateway.

### 6.4 Zero-Cache PAM Invocation

The gateway delegates auth to `sasl`/`pam` directly via the `ngx_http_auth_pam_module`.

- **Problem**: Caching auth in regular apps is standard, but in AD ecosystems, group/permission revocation must be immediate.
- **Solution**: We don't employ token-based Nginx caching for the WebSocket terminal (`ttyd`). Every connection handshakes directly through the system socket. The overhead is negligible because the Gateway and PAM daemon share the same UNIX bus.
