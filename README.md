# Automated R, RStudio Server & Nginx Reverse Proxy Deployment Kit

![Shell Logo](https://img.shields.io/badge/Shell-Bash-blue)
![OS](https://img.shields.io/badge/OS-Ubuntu%2022.04%2F24.04-orange)
![License](https://img.shields.io/badge/License-GPL3.0-green)
![Compliance](https://img.shields.io/badge/ShellCheck-Compliant-brightgreen)

This repository provides a robust, modular, and automated set of scripts for deploying a production-ready R environment, including R, RStudio Server, Nginx reverse proxy, SSSD+Kerberos authentication, and system optimizations for Ubuntu 22.04/24.04 LTS.

The solution is designed for reproducibility, security, and manageability — leveraging configuration-driven Bash modules, best practices for scientific computing, and safe, idempotent operations (re-runnable scripts).

---

## Core Features

* **Full R Environment Automation:** Installs R (with OpenBLAS & OpenMP), RStudio Server (auto-latest), and a curated set of CRAN/GitHub R packages.
* **Binary Package Support:** Configures BSPM (Binary Package Manager) and R2U, enabling fast system-level R package installs.
* **Nginx Reverse Proxy:** Automates Nginx setup as a secure reverse proxy for RStudio Server, supporting SSL and custom domains.
* **Domain Authentication:** Integrates SSSD and Kerberos for enterprise-grade domain login (Active Directory/LDAP).
* **VM & Performance Tuning:** Includes scripts for optimizing VM deployments (disk, RAM, CPU, overcommit, etc).
* **Safe Logging & Backup:** All actions are logged, and critical files are backed up before modification.
* **Menu & Modularization:** Offers an interactive menu and function-based invocation for each setup component.

---

## Project Structure

The project is organized into a main orchestrator and modular installation scripts under `install/`.

```
.
├── setup_r_env.sh                 # Main orchestrator script (full R, RStudio, Nginx, SSSD, etc)
├── install/
│   ├── common_utils.sh            # Shared Bash utilities and helpers
│   ├── nginx_setup.sh             # Automated Nginx reverse proxy configuration
│   ├── optimize_vm.sh             # VM disk, RAM, CPU tuning
│   ├── rstudio_setup.sh           # Stand-alone RStudio Server install script
│   ├── sssd_kerberos_setup.sh     # SSSD + Kerberos domain authentication setup
│   ├── conf/                      # Directory for configuration templates or overrides
│   └── templates/                 # Directory for script/template assets (SSL, Nginx, etc)
├── LICENSE
└── README.md                      # This documentation
```

---

## Part 1: Full R, RStudio & Nginx Environment Deployment

### Prerequisites

1. **Ubuntu 22.04 or 24.04 LTS** (VM or physical, root/sudo access required).
2. Network connectivity (for CRAN, GitHub, Posit, and system updates).
3. (Recommended) Dedicated VM, especially for production or classroom/multi-user setups.

### Step-by-Step Instructions

#### 1. Clone the Repository

```bash
git clone https://github.com/gsamuele78/R-studioConf.git
cd R-studioConf
```

#### 2. Run the Main Setup Script

By default, the main script provides an interactive menu. For full automation, use the `install_all` action.

```bash
sudo bash setup_r_env.sh install_all
# Or for guided setup:
sudo bash setup_r_env.sh
```

#### 3. Script Actions & Configuration

- **Interactive Menu:** Will guide you through pre-flight checks, CRAN repo, R, OpenBLAS/OpenMP, BSPM, R packages, RStudio Server, and Nginx/SSSD setup.
- **Logging:** Logs are saved to `/var/log/r_setup/`.
- **Backups:** Critical config files are backed up to `/opt/r_setup_backups/`.
- **Environment Variables:** Advanced users can override key paths and settings via environment variables. See the script's `usage()` for details.

#### 4. Verify Installation

- RStudio Server should be available at: `http://<YOUR_SERVER_IP>:8787`
- Nginx (if enabled) will proxy to RStudio and potentially serve SSL if configured.
- Domain logins (via SSSD) should work for authorized users.

---

## Part 2: Component Scripts & Advanced Usage

### install/common_utils.sh

- Shared library of Bash utility functions, logging, error handling, etc.
- Used by all major scripts for safety and DRY principles.

### install/nginx_setup.sh

- Automates installation and configuration of Nginx as a reverse proxy to RStudio Server.
- Supports SSL, custom domains, HTTP → HTTPS redirection, and basic hardening.
- Templates for Nginx config and SSL deployment are in `install/templates/`.

### install/rstudio_setup.sh

- Stand-alone installer for RStudio Server (auto-detects latest version for Ubuntu).
- Handles removal of old versions, service enablement, and logs all actions.

### install/sssd_kerberos_setup.sh

- Automates SSSD and Kerberos configuration for Active Directory or LDAP domain login.
- Manages `/etc/sssd/sssd.conf`, Kerberos keytabs, and PAM/NSS integration.
- Backs up previous configs, verifies domain join, and can be re-run safely.

### install/optimize_vm.sh

- Applies best practices for VM performance (swappiness, noatime, overcommit, etc).
- Optionally prepares disks, tunes memory, and documents VM hardware.

### install/conf/ and install/templates/

- Place your custom config templates (SSL certs, Nginx sites, SSSD, etc) here for overrides.
- The scripts will use these if present, supporting site-specific customization.

---

## Post-Deployment Management

### Updating or Expanding

- **Re-run scripts:** All scripts are idempotent; re-running updates or repairs components without breaking existing configs.
- **Edit templates/configs:** Adjust files under `install/conf/` or `install/templates/` and re-run setup scripts for changes.
- **Add more R packages:** Edit the package lists in `setup_r_env.sh` and re-run the package install step.

### Uninstallation

The main script supports full uninstall:

```bash
sudo bash setup_r_env.sh uninstall_all
```

- Removes R, RStudio Server, Nginx, SSSD configs, CRAN/R2U repos, and user data (with confirmation).
- Backs up configs before removal and logs all actions.

---

## Architectural Decisions

* **Modularity:** Each system (R, RStudio, Nginx, SSSD) is handled by a dedicated script, all sharing utilities and logging.
* **Binary Package Management:** Uses BSPM/R2U to allow fast, system-level R package installation.
* **Domain Security:** SSSD and Kerberos allow enterprise-grade authentication for multi-user RStudio deployments.
* **Reverse Proxy:** Nginx adds security, SSL, and production-readiness to RStudio Server.
* **Safe Defaults:** The scripts use `set -euo pipefail`, backup all files before editing, and provide logs for all actions.

---

## License

This project is licensed under the GPL-3.0 License. See the [`LICENSE`](https://github.com/gsamuele78/R-studioConf/blob/main/LICENSE) file for details.

---

## Acknowledgements

- Uses open source best practices from the R and Linux system administration communities.

