# Security Model & Architecture

## 1. Core Philosophy

The security model of the Botanical Portal is based on **Context Isolation** and **Gateway Enforcement**.
We assume the Frontend (Browser) is untrusted, and the Backend (Services) effectively trusts the Gateway (Nginx).

## 2. Authentication Flow

### 2.1 The Gateway as the PEP (Policy Enforcement Point)

Nginx is the single point of entry for all privileged traffic.

- **Module**: `ngx_http_auth_pam_module`
- **Mechanism**: All requests to `/terminal-inner/` and `/auth-check` are intercepted.
- **Validation**: Nginx offloads verifying the `Authorization: Basic` header to the system PAM stack (SSSD/Samba).
- **Result**: Unauthenticated packets never reach the `ttyd` backend process.

### 2.2 Frontend "Credential Management"

The Portal Frontend (`portal_index.html`) handles credentials **ephemerally**.

- **Input**: User types password in Modal.
- **Transient Storage**: Password exists in a javascript variable `let password` for ~2 seconds.
- **Transmission**:
  - To Nginx: via `fetch()` headers (HTTPS protected).
  - To RStudio: via `POST` body (HTTPS protected).
  - To Terminal: via URL Injection (Sanitized immediately).
- **Storage**: Passwords are **NEVER** stored in `localStorage`, `sessionStorage`, or `Cookies`.

## 3. Isolation Strategy (The "New Tab" Model)

We deliberately avoid `<iframe>` for the main service view to prevent:

1. **Clickjacking**: We allow `X-Frame-Options: DENY` (except where we proxy-strip it for wrappers).
2. **Cookie Leaks**: Services running in `_blank` tabs act as "First Party" contexts.
    - RStudio's `session-id` cookie is `SameSite=Lax` or `Strict`.
    - If embedded in an iframe, browsers would treat it as `Third Party` and block it.

## 4. Network Security

### 4.1 Header Spoofing (The Trusted Proxy Pattern)

Since services run on `localhost` but users access via `public-domain.com`, Nginx must "lie" to the backends to pass their internal security checks (CSRF/CORS).

**Headers Injected by Nginx**:

- `X-Forwarded-Proto https`: Tells backend "User is using Encryption".
- `Origin https://domain.com`: Spoofs the Origin to match the public site (bypassing RStudio's CSRF check).
- `Referer https://domain.com/...`: Spoofs referrer.
- `X-Forwarded-User <username>`: Critical for Terminal identity assertion. The backend trusts this header implicitly, so direct access to backend ports (7681) MUST be blocked by firewall (UFW/IPTables).

## 5. System Hardening

- **Non-Interactive User**: Nginx runs as `www-data`.
- **Strict file permissions**:
  - Config files: `root:root 644`
  - SSL Keys: `root:root 600`
- **Minimal Privileges**: `www-data` is granted group membership (`sasl`, `sambashare`) strictly for the socket/pipe needed for authentication, nothing else.
