# Scripts Reference: Deployment Orchestration

The `scripts/` directory contains the executable bash scripts responsible for the complete lifecycle of the server from a bare-metal Ubuntu installation to a fully functional RStudio/Terminal/Nextcloud gateway domain-joined to Active Directory.

## 1. Execution Order (The Numbering Convention)

Scripts are prefixed with numbers to dictate the strict deployment sequence. Running them out of order guarantees failure due to missing dependencies.

* `0x_`: Foundation & Prerequisites
* `1x_`: Active Directory & Identity
* `2x_`: Core Dependencies
* `3x_`: Web Services (Nginx, Certs, Portal)
* `4x_`: System Services (Telemetry, Monitoring)
* `5x_`: Environment & Data Orchestration (R, Python, Master Setup)
* `99_`: Diagnostics & Health Checks

---

## 2. Core Scripts Breakdown

This section documents the primary logic, inputs, and architectural significance of critical scripts.

### 2.1 Identity & Access

The backbone of the SSO integration.

#### `10_join_domain_sssd.sh`

* **Role**: Joins the server to Active Directory using SSSD and realmd.
* **Mechanism**: Detects DNS resolution for `AD_DOMAIN_LOWER`. Uses `kinit` to acquire a Kerberos ticket for the Domain Admin, then executes `realm join`. Configures SSSD (`/etc/sssd/sssd.conf`) for `ad_gpo_access_control = permissive` to allow shell access for AD users.
* **Sysadmin Note**: Automatically patches `/etc/pam.d/common-session` to include `pam_mkhomedir.so`, ensuring user homes are generated on their first Nginx/TTYD login if they don't exist on the NFS mount.

#### `11_join_domain_samba.sh`

* **Role**: Legacy alternative to SSSD using Winbind/Samba.
* **Mechanism**: Replaces SSSD entirely. Edits `/etc/nsswitch.conf` directly. Used only if SSSD fails to interact correctly with specific institutional AD trust policies.

### 2.2 The Web Gateway

The public face of the system.

#### `30_install_nginx.sh`

* **Role**: Installs Nginx and configures the `auth_pam` module.
* **Mechanism**: Compiles or installs the `libnginx-mod-http-auth-pam` package. Uses the `__process_template` function to inject exact paths (`/rstudio-inner/`, `/terminal-inner/`) and synchronized timeouts into the virtual host configuration.
* **Optimization**: Contains a specific "detect and recover" IPv6 loop. If `sysctl` cannot bind `[::]:80` because kernel IPv6 is disabled, it patches the Nginx config to be IPv4-only rather than failing.

#### `31_setup_web_portal.sh`

* **Role**: Deploys the static HTML/JS/CSS frontend.
* **Mechanism**: Copies contents from `assets/` to `/var/www/html/portal`. Replaces placeholder URLs in the JS payloads and configures the customized modal login layouts.

#### `32_setup_letsencrypt.sh`

* **Role**: Provisions SSL certificates via Certbot for public instances, or configures the dummy Snakeoil certs for intranet testing.

### 2.3 Environmental Orchestration

The heaviest and most complex layer.

#### `50_setup_nodes.sh`

* **Role**: The "Master Node Setup". Orchestrates all data science dependencies.
* **Execution**:
    1. **System Tuning**: Generates instantaneous swap space via `fallocate` bypassing slow `dd` operations.
    2. **RAMDisk**: Mounts `/tmp` as a `tmpfs` RAMDisk (e.g., 100GB) to massively accelerate R package compilation (`gcc` I/O offloading).
    3. **Kernel BLAS**: Detects CPU flags via `lscpu` to dynamically link the correct OpenBLAS target (avoids QEMU livelocks by locking threads to hardware cores).
    4. **Package Management**: Isolates all `Rscript` execution via secure `mktemp` wrapper scripts. Builds the `bspm` (Bridge to System Package Manager) to route `install.packages()` requests to the high-performance Ubuntu `apt` cache.
    5. **Security**: Replaces legacy `eval()` interpolation with fixed Heredoc (`<<EOF`) payloads to prevent arbitrary code execution during build time.

#### `r_env_manager.sh` (Root level)

* **Role**: Operational tool for upgrading Java/R environments post-deployment.
* **Security**: Like `50_setup_nodes.sh`, it employs `mktemp` to generate arbitrary temporary workspaces safely, avoiding `.Rprofile` hijacking by underprivileged users.

### 2.4 Monitoring & Telemetry

#### `40_install_telemetry.sh`

* **Role**: Installs Node Exporter and the custom Python FastAPI telemetry endpoint.
* **Architecture**: Wraps the Python API inside a distinct Virtual Environment (`/opt/custom_api_env`). Exposes port 8000 internally.
* **Optimization**: Configures the FastAPI router with a `ThreadpoolExecutor` to perform heavy `subprocess.run` OS shell-outs asynchronously, guaranteeing the Nginx proxy doesn't time out while waiting for disk I/O metrics.

### 2.5 Diagnostics

#### `99_health_check.sh`

* **Role**: Full system audit.
* **Mechanism**: Probes Samba/SSSD process status, evaluates pam.d configurations vs Nginx capabilities, tests PAM AD authentication credentials silently, and verifies SSL expiration dates.

#### `99_audit_r_environment.sh`

* **Role**: Verifies the internal consistency of the R runtime.
* **Mechanism**: `mktemp` injects an R-script that proves `future` parallelization counts matches the detected `cgroups`/limits, and verifies `reticulate` binds correctly to the Python geospatial virtual environment.
