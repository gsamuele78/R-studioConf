# Configuration Map & Reference

## 1. Overview

The `config/` directory implements the **Separation of Configuration from Code**.
System Administrators should *only* need to edit files in this directory. Scripts read these variables at runtime.

## 2. Configuration Inventory

### Master Environment

- **`r_env_manager.conf`**
  - **Used By**: `r_env_manager.sh`
  - **Controls**: R version, CRAN mirror URL, Package lists.

### System & Identity

- **`optimize_system.vars.conf`**
  - **Used By**: `01_optimize_system.sh`
  - **Controls**: Sysctl params, swap settings.
- **`configure_time_sync.vars.conf`**
  - **Used By**: `02_configure_time_sync.sh`
  - **Controls**: NTP server pool (e.g., `pool.ntp.org`, internal AD DC).
- **`join_domain_samba.vars.conf`**
  - **Used By**: `11_join_domain_samba.sh`
  - **Controls**: AD Domain Name, Realm, Workgroup, OU path.
- **`join_domain_sssd.vars.conf`**
  - **Used By**: `10_join_domain_sssd.sh`
  - **Controls**: SSSD specific parameters (if using SSSD).

### Application Services

- **`configure_rstudio.vars.conf`**
  - **Used By**: `20_configure_rstudio.sh`
  - **Controls**: RStudio License Key, Version Override, Session Timeout.
- **`install_nginx.vars.conf`**
  - **Used By**: `30_install_nginx.sh`
  - **Controls**:
    - `DOMAIN_NAME`: Public FQDN.
    - `SSL_CERT_PATH`: Path to keys.
    - `RSTUDIO_PORT`: Backend port (default 8787).
    - `WEB_TERMINAL_PORT`: Backend port (default 7681).

---

## 3. Best Practices (DevOps Insight)

1. **Secrets Management**:
    - Files containing passwords (like AD join accounts) should be secured with `chmod 600`.
    - *Recommendation*: In future enterprise iterations, replace these with HashiCorp Vault or Env Vart injection.

2. **Immutability**:
    - Scripts source these files on every run. Changing a variable effectively changes the "State definition" of the server. Re-running the script applies the new state.
