# PKI Integration (Step-CA)

This deployment integrates with `Infra-Iam-PKI` (Step-CA) for internal trust and automatic certificate management.

## 1. Trusting the Root CA

All containers (and the Host) need to trust the Step-CA Root Certificate to communicate with internal HTTPS services (e.g., Keycloak, AD via LDAPS).

* **Host**: Run `sudo scripts/manage_pki_trust.sh <URL> <FINGERPRINT>`
* **Containers**: Automatically handled on startup via `entrypoint_rstudio.sh` / `entrypoint_nginx.sh` using `fetch_root.sh`.

## 2. Nginx Certificate Enrollment (ACME/Token)

The Nginx container automatically enrolls a valid certificate for `HOST_DOMAIN` on startup.

### Configuration

In `.env`:

* `STEP_CA_URL`: URL of your Step-CA (e.g., `https://ca.biome.unibo.it:9000`)
* `STEP_FINGERPRINT`: Root CA Fingerprint.
* `STEP_TOKEN`: **Required for first-time enrollment**.

### Generating a Token

On your CA server (Infra-PKI), run:

```bash
./generate_token.sh
# Enter the hostname of this deployment (must match HOST_DOMAIN)
```

Copy the resulting token into `STEP_TOKEN` in `.env`.

### Renewal

The container checks for renewal on every startup (or restart). You can also run `docker exec -it nginx /scripts/pki/enroll_cert.sh ...` manually if needed, but the entrypoint handles this.

## 3. Troubleshooting PKI

* **"Certificate verify failed"**: The Root CA is not in the trust store. Check logs for `fetch_root.sh` errors.
* **"Enrollment failed"**: Check if `STEP_TOKEN` is valid/expired. Tokens are one-time use usually, but renewed certs don't need tokens. If you lost the cert volume (`nginx_certs`), you need a new token.
