# RStudio Docker Deployment (Dual Backend & Web Portal)

This directory contains the complete infrastructure to deploy RStudio Server in a "Pet Container" mode, fully integrated with your Host's Active Directory (SSSD or Samba), along with a Web Portal.

## Structure matches your project root

* `scripts/`: Mirrored setup scripts + new Docker entrypoints.
* `config/`: Mirrored configuration files.
* `templates/`: Mirrored templates + Docker-specific config templates.
* `lib/`: Shared utilities (`common_utils.sh`).
* `assets/`: Web portal assets (logo, background).

## configuration

All settings are controlled by the `.env` file.

```ini
AUTH_BACKEND=sssd          # Choose 'sssd' or 'samba'
HOST_DOMAIN=botanical.example.com
RSTUDIO_PORT=8787
HOST_HOME_DIR=/home
```

## How to Deploy

### 1. Select Backend

Edit `.env` and set `AUTH_BACKEND` to either `sssd` or `samba` matching your Host's setup.

### 2. Build and Run

Use Docker Compose profiles to launch the correct stack.

**For SSSD Backend:**

```bash
docker compose --profile sssd up -d --build
```

**For Samba Backend:**

```bash
docker compose --profile samba up -d --build
```

**To include the Web Portal:**
Add the `portal` profile.

```bash
docker compose --profile sssd --profile portal up -d --build
```

### 3. Access

* **Web Portal**: `https://<host-domain>` (Requires SSL certs mounted as defined in `.env`)
* **RStudio Direct**: `http://<host-ip>:8787`

## Notes

* **Network Mode Host**: The containers run in host networking mode to transparently use the Host's authentication sockets/pipes.
* **User Persistence**: `/home` is bind-mounted, so RStudio users see their actual Host home directories.
