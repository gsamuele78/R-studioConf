<!-- docs/operations/MAINTENANCE.md -->
# Maintenance Runbook

> **Audience:** sysadmins.  
> **Tier:** T1 host.  
> **Last updated:** 2026-05-09.

Routine maintenance tasks, in approximate order of frequency.

---

## 1. Daily / scheduled (already automated)

These are wired into cron / systemd-timer by the deployment scripts.
Verify they are still running on each host.

| Job | Installed by | Schedule source | What it does |
|---|---|---|---|
| Nginx tmp cleanup | `15_setup_nginx_cleanup.sh` | daily cron | Trim `client_body_temp` / `proxy_temp` with disk safety check. |
| R orphan cleanup | `50_setup_nodes.sh` (deploys `cleanup_r_orphans.sh.template`) | `setup_nodes.vars.conf :: ORPHAN_CRON_CLEANUP` | Kill rsession workers whose parent ttys/RStudio sessions are gone. |
| R orphan notify | same | `ORPHAN_CRON_NOTIFY` | Email user before kill (per `user_email_map.txt`). |
| R orphan report | same | `ORPHAN_CRON_REPORT` | CSV + email to `admin_recipients.txt`. |
| Let's Encrypt renewal | `32_setup_letsencrypt.sh` | certbot.timer | Renew + nginx reload. |
| Package drift scan | (manual or cron) | — | `99_check_pkg_drift.sh` — recommend weekly. |
| Renviron override scan | (manual) | — | `99_check_user_renviron_overrides.sh` — after deploys or when users report env mismatches. |

Verify with: `systemctl list-timers --all | grep -E 'cleanup|orphan|certbot'`
and `crontab -l -u root`.

---

## 2. Weekly

```bash
# Health snapshot
sudo bash scripts/99_health_check.sh

# Drift scan
sudo bash scripts/99_check_pkg_drift.sh

# Renviron override scan (user-side env drift)
sudo bash scripts/99_check_user_renviron_overrides.sh

# Disk pressure
df -h /Rtmp /home /var

# Nginx package drift check (prevent auth_pam regression)
dpkg -l | grep -E 'nginx|auth-pam'
apt-mark showhold | grep -E 'nginx|auth-pam'
```

If the drift scan flags packages, decide:

* **Pin** in `config/r_env_manager.conf :: R_USER_PACKAGES_CRAN` and
  re-run `r_env_manager.sh`.
* **Rebuild** the diverging node from a clean baseline
  ([`CLEAN_VM_BASELINE.md`](CLEAN_VM_BASELINE.md)).

### 2.1 Nginx package drift guard

Ubuntu `unattended-upgrades` can move nginx to a version that is
incompatible with `libnginx-mod-http-auth-pam`, causing worker segfaults
on portal login. The known-good version is `1.24.0-2ubuntu7.9`; the
known-bad version is `1.24.0-2ubuntu7.10`.

**Verify on every node:**

```bash
dpkg -l | grep -E 'nginx|auth-pam'
# Expected:
#   nginx                       1.24.0-2ubuntu7.9
#   nginx-common                1.24.0-2ubuntu7.9
#   nginx-full                  1.24.0-2ubuntu7.9
#   libnginx-mod-stream         1.24.0-2ubuntu7.9
#   libnginx-mod-http-auth-pam  1:1.5.5-2build2

apt-mark showhold | grep -E 'nginx|auth-pam'
# Expected: all five packages listed

ls /etc/apt/preferences.d/99-block-nginx-bad.pref
# Expected: file exists with Pin-Priority: -1 for 1.24.0-2ubuntu7.10
```

> **Important:** APT ignores files in `/etc/apt/preferences.d/` with
> invalid extensions. Use `.pref` or no extension. The filename
> `99-block-nginx-2ubuntu7.10` is silently ignored because `.10` is
> not a recognised preferences extension.

**If a node has the bad version**, downgrade using `dpkg-repack` from a
working node. Full procedure:
[`NGINX_AUTH_PAM_REGRESSION_2026-06.md`](NGINX_AUTH_PAM_REGRESSION_2026-06.md).

**To protect a node that is still on the good version:**

```bash
sudo apt-mark hold nginx nginx-common nginx-full libnginx-mod-stream libnginx-mod-http-auth-pam

sudo tee /etc/apt/preferences.d/99-block-nginx-bad.pref >/dev/null <<'EOF'
Package: nginx nginx-common nginx-full libnginx-mod-stream
Pin: version 1.24.0-2ubuntu7.10
Pin-Priority: -1
EOF
```

---

## 3. Monthly / on-demand

### 3.1 R / RStudio version bump

```bash
# r_env_manager.sh consults 21_helper_rstudio_version.sh; idempotent.
sudo ./r_env_manager.sh

# Post-bump audit
sudo bash scripts/99_audit_r_environment.sh
```

After the bump:

* Re-run `50_setup_nodes.sh` to refresh `/etc/R/Rprofile.site` and
  `/etc/R/Rprofile_site.d/*` against the new R.
* Smoke-test with `bash scripts/test_rstudio_login.sh`.

### 3.2 Apply Rprofile v12.4 (Lussu fork-guard + NFS lookup-storm fix)

For the procedure on new and already-deployed nodes, plus rollback and
per-user bypass, see the dedicated runbook:
[`UPGRADE_TO_v12.4.md`](UPGRADE_TO_v12.4.md).

Quick reference:

```bash
sudo bash scripts/50_setup_nodes.sh   # menu option L = local R-libs + NFS audit only
sudo bash scripts/50_setup_nodes.sh --verify   # expect: Rprofile.site version: 12.4
```

Optional: pre-create a dedicated `/var/lib/biome-Rlibs/` disk by
setting `R_LIBS_LOCAL_DEVICE=/dev/sdX` in `setup_nodes.vars.conf` before
running the script (Mode B; idempotent fstab via UUID).

### 3.3 Re-render templates (after editing under `templates/`)

```bash
# Nginx
sudo bash scripts/update_nginx_templates.sh
sudo systemctl reload nginx

# R-side dispatcher / fragments / Renviron
sudo bash scripts/50_setup_nodes.sh   # idempotent

# RStudio config
sudo bash scripts/20_configure_rstudio.sh
```

### 3.4 Backup / restore config

`r_env_manager.sh` rotates each managed config to
`/var/backups/r_env_manager/files/<full-path>.<timestamp>` before
rewriting it.

```bash
ls -lt /var/backups/r_env_manager/files/etc/rstudio/
# Roll back rserver.conf:
sudo cp /var/backups/r_env_manager/files/etc/rstudio/rserver.conf.<TS> \
        /etc/rstudio/rserver.conf
sudo systemctl restart rstudio-server
```

Rotate `/var/backups/r_env_manager/files/` per your retention policy
(no automatic prune is shipped, by design — destructive default would
violate pessimistic engineering).

### 3.5 Domain machine-account refresh

Active Directory rotates the computer-object password periodically.
After ~30 days, refresh:

```bash
sudo bash scripts/11_join_domain_samba.sh    # Samba/winbind backend
# or
sudo bash scripts/10_join_domain_sssd.sh     # SSSD backend
```

Both scripts are idempotent — they detect "already joined" and just
refresh the keytab + restart the daemon.

---

## 4. Quarterly

### 4.1 Clean-VM baseline test

Build a fresh VM from scratch following [`CLEAN_VM_BASELINE.md`](CLEAN_VM_BASELINE.md);
diff package versions and `R --version` against production.

### 4.2 Audit drift

```bash
sudo bash scripts/99_audit_r_environment.sh   # full report
diff -u <previous-audit.md> <new-audit.md>
```

Investigate any unexplained delta.

### 4.3 PAM stack verification

Even if `passwd` works today, regression can creep in via
`unattended-upgrades`. Run:

```bash
sudo bash scripts/fix_pam_segfault_inplace.sh --check
```

If it reports anything other than CLEAN, run without `--check`.

---

## 5. Emergency rollback

If a config change broke production:

1. Stop the service (`systemctl stop nginx`, etc.).
2. List backups: `ls -lt /var/backups/r_env_manager/files/<path>/`.
3. Copy the most recent pre-change snapshot back into place.
4. Restart the service.
5. File a follow-up ticket — the rollback is temporary; the underlying
   bug must still be fixed in T1 (and ported to T2/T3 per
   `.ai/project.yml :: tier_deltas`).

---

## 6. Logs & retention

| Path | Owner | Retention |
|---|---|---|
| `/var/log/biome-log/core/*.log` | r_env_manager | rotate via logrotate (default) |
| `/var/log/rstudio-server/*` | rstudio-server | logrotate |
| `/var/log/nginx/*` | nginx | logrotate |
| `/var/log/secure_access/*` | ttyd wrapper | logrotate |
| `/var/log/sssd/*` | sssd | logrotate |
| `/var/log/samba/*` | samba | logrotate |
| `/var/backups/r_env_manager/files/*` | r_env_manager | **manual** prune |
| `${BIOME_CONF}/audit/*` | 99_audit_r_environment | manual |
| `${BIOME_CONF}/pkg_drift/baseline.csv` | 99_check_pkg_drift | manual |

Full log inventory: [`diagnostic_logs.md`](diagnostic_logs.md).

---

## 7. Cross-references

* Symptom-indexed runbook → [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md)
* Diagnostic toolbox → [`DIAGNOSTICS_INDEX.md`](DIAGNOSTICS_INDEX.md)
* Clean-VM baseline procedure → [`CLEAN_VM_BASELINE.md`](CLEAN_VM_BASELINE.md)
* Lussu hang investigation → [`LUSSU_HANG_BISECTION.md`](LUSSU_HANG_BISECTION.md)
* User-script triage → [`USER_SCRIPT_TROUBLESHOOTING.md`](USER_SCRIPT_TROUBLESHOOTING.md)
* Quotas & limits → [`USER_QUOTAS_AND_RESOURCES.md`](USER_QUOTAS_AND_RESOURCES.md)
* Storage growth → [`add_storage_no_reboot.md`](add_storage_no_reboot.md)
* PAM hardening → [`../deployment/PAM_HARDENING.md`](../deployment/PAM_HARDENING.md)
