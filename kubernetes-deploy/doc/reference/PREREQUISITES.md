# Prerequisites & Cluster Preparation

Before deploying the RStudio Kubernetes stack, the target RKE2 cluster must be configured to support the specific storage and identity requirements.

## 1. Internal PKI Trust (Step-CA)

The R-Studio pods use `InitContainers` to securely fetch Root Certificates from the `Infra-Iam-PKI` Step-CA instance dynamically.

* The `STEP_CA_FINGERPRINT` and `STEP_TOKEN` must be populated in `env/.env.prd`.
* Ensure that the DNS name `step-ca.pki.svc.cluster.local` resolves correctly from the `botanical` namespace.

## 2. Storage Provisioning (CSI Driver)

Unlike the Docker Compose deployment which relied on local host directories, Kubernetes requires a Container Storage Interface (CSI) driver to provision `PersistentVolumeClaims`.

Ensure your cluster has a default StorageClass capable of `ReadWriteMany` (RWX) if you plan on scaling the RStudio deployment, usually backed by an external NFS cluster (like TrueNAS or NetApp).

* `/nfs/home`: Mount point for users.
* `/opt/r-geospatial`: Target for Python venvs and Geo-Libraries.

## 3. Kubernetes Ingress Controller

The stack no longer binds directly to `80/443` on the host interfaces (`network_mode: host` is deprecated).

An Ingress Controller must be running on the RKE2 cluster to evaluate `botanical-ingress`.

* **Traefik** (RKE2 default): Supported naturally.
* **NGINX Ingress**: Annotated in `ingress.yaml`. Make sure TLS Passthrough is enabled if terminating at the Portal pod.

## 4. Active Directory Connectivity

The Worker Nodes themselves do **NOT** need to be joined to Active Directory.
The `winbind-sidecar` inside the R-Studio pod handles the Active Directory join exclusively for the application pod, protecting node immutability. Ensure that the Kubernetes CNI allows traffic out to the Domain Controllers over LDAP (tcp/389) and Kerberos (tcp/udp/88).
