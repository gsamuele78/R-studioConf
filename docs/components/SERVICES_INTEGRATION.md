# Service Integration Details

## 1. Overview

Each backend service integrated into the portal has specific configuration requirements to function correctly behind the Nginx reverse proxy.

## 2. RStudio Server

### 2.1 Configuration (`/etc/rstudio/rserver.conf`)

Crucial settings for proxy support:

- `www-address=127.0.0.1`: Listen on localhost only (security).
- `www-port=8787`: Default port.
- `www-root-path=/rstudio-inner`: Tells RStudio it is mounted at a subpath. **This is critical** for resource loading (script tags, css).
- `www-enable-origin-check=1`: Enforces strict Origin checking (we spoof this).
- `auth-pam-require-password-prompt=0`: Allows the automated login via POST to bypass interactive prompts.

### 2.2 Frontend Handshake

- **Method**: `Pro` or `Open` Source version.
- **Authentication**: Cookie-based.
- **Flow**: The Portal `POST`s to `/auth-do-sign-in` with `csrf-token` in body & cookie. RStudio verifies, issues session cookie.
- **Launch**: New tab opens `/rstudio/`.

## 3. Web Terminal (TTYD)

### 3.1 Startup (`/etc/systemd/system/ttyd.service.d/override.conf`)

- **Process**: Runs as root (initially) to allow spawning sessions for any user.
- **Flag**: `--auth-header "X-Forwarded-User"`
  - This tells `ttyd`: "Trust the username in this HTTP header".
- **Security**: Since `ttyd` trusts the header, direct access to port `7681` MUST be blocked. Only Nginx (which performs `auth_pam`) should reach it.

### 3.2 Frontend Handshake

- **Method**: Basic Auth (URL Injection).
- **Flow**: Portal validates credentials against Nginx. If successful, constructs `https://user:pass@host/terminal/`.
- **Cleanup**: The `terminal_wrapper.html` immediately runs `history.replaceState()` to hide the password from the browser URL bar.

## 4. Nextcloud

### 4.1 Configuration (`/var/www/nextcloud/config/config.php`)

- **`trusted_domains`**: Must include the public domain (and `localhost`).
- **`trusted_proxies`**: Must include `127.0.0.1` (Nginx).
- **`overwritewebroot`**: Must be set to `/files-inner`.
  - This tells Nextcloud to generate URLs starting with `/files-inner/` instead of `/`.
- **`overwriteprotocol`**: `https`.

### 4.2 Frontend Handshake

- **Method**: RequestToken + POST.
- **Flow**: Portal fetches login token from `/login`, submits credentials.
- **Session**: Nextcloud sets `nc_session` cookie. New tab shares this cookie.
