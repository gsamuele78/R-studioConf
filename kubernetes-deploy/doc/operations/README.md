# Operations & Maintenance Guide (Kubernetes)

Common failure domains and resolution steps for the `kubernetes-deploy` implementation.

## 1. Winbind Sidecar Failures (Authentication Loss)

**Symptom:** Users cannot log in to RStudio. `wbinfo` returns connection errors.

**Diagnosis:**

```bash
kubectl logs deployment/rstudio -c winbind-sidecar -n botanical
```

* **Error**: `NT_STATUS_IO_TIMEOUT` o `Cannot contact KDC`.
  **Resolution**: The pod cannot route to the Domain Controllers. Check network policies or the `krb5.conf` provided in `configmaps.yaml` to ensure the internal DNS suffix is valid.
* **Error**: `NT_STATUS_LOGON_FAILURE`.
  **Resolution**: The `AD_BIND_USER` and `AD_BIND_PASS` in `env/.env.prd` are invalid or the account is locked in Keycloak/AD.

## 2. RStudio Container Hangs in ContainerCreating (Race Condition Lock)

**Symptom:** The `rstudio` container never reaches `Running` state and `kubectl describe pod` shows it's stuck waiting on the `postStart` hook.

**Diagnosis:**
The Phase 2 sysadmin hardening forces RStudio to wait for Winbind to respond to `wbinfo -p`. If Winbind fails to start or connect to AD, the RStudio initialization loop will hang indefinitely to prevent optimistic booting.

**Resolution**:

1. Abort checking the RStudio container logs and check the sidecar logs instead: `kubectl logs deployment/rstudio -c winbind-sidecar -n botanical`.
2. Winbind is failing to provision the AD trust. Resolve the AD connectivity issue (see Section 1). Once Winbind replies to `wbinfo -p`, the `postStart` hook will automatically release and RStudio will boot.

## 3. InitContainer Hangs (PKI Trust)

**Symptom:** RStudio or Nginx Portal pods stay stuck in `Init:0/1` state indefinitely.

**Diagnosis:**

```bash
kubectl logs deployment/rstudio -c fetch-pki-certs -n botanical
```

**Resolution**: The Step-CA token has likely expired (they are one-time use), or the fingerprint is incorrect. Generate a new JWT token from the `Infra-Iam-PKI` deployment and update `.env.prd`. Run `./scripts/deploy_k8s.sh` again to overwrite the Secret.

## 4. Persistent Volume Mount Failures

**Symptom:** Pod fails to start, throwing `FailedMount` errors in Events.

**Diagnosis:**

```bash
kubectl describe pod -l app=rstudio -n botanical
```

**Resolution**:
Review the `storage.yaml` file. The underlying CSI driver may not support the requested `accessModes` (for instance, EBS volumes do not support `ReadWriteMany`, while EFS/NFS does).

## 5. Telemetry API Permission Denied

**Symptom:** Telemetry API logs show HTTP 403 Forbidden when trying to fetch cluster metrics.

**Diagnosis:**
Ensure that the `ClusterRoleBinding` deployed in `telemetry-api-deployment.yaml` successfully bound the `telemetry-sa` to the `telemetry-metrics-reader` role.
Verify that the `metrics-server` daemon is actually running on the RKE2 cluster to service `metrics.k8s.io` requests.
