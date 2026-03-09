# R-Studio RKE2 Kubernetes Architecture

*Document Version: 1.0 (Sysadmin Target)*

## 1. Overview

The `kubernetes-deploy` folder contains the production-grade manifests for running the Botanical R-Studio Portal on a Kubernetes (RKE2) cluster.

Unlike the legacy Docker Compose approach, this deployment utilizes **Zero-Trust, Pessimistic Container Engineering**.

## 2. Directory Structure

```text
kubernetes-deploy/
├── configmaps.yaml             # Non-sensitive configuration (Nginx, Samba, RStudio)
├── doc/                        # Comprehensive documentation (this folder)
├── env/                        # Local environment templates (.env.example) NOT commited to git
├── ingress.yaml                # Traefik/Nginx routing rules
├── kustomization.yaml          # The master Kustomize entrypoint tying all manifests together
├── namespace.yaml              # Enforces the `botanical` isolation boundary
├── nginx_proxy_location.conf   # Optimized Nginx proxy logic for the portal
├── oauth2-proxy-deployment.yaml# Subsystem for OIDC integration
├── ollama-deployment.yaml      # AI Engine with isolated PVC storage
├── portal-deployment.yaml      # The frontend Nginx interface
├── rstudio-deployment.yaml     # Core logic containing the Winbind Sidecar and RStudio App
├── secrets.yaml                # Generated dynamically by deploy_k8s.sh
├── storage.yaml                # PersistentVolumeClaims for NFS mappings
├── telemetry-api-deployment.yaml # K8s native metrics viewer (no docker.socket)
├── scripts/
│   └── deploy_k8s.sh           # The Master Sysadmin Deployment Executor
└── validate_k8s.sh             # Linting and syntax verification pipeline
```

## 3. The Sysadmin Winbind Sidecar Pattern

The most significant architectural change from Docker is how RStudio authenticates against Active Directory (`Infra-Iam-PKI`).

1. **No Host Dependency:** K8s worker nodes DO NOT need to be joined to the AD domain.
2. **Sidecar Injection:** The `rstudio-deployment.yaml` runs a dedicated `ubuntu` container executing `winbindd`.
3. **Socket Sharing:** An `emptyDir` mounts `/var/run/samba` between the Winbind sidecar and the RStudio container. RStudio performs PAM lookups against this internal socket.
4. **NFS ID Mapping Consistency:** The `configmaps.yaml` injects a strict `smb.conf` into the sidecar, forcing `tdb` / `ad` ID mapping. This guarantees that `DOCKER_USERID` mappings translate perfectly to the NFS file ownership on the `home` and `projects` PVCs.

## 4. Deployment Lifecycle

Administrators **MUST NOT** deploy manifests with raw `kubectl` without generating secrets first.
Always use the provided deployment tool:

```bash
cd kubernetes-deploy
# 1. Prepare environment
cp env/.env.example env/.env.prd
nano env/.env.prd

# 2. Deploy
./scripts/deploy_k8s.sh
```

## 5. Security Posture

* **Capability Drops**: All `runAsUser: 0` pods immediately drop `CAP_SYS_ADMIN`, `SYS_CHROOT` (from RStudio), and `NET_BIND_SERVICE` (by shifting Nginx to internal port `8443` running as `UID 101`).
* **Non-Optimistic Initialization**: The RStudio container features a shell `postStart` lifecycle hook (`until wbinfo -p; do sleep 2; done`) protecting against race conditions if the AD sidecar boots slowly, ensuring PAM lookups never fail randomly on startup.
* **Noisy Neighbor Protection**: AI engine limits (Ollama) are brutally constrained to `2500m` CPU to prevent scheduler starvation across the Kubernetes worker nodes.
* **Telemetry via API**: The legacy Telemetry API which relied on mounting `/var/run/docker.sock` has been completely rewritten. It now uses a K8s `ServiceAccount` and `ClusterRoleBinding` to query metrics securely from the `metrics.k8s.io` API.
* **Enterprise Web Security**: Nginx natively injects strict `HSTS`, `X-Frame-Options`, and `Content-Security-Policy` HTTP headers on all proxied traffic.
* Probes are strictly non-optimistic (e.g., Nginx will not report `Ready` until the TCP socket actually opens).
