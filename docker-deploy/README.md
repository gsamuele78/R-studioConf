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

**Optional: GitHub token for the R package build.** The `rstudio-*` images install
R packages from GitHub, and unauthenticated GitHub API calls are capped at 60 per
hour per IP. A shared or NATed IP can exhaust that and fail the build with
`HTTP error 403 ... API rate limit exceeded`. To build authenticated, export a
token in the shell that runs the build (a fine-grained token with public read
access is enough):

```bash
read -rs GITHUB_PAT && export GITHUB_PAT
docker compose --profile sssd --profile portal up -d --build
```

Compose passes it as the BuildKit secret `github_pat`, mounted only for the
package install step and never stored in an image layer. Unset, the build runs
unauthenticated as before. Do not write the token into `.env`.

### 3. Access

* **Web Portal**: `https://<host-domain>` (Requires SSL certs mounted as defined in `.env`)
* **RStudio Direct**: `http://<host-ip>:8787`

## Components

* **RStudio Pet**: Runs with `network_mode: host` to access Host Auth sockets.
* **Nginx Portal**: Custom build that processes `templates/portal_index.html.template` using `common_utils.sh` logic at startup.
