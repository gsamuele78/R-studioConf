# Integrating Infra-Iam-PKI with Botanical RStudio

This document details how the `rstudio-deployment.yaml` integrates with the greater `Infra-Iam-PKI` cluster deployment.

## 1. Domain Join via Sidecar

Instead of the host OS managing the machine trust account, the Winbind sidecar inside the RStudio Pod handles the connection.

* The sidecar requires credentials to join the domain (or an injected Keytab).
* These credentials belong to the `Infra-Iam-PKI` Keycloak/Samba backend.
* They are injected into the cluster by the `deploy_k8s.sh` script reading from `env/.env.prd`. Ensure the `AD_BIND_USER` and `AD_BIND_PASS` variables map to an authorized Join account in the IAM database.

## 2. PKI Trust Bootstrapping

Before RStudio or Nginx even attempt to start, they execute an `initContainer` running the `smallstep/step-cli` tool.

```yaml
initContainers:
  - name: fetch-pki-certs
    image: smallstep/step-cli:0.25.2
    # ...
    command:
      - sh
      - -c
      - |
        until step ca root /certs/step-ca-root.crt --ca-url https://step-ca.pki.svc.cluster.local:9000 ...
```

This ensures that the internal cluster CA (provided by `Infra-Iam-PKI`) is securely downloaded and mounted into the pods, preventing Man-In-The-Middle attacks or SSL validation failures on internal API calls (e.g., routing to Nextcloud or OIDC endpoints).

If the PKI server is offline, the POD safely "fails closed" in the init phase.
