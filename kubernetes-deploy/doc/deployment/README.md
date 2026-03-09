# Deployment Guide: Orchestration & Topology

How to deploy the R-Studio enterprise stack onto a Kubernetes RKE2 cluster using Kustomize and the automated sysadmin pipeline.

## 1. Configuration (Environments & Secrets)

The deployment relies on a strict separation of configuration:

* **Non-Sensitive Logic**: Managed entirely in `configmaps.yaml`.
* **Sensitive Credentials**: Handled via `.env.prd` and dynamically injected into Kubernetes Secrets.

1. Navigate to the `env` directory:

   ```bash
   cd kubernetes-deploy/env
   cp .env.example .env.prd
   ```

2. Edit `.env.prd` and populate the `STEP_CA_FINGERPRINT`, `STEP_TOKEN`, `AD_BIND_PASS`, and the OIDC OpenID Connect Client Secrets.
   > **Note**: Do NOT commit `.env.prd` to version control.

## 2. Infrastructure Validation

Before applying, run the pre-flight linter to ensure all manifests meet Zero-Trust constraints (no privileged sockets, no root executions without capability drops):

```bash
./kubernetes-deploy/scripts/validate_k8s.sh
```

## 3. Deployment Execution

Execute the master wrapper script. This script securely provisions the `secrets.yaml` into memory, creates the namespace, creates PersistentVolumeClaims, and processes the Kustomize tree.

```bash
cd kubernetes-deploy
./scripts/deploy_k8s.sh
```

## 4. Verify Access

Monitor the initialization process (particularly the `fetch-pki-certs` InitContainers).

```bash
kubectl get pods -n botanical -w
```
