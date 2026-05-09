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

Verify with: `systemctl list-timers --all | grep -E 'cleanup|orphan|certbot'`
and `crontab -l -u root`.

---

## 2. Weekly

```bash
# Health snapshot
sudo bash scripts/99_health_check.sh

# Drift scan
sudo bash scripts/99_check_pkg_drift.sh

# Disk pressure
df -h /Rtmp /home /var
```

If the drift scan flags packages, decide:

* **Pin** in `config/r_env_manager.conf :: R_USER_PACKAGES_CRAN` and
  re-run `r_env_manager.sh`.
* **Rebuild** the diverging node from a clean baseline
  ([`CLEAN_VM_BASELINE.md`](CLEAN_VM_BASELINE.md)).

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

### 3.2 Re-render templates (after editing under `templates/`)

```bash
# Nginx
sudo bash scripts/update_nginx_templates.sh
sudo systemctl reload nginx

# R-side dispatcher / fragments / Renviron
sudo bash scripts/50_setup_nodes.sh   # idempotent

# RStudio config
sudo bash scripts/20_configure_rstudio.sh
```

### 3.3 Backup / restore config

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

### 3.4 Domain machine-account refresh

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
