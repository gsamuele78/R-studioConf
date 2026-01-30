# Future Roadmap & Migration

## 1. Evolution Strategy

The current architecture ("Static Portal + Nginx Auth") is optimized for **Simplicity, Speed, and Low Maintenance** in a workgroup/lab environment (10-100 users).
To scale to an Enterprise Environment (1000+ users, Zero Trust), we recommend the following migration path.

## 2. Phase 1: Modernize Authentication (OIDC)

**Goal**: Remove password handling from the Portal Frontend completely.

### Current Limitation

The Portal handles user passwords ephemerally in JS. While secure (HTTPS), it is not "Zero Trust".

### Proposed Architecture

**Keycloak / Authentik** as the Identity Provider (IdP).

1. **Deploy IdP**: Connect Keycloak to AD.
2. **Deploy `oauth2-proxy`**: Run this sidecar alongside Nginx.
3. **Flow**:
    - User visits Portal -> Redirected to Keycloak -> Log in.
    - Keycloak redirects back with JWT/Cookie.
    - Nginx verifies Cookie (via `auth_request` to `oauth2-proxy`).
    - Nginx passes `X-Forwarded-User` (from JWT) to backend.
4. **Impact**:
    - Portal becomes purely navigational.
    - "Secure Connect" modal removed.
    - SSO is handled entirely by standard OIDC flows.

## 3. Phase 2: Containerization (Kubernetes)

**Goal**: Resource isolation and scalability.

### Current Limitation

All users share the same RStudio Server process and system resources (RAM/CPU). One heavy job affects everyone.

### Proposed Architecture

**JupyterHub / RStudio Connect on K8s**.

1. **Architecture**: The Portal becomes a "Spawner" interface.
2. **Flow**: Login -> Spawn Personal Pod -> Proxy traffic to Pod IP.
3. **Technology**:
    - **Helm Charts**: Standard deployment.
    - **Zero-to-JupyterHub**: Standard guide (works for RStudio too).
4. **Benefit**:
    - Hard limits per user (e.g., 4GB RAM).
    - Custom images per user (Data Science vs. BioInformatics).

## 4. Phase 3: Infrastructure as Code (IaC)

**Goal**: Reproducibility and Audit.

### Current Limitation

Shell scripts (`scripts/`) are imperative.

### Proposed Migration

**Ansible / Terraform**.

1. **Ansible**: Convert `01_optimize_system.sh` -> System Roles. Convert `30_install_nginx.sh` -> Nginx Role.
2. **Terraform**: Provision underlying VMs/Cloud logical resources.
3. **CI/CD**: GitOps workflow. Push to `main` -> Ansible applies config.

## 5. Summary

| Feature | Current | Enterprise Target |
| :--- | :--- | :--- |
| **Auth** | PAM / Basic | OIDC / SAML (Keycloak) |
| **Compute** | Shared Host | Container per User (K8s) |
| **Deploy** | Bash Scripts | Ansible / FluxCD |
| **Proxy** | Nginx | Traefik / Ingress |
