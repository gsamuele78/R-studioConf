# Botanical Portal Documentation

Welcome to the technical documentation library for the **Botanical Big Data Calculus Portal**.
This library provides comprehensive guides for System Engineers and Developers.

## 📚 Documentation Tree

### 1. Architecture

- **[System Overview](architecture/SYSTEM_OVERVIEW.md)**: High-level design, component diagram, and core concepts.
- **[Security Model](architecture/SECURITY_MODEL.md)**: Authentication flows, isolation strategies, and Nginx hardening.

### 2. Component Guides

- **[Nginx Gateway](components/NGINX_GATEWAY.md)**: Configuration deep-dive, headers, and rewrite rules.
- **[Portal Frontend](components/PORTAL_FRONTEND.md)**: HTML structure, JavaScript auto-login logic, and CSS responsiveness.
- **[Service Integration](components/SERVICES_INTEGRATION.md)**: integration details for RStudio Server, TTYD Terminal, and Nextcloud.

### 3. Deployment & Configuration

- **[Installation Guide](deployment/INSTALLATION_GUIDE.md)**: Step-by-step deployment instructions using the script library.
- **[Configuration Reference](deployment/CONFIGURATION_REFERENCE.md)**: Explanation of variable files (`.vars.conf`) and templates.

### 4. Operations

- **[Troubleshooting](operations/TROUBLESHOOTING.md)**: Common errors, diagnostic steps, and log locations.
- **[Maintenance](operations/MAINTENANCE.md)**: Routine updates, certificate management, and health checks.

### 5. Reference (Deep Dive)

- **[Script Catalog](reference/SCRIPT_CATALOG.md)**: Inventory of all repository scripts and their functions.
- **[Configuration Map](reference/CONFIGURATION_MAP.md)**: Guide to `.vars.conf` files.
- **[Template Gallery](reference/TEMPLATE_GALLERY.md)**: Details on Nginx and System templates.
- **[Nginx Auth Backends](reference/NGINX_AUTH_BACKENDS.md)**: Deep dive into SSSD vs Samba PAM integration.

### 6. Roadmap & Evolution

- **[Future Migration](FUTURE_MIGRATION.md)**: Path to OIDC, Kubernetes, and Ansible adoption.

---

*This documentation is maintained in the `docs/` directory of the repository.*
