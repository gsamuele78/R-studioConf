# RStudio Docker Deployment (Dual Backend & Web Portal)

This directory contains the complete infrastructure to deploy RStudio Server in a "Pet Container" mode, fully integrated with your Host's Active Directory (SSSD or Samba).

## Structure matches your project root

* `scripts/`: Mirrored setup scripts + Docker entrypoints (`entrypoint_nginx.sh` uses `common_utils.sh` logic).
* `config/`: Mirrored configuration files (Reference only; config is in `.env`).
* `templates/`: HTML/CSS/Conf Templates used by the Nginx Entrypoint.
* `lib/`: Shared utilities (`common_utils.sh`).
* `assets/`: Web portal assets (logo, background).
* `doc/`: Sysadmin Architectural Reference, PRD Logic, and Troubleshooting.

## Sysadmin Architecture & PRD Design

Questa implementazione aderisce alle rigorose Best Practice Sysadmin (es. *Non-Optimistic approach*, Kernel Performance Shielding, *Race Condition Mitigation* via `mktemp`).

Per la documentazione architetturale dettagliata:

### Foundation & Operations

* [Deployment Orchestration](doc/deployment/README.md): Compose profiles, Resource limits, e mount policies.
* [Operations & Maintenance](doc/operations/README.md): CLI troubleshooting, Tmpfs lifecycle, e Log live-tail.
* [Developer Reference](doc/developer/README.md): Dockerfile topology, Entrypoint Sandbox (`mktemp`) logic.
* [Configuration Reference](doc/reference/README.md): `.env` 12-Factor variables e Feature flags.

### Security & Architecture

* [System Overview](doc/architecture/SYSTEM_OVERVIEW.md): Pet Container Pattern, BSPM Packages build, Threading Resource Allocation.
* [Security Model](doc/architecture/SECURITY_MODEL.md): `tmpfs` RAM isolation, Host Loopback shielding, Network Policies.
* [Nginx Gateway](doc/components/NGINX_GATEWAY.md): Reverse Proxy, PRD UI Templating, CSRF Auth Flow.
* [OOD & Keycloak Auth](doc/OOD_KEYCLOAK_INTEGRATION.md): Auth-Proxy pattern documentation.
* [PKI Trust Integration](doc/PKI_INTEGRATION.md): Root CA certificate internal propagation.

## Configuration

All settings are controlled by the **`.env`** file.

```ini
AUTH_BACKEND=sssd          # Choose 'sssd' or 'samba'
HOST_DOMAIN=botanical.example.com
RSTUDIO_PORT=8787
HOST_HOME_DIR=/home
```

## How to Deploy

### 1. Automated Deployment (Recommended)

Use the included `deploy.sh` script which validates your `.env` and health-checks the services.

```bash
chmod +x deploy.sh
./deploy.sh
```

### 2. Manual Deployment

Select your backend profile and launch.

**For SSSD Backend + Portal:**

```bash
docker compose --profile sssd --profile portal up -d --build
```

**For Samba Backend + Portal:**

```bash
docker compose --profile samba --profile portal up -d --build
```

### 3. Access

* **Web Portal**: `https://<host-domain>` (Requires SSL certs mounted as defined in `.env`)
* **RStudio Direct**: `http://<host-ip>:8787`

## Components

* **RStudio Pet**: Runs with `network_mode: host` to access Host Auth sockets.
* **Nginx Portal**: Custom build that processes `templates/portal_index.html.template` using `common_utils.sh` logic at startup.
