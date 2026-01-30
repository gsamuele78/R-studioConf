# Script Repository Catalog

## 1. Orchestration Core

### `r_env_manager.sh`

**Path**: Root `/`
**Type**: Master Orchestrator (Monolithic)
**Audience**: System Administrators
**Description**:
This is the "Grand Parent" script. It manages the high-level lifecycle of the R Environment.

- **Idempotency**: Safe to run multiple times. Uses lock files (`/var/run/r_env_manager.lock`).
- **State Management**: Tracks installation state in `/var/lib/r_env_manager`.
- **Function**: Orchestrates R installation, CRAN/BSP setup, RStudio Server installation, and OpenBLAS optimization.
- **Insight**: This script is definitive for the *R Environment* itself, whereas the `scripts/` folder manages the *Platform* (Nginx, Auth, Portal).

### `lib/common_utils.sh`

**Path**: `/lib/`
**Type**: Shared Library
**Description**:
Contains universal helper functions sourced by almost all other scripts.

- `log()`: Standardized logging with colors.
- `run_command()`: Wrapper for command execution with error handling.
- `check_root()`: Safety check.
- `setup_noninteractive_mode()`: Critical for automated apt installs (suppresses man-db updates).

---

## 2. Modular Deployment Scripts (`scripts/`)

These scripts follow a **Phased Execution Model** (00-99). They are designed to be run sequentially or individually for targeted maintenance.

### Phase 0: System Prep

- **`01_optimize_system.sh`**: Disables interfering services (unattended-upgrades in foreground), sets sysctl performance parameters.
- **`02_configure_time_sync.sh`**: Ensures accurate NTP (Chrony/Timesyncd) crucial for Kerberos/AD auth.
- **`03_install_secure_access.sh`**: Hardens SSH (likely).

### Phase 1: Identity & Domain

- **`10_join_domain_sssd.sh`**: Automates Active Directory join via SSSD (RedHat style).
- **`11_join_domain_samba.sh`**: Automates AD join via Winbind/Samba (used by this architecture).
- **`12_lib_kerberos_setup.sh`**: Library functions for handling Kerberos ticket request/renewal.

### Phase 2: RStudio & Backend

- **`20_configure_rstudio.sh`**:
  - Installs RStudio Server.
  - Configures `rserver.conf` and `rsession.conf`.
  - Sets up PAM profiles.
- **`21_helper_rstudio_version.sh`**: Scrapes the Posit website to find the latest version URL for the current OS.

### Phase 3: Gateway & Frontend

- **`30_install_nginx.sh`**:
  - Installs Nginx.
  - Compiles/Enables `libpam-nginx` module for `auth_pam`.
  - Deploys SSL certificates.
- **`31_setup_web_portal.sh`**:
  - **The Portal Generator**.
  - Reads `templates/portal_index.html.template`.
  - Injects variables (Years, Paths).
  - Deploys the static HTML site to `/var/www/html`.
- **`32_setup_letsencrypt.sh`**: Automates Certbot/ACME setup for public SSL.

### Phase 4: Telemetry

- **`40_install_telemetry.sh`**: Sets up Prometheus Node Exporter or custom Python telemetry agents (`scripts/telemetry/`).

### Phase 9: Verification

- **`99_verify_domain_join.sh`**: Diagnostics script to test AD connectivity (`wbinfo`, `id user`).
- **`99_health_check.sh`**: General system status report.

---

## 3. Helper Scripts

- **`ttyd_login_wrapper.sh`**: Used by `ttyd` systemd service to validate users passed via Nginx.
- **`update_nginx_templates.sh`**: Utility to hot-reload Nginx templates without full reinstall.
- **`test_rstudio_login.sh`**: Synthesizes a login request to debug RStudio connectivity.
