# Prerequisites & Host Preparation

Before deploying the RStudio Docker stack, the host machine must be joined to the Active Directory domain and configured for correct time synchronization.

## 1. Time Synchronization (Critical)

Kerberos authentication requires the host's clock to be within 5 minutes of the AD Domain Controller.

**Script:** `scripts/02_configure_time_sync.sh`

```bash
# Edit .env to set NTP_PREFERRED_CLIENT (chrony/systemd-timesyncd)
# Run locally on the host:
sudo ./scripts/02_configure_time_sync.sh
```

## 2. Active Directory Join

You must join the host to the AD domain using either **SSSD** or **Samba/Winbind**. This connection is "passed through" to the containers via socket mounting.

### Option A: SSSD (Recommended for Modern Linux)

**Script:** `scripts/10_join_domain_sssd.sh`

1. Ensure `.env` variables for `DEFAULT_AD_DOMAIN_LOWER`, etc., are correct.
2. Run:

    ```bash
    sudo ./scripts/10_join_domain_sssd.sh
    ```

3. Verify: `getent passwd <some_ad_user>`

### Option B: Samba/Winbind (Legacy/Specific Requirements)

**Script:** `scripts/11_join_domain_samba.sh`

1. Run:

    ```bash
    sudo ./scripts/11_join_domain_samba.sh
    ```

2. Verify: `wbinfo -u`

## 3. Kerberos Configuration

Ensure `/etc/krb5.conf` is correctly configured for your realms.

**Script:** `scripts/12_lib_kerberos_setup.sh` (Called automatically by join scripts usually)

## 4. PKI Trust (Step-CA)

The host must trust the internal Step-CA to allow secure communication with internal services (Keycloak, etc.).

**Script:** `scripts/manage_pki_trust.sh`

```bash
# Usage: ./manage_pki_trust.sh <CA_URL> <FINGERPRINT>
sudo ./scripts/manage_pki_trust.sh "https://ca.biome.unibo.it:9000" "your_fingerprint_here"
```

This installs the Root CA into `/usr/local/share/ca-certificates` and updates the system store.
