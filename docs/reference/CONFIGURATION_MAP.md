<!-- docs/reference/CONFIGURATION_MAP.md -->
# Configuration Map (T1 Host)

> **Tier:** T1 host configuration. Authoritative.  
> **Last updated:** 2026-06-19 (site-local overlay introduced; see §0 + CHANGELOG).

Every numbered phase script in `scripts/` reads exactly one
`config/<name>.vars.conf` (plus, optionally, `lib_kerberos_setup.vars.conf`
for Kerberos-aware scripts). The table below is the complete map. Variables
are bash-style `KEY=VALUE` and are sourced — never `eval`'d.

> **Hard rule (HR-12):** `.env` files and any concrete secret/PII values **MUST
> NOT** be committed. The repo ships sanitized `*.example` templates; real site
> values live in the gitignored `config/site/` overlay (see §0 and
> [`../../config/SITE_OVERRIDE.md`](../../config/SITE_OVERRIDE.md)).

---

## 0. Site-local config overlay (since 2026-06-19)

Files carrying AD topology, third-party PII, or institutional contacts are **not
committed**. The repo ships `<name>.example`; the live host keeps real values in
`config/site/<name>` (gitignored, immune to `git pull` / history rewrites).

* `lib/common_utils.sh` provides **`resolve_site_config <name> <config_dir>`** —
  returns `config/site/<name>` if present, else `config/<name>.example` (warns to
  stderr) — and **`assert_site_configured <label> <value>`**, which aborts if a
  required value is empty or still holds the `__FILL_ME__` sentinel. A fresh clone
  therefore **fails fast** instead of half-joining a domain with placeholder data.
* Overlaid files (★ in §1): `lib_kerberos_setup.vars.conf`,
  `join_domain_sssd.vars.conf`, `join_domain_samba.vars.conf` (sourced + asserted);
  `admin_recipients.txt`, `user_email_map.txt`, `scopri_progetti_known.conf`,
  `scopri_theme_map.conf` (copied at deploy); plus `setup_nodes.site.vars.conf`,
  which overrides the 6 sanitized mail/SMTP/contact keys in the still-committed
  `setup_nodes.vars.conf` (`SMTP_HOST`, `SENDER_EMAIL`, `MAIL_DOMAIN`,
  `MAIL_DOMAINS_USER`, `SMTP_DNS_SERVERS`, `BIOME_CONTACT`).
* First-time setup and the live-host migration runbook:
  [`../../config/SITE_OVERRIDE.md`](../../config/SITE_OVERRIDE.md) and
  `plan/secret_scrub_site_overlay_plan.md`.

---

## 1. File-to-script binding

> ★ = site-local overlay (real values in `config/site/`; repo ships `<name>.example`).

| Config file | Consumed by | Purpose |
|---|---|---|
| `configure_rstudio.vars.conf` | `scripts/20_configure_rstudio.sh` | RStudio Server paths, ports, timeouts, BLAS thread pin, shared-dir groups. |
| `configure_time_sync.vars.conf` | `scripts/02_configure_time_sync.sh` | NTP backend selection + fallback pools. |
| `install_nginx.vars.conf` | `scripts/30_install_nginx.sh`, `scripts/32_setup_letsencrypt.sh` | Nginx layout, SSL/Let's-Encrypt, auth backend, AD domain, upstream ports. |
| `install_secure_access.vars.conf` | `scripts/03_install_secure_access.sh` | ttyd port + Nextcloud upstream URL. |
| `join_domain_samba.vars.conf` ★ | `scripts/11_join_domain_samba.sh` | Samba/Winbind defaults: idmap ranges, realm, workgroup, log policy. |
| `join_domain_sssd.vars.conf` ★ | `scripts/10_join_domain_sssd.sh` | SSSD defaults: home-dir template, FQNS, GPO map service. |
| `lib_kerberos_setup.vars.conf` ★ | `scripts/12_lib_kerberos_setup.sh` (sourced by 10/11) | Multi-realm krb5: KDCs + admin servers + domain→realm map. **Asserted** non-placeholder. |
| `optimize_system_proxmox.vm.vars.conf` | `scripts/01_optimize_system.sh` | Proxmox VM identity (VMID, cores, storage pool, target disk, bridge). |
| `optimize_system.vars.conf` | `scripts/31_optimize_system.sh` | Nginx-side kernel/sysctl tuning. |
| `r_env_manager.conf` | `r_env_manager.sh` | CRAN mirror + APT key, RStudio fallback version/arch, R user packages, GitHub PAT, min memory/disk. |
| `setup_nodes.vars.conf` | `scripts/50_setup_nodes.sh`, `scripts/40_install_telemetry.sh` | Node-side config: hostnames, NFS/CIFS mounts, RAM/Tmp disk sizes, `BIOME_CONF`, orphan-cleanup cron, archive paths. Mail/SMTP/contact keys are sanitized here and overridden by `setup_nodes.site.vars.conf` ★. |
| `setup_nodes.site.vars.conf` ★ | `scripts/50_setup_nodes.sh` (sourced after `setup_nodes.vars.conf`) | Real `SMTP_HOST` / `SENDER_EMAIL` / `MAIL_DOMAIN` / `MAIL_DOMAINS_USER` / `SMTP_DNS_SERVERS` / `BIOME_CONTACT`. |
| `scopri_progetti_known.conf` ★ | `templates/scopri_progetti.sh.template` (deployed) | Known-project allowlist (`username:supervisor:project`) for project-discovery. |
| `scopri_theme_map.conf` ★ | `templates/scopri_progetti.sh.template` (deployed) | Theme→supervisor inference map (`pattern;supervisor;theme`). Externalized from the template; no match → `_UNKNOWN_`. |

| Auxiliary file | Consumed by | Purpose |
|---|---|---|
| `admin_recipients.txt` ★ | `50_setup_nodes.sh` (deploy), `99_check_pkg_drift.sh`, `telemetry_api.py` | One email/line — recipients of admin notifications (orphan reports, drift alerts, postmortem dumps). |
| `user_email_map.txt` ★ | `50_setup_nodes.sh` (deploy), `resolve_user_email()` | `username  email` map for per-user notifications when AD lookup is unavailable. |

---

## 2. Per-file variable reference

### `configure_rstudio.vars.conf`

| Variable | Purpose |
|---|---|
| `R_PROJECTS_ROOT` | Shared projects root (typically `/home/projects`). |
| `USER_LOGIN_LOG_ROOT` | Per-user RStudio login log root. |
| `GLOBAL_RSTUDIO_TMP_DIR` | RStudio session tmp; should resolve to `/Rtmp` on production nodes. |
| `RSTUDIO_PROFILE_SCRIPT_PATH` | Site-level R profile bootstrap target. |
| `RSERVER_CONF_PATH`, `RSESSION_CONF_PATH`, `RSTUDIO_LOGGING_CONF_PATH`, `RSTUDIO_ENV_VARS_PATH` | Canonical RStudio config paths. |
| `GLOBAL_R_ENVIRON_SITE_PATH`, `GLOBAL_R_PROFILE_SITE_PATH` | `/etc/R/Renviron.site`, `/etc/R/Rprofile.site`. |
| `RSTUDIO_SERVER_LOG_DIR`, `RSTUDIO_FILE_LOCKING_LOG_DIR` | Server log dirs. |
| `RSERVER_WWW_ADDRESS`, `RSERVER_WWW_PORT` | Internal RStudio listen address/port (Nginx upstream). |
| `DEFAULT_PYTHON_VERSION_LOGIN_SCRIPT`, `DEFAULT_PYTHON_PATH_LOGIN_SCRIPT` | Default Python for `reticulate` / login scripts. |
| `RSESSION_TIMEOUT_MINUTES`, `RSESSION_WEBSOCKET_LOG_LEVEL` | Session lifetime + WS log verbosity. |
| `OPENBLAS_NUM_THREADS_RSTUDIO`, `OMP_NUM_THREADS_RSTUDIO` | **Critical** thread pins. Combined with `libopenblas0-serial` (HR — see Rprofile rules). |
| `TARGET_SHARED_DIR_GROUP_PRIMARY`, `TARGET_SHARED_DIR_GROUP_SECONDARY` | Group ownership for shared project directories. |

### `configure_time_sync.vars.conf`

| Variable | Purpose |
|---|---|
| `NTP_PREFERRED_CLIENT` | `chrony` / `ntp` / `systemd-timesyncd`. |
| `CHRONY_CONF_PATH`, `CHRONY_LOG_DIR`, `CHRONY_DRIFTFILE`, `CHRONY_MAKESTEP`, `CHRONY_RTC_SYNC` | Chrony tunables. |
| `CHRONY_FALLBACK_POOLS`, `SYSTEMD_FALLBACK_NTP`, `NTP_FALLBACK_SERVERS` | Network-resilient pool/server lists. |
| `NTP_CONF_PATH` | `ntpd` config path when `ntp` is selected. |

### `install_nginx.vars.conf`

| Variable | Purpose |
|---|---|
| `_CONF_DIR` | Config self-reference for relative-path computation. |
| `CERT_MODE` | `selfsigned` / `letsencrypt-staging` / `letsencrypt`. |
| `DOMAIN_OR_IP` | Public hostname or IP. |
| `NGINX_DIR`, `NGINX_TEMPLATE_DIR`, `LOG_DIR`, `DHPARAM_PATH` | Filesystem layout. |
| `RSTUDIO_PORT`, `WEB_TERMINAL_PORT`, `NEXTCLOUD_TARGET_URL` | Upstream targets. |
| `SSL_CERT_DIR`, `SSL_DAYS`, `SSL_COUNTRY`, `SSL_STATE`, `SSL_LOCALITY`, `SSL_ORGANIZATION`, `SSL_ORG_UNIT` | Self-signed cert subject. |
| `LE_EMAIL`, `LE_CERT_DIR`, `LE_MODE`, `LE_ADDITIONAL_DOMAINS`, `LE_WEBROOT` | Let's Encrypt knobs. |
| `AUTH_BACKEND` | `sssd` or `samba` — drives auto-detection in `30_install_nginx.sh`. |
| `AD_DOMAIN_LOWER`, `AD_DOMAIN_UPPER` | AD domain forms used in templates and PAM service names. |

### `install_secure_access.vars.conf`

| Variable | Purpose |
|---|---|
| `WEB_TERMINAL_PORT` | ttyd listen port (loopback). |
| `NEXTCLOUD_TARGET_URL` | Upstream URL for the Nextcloud iframe wrapper. |

### `join_domain_samba.vars.conf`

| Variable | Purpose |
|---|---|
| `_CONF_DIR`, `DEFAULT_SAMBA_SMB_CONF_PATH` | Self-ref + canonical `smb.conf` path. |
| `DEFAULT_IDMAP_PERSONALE_RANGE_LOW/HIGH`, `DEFAULT_IDMAP_STAR_RANGE_LOW/HIGH` | Winbind idmap ranges per realm. |
| `DEFAULT_TEMPLATE_HOMEDIR` | `template homedir = …` directive. |
| `DEFAULT_REALM`, `DEFAULT_WORKGROUP`, `DEFAULT_SSSD_COMPAT` | Realm / NetBIOS / sssd-compat. |
| `DEFAULT_SAMBA_LOG_LEVEL`, `DEFAULT_SAMBA_MAX_LOG_SIZE` | Logging policy. |
| `DEFAULT_MEMBERSHIP_SOFTWARE`, `DEFAULT_CLIENT_SOFTWARE` | `realm join` software selectors. |
| `USE_WINBIND` | `true` / `false` toggle. |
| `DEFAULT_IDMAP_BACKEND_DOMAIN` | Per-domain idmap backend (`rid`, `ad`, ...). |
| `DEFAULT_VALID_USERS_PATTERN`, `DEFAULT_INVALID_USERS_PATTERN` | Regex-style allow/deny patterns. |

### `join_domain_sssd.vars.conf`

| Variable | Purpose |
|---|---|
| `_CONF_DIR` | Self-ref. |
| `DEFAULT_FALLBACK_HOMEDIR_TEMPLATE` | `fallback_homedir` formula (e.g. `/home/%u@%d`). |
| `DEFAULT_USE_FQNS` | Whether to use fully-qualified usernames. |
| `DEFAULT_AD_GPO_MAP_SERVICE` | GPO service mapping list. |

### `lib_kerberos_setup.vars.conf`

| Variable | Purpose |
|---|---|
| `DEFAULT_AD_DOMAIN_LOWER`, `DEFAULT_AD_DOMAIN_UPPER` | Lower/upper domain forms. |
| `DEFAULT_AD_ADMIN_USER_EXAMPLE` | Sample admin user shown to operator at join time. |
| `DEFAULT_COMPUTER_OU_BASE`, `DEFAULT_COMPUTER_OU_CUSTOM_PART`, `DEFAULT_OS_NAME` | LDAP placement of the computer object. |
| `DEFAULT_SIMPLE_ALLOW_GROUPS` | Initial AD groups granted login. |
| `DEFAULT_HOME_TEMPLATE` | Home-dir template fed to PAM `mkhomedir`. |
| `NTP_PREFERRED_CLIENT`, `DEFAULT_NTP_FALLBACK_POOLS_CHRONY_NTP`, `DEFAULT_NTP_FALLBACK_POOLS_SYSTEMD` | Time-sync fallback (Kerberos requires ≤5 min skew). |
| `DEFAULT_DIR_UNIBO_REALM` / `_KDC` / `_ADMIN_SERVER` | DIR.UNIBO.IT realm. |
| `DEFAULT_PERSONALE_UNIBO_REALM` / `_KDC` / `_ADMIN_SERVER` | AD.EXAMPLE.COM realm. |
| `DEFAULT_STUDENTI_UNIBO_REALM` / `_KDC` / `_ADMIN_SERVER` | STUDENTI.DIR.UNIBO.IT realm. |
| `DEFAULT_DOMAIN_REALM_MAPPINGS` | `[domain_realm]` block lines. |

### `optimize_system_proxmox.vm.vars.conf`

| Variable | Purpose |
|---|---|
| `VMID`, `CORES`, `STORAGE_POOL`, `TARGET_DISK`, `NETWORK_BRIDGE` | Proxmox VM identity. |
| `GUEST_SCRIPT_TEMPLATE` | Path to `guest_optimizer.sh.tpl`, applied inside the guest. |

### `optimize_system.vars.conf`

| Variable | Purpose |
|---|---|
| `_CONF_DIR`, `SYSCTL_CONF` | Self-ref + sysctl drop-in path. |
| `WORKER_PROCESSES`, `WORKER_CONNECTIONS` | Nginx capacity. |
| `TIMEOUT_LONG`, `TIMEOUT_STANDARD` | Long-poll vs default timeouts (RStudio sessions need long). |
| `BUFFERING_STATE` | `on`/`off` for proxy buffering (typically `off` for ttyd/RStudio). |

### `r_env_manager.conf`

| Variable | Purpose |
|---|---|
| `CRAN_MIRROR_URL`, `CRAN_REPO_URL_BIN`, `CRAN_APT_KEY_URL`, `CRAN_APT_KEYRING_FILE` | CRAN binary apt repo + signing key. |
| `RSTUDIO_VERSION_FALLBACK`, `RSTUDIO_ARCH_FALLBACK` | Used when `21_helper_rstudio_version.sh` cannot scrape posit.co. |
| `R_USER_PACKAGES_CRAN`, `R_USER_PACKAGES_GITHUB` | Curated baseline packages installed during env setup. |
| `GITHUB_PAT` | PAT for GitHub installs (read from env if unset; **never commit**). |
| `MIN_MEMORY_MB`, `MIN_DISK_MB` | Pre-flight resource gates. |

### `setup_nodes.vars.conf`

| Variable | Purpose |
|---|---|
| `BIOME_HOST`, `BIOME_IP` | Node identity. |
| `NFS_HOME`, `CIFS_ARCHIVE` | Shared home + archive mount sources. |
| `PYTHON_ENV` | Path of the geospatial venv (terra/sf/gdal-bound). |
| `RAMDISK_SIZE`, `RAMDISK_GB` | tmpfs sizing for `/tmp` if RAM-disk is enabled. |
| `TMP_DISK_GB`, `TMP_WARN_THRESHOLD_PCT` | `/Rtmp` ext4 disk size + free-space alarm threshold. |
| `BIOME_CONF` | Authoritative config root, default `/etc/biome-calc/`. |
| `LOG_FILE` | Node-level deploy log. |
| `SMTP_HOST`, `SMTP_PORT`, `SENDER_EMAIL`, `MAIL_DOMAIN`, `MAIL_DOMAINS_USER`, `SMTP_DNS_SERVERS` | Mail relay for orphan/postmortem notifications. |
| `KILL_TIMEOUT` | Grace before SIGKILL on orphan cleanup. |
| `ORPHAN_CRON_CLEANUP`, `ORPHAN_CRON_NOTIFY`, `ORPHAN_CRON_REPORT` | Cron schedules for the three orphan jobs. |
| `ARCHIVE_STORAGE_ROOT`, `ARCHIVE_LOG_DIR`, `ARCHIVE_CONF_DIR`, `ARCHIVE_CSV_FILE` | Archive manager state. |
| `RPROFILE_VERSION` | Currently `12.4`. Tag baked into `/etc/R/Rprofile.site` for `--verify`. |
| `R_LIBS_LOCAL_ROOT` | Local R-libs root (default `/var/lib/biome-Rlibs`). Mode A uses rootfs; Mode B mounts a dedicated disk here. |
| `R_LIBS_LOCAL_DEVICE` | Optional. e.g. `/dev/sdb`. If set, Step 7c (`setup_nodes_local_rlibs`) does `mkfs` + UUID-based `/etc/fstab` entry + mount. Empty = Mode A. |
| `R_LIBS_LOCAL_FSTYPE`, `R_LIBS_LOCAL_SIZE_GB` | Filesystem type (default `ext4`) and minimum size gate for Mode B. |
| `NFS_AUDIT_REQUIRE_VERS`, `NFS_AUDIT_REQUIRE_NCONNECT`, `NFS_AUDIT_REQUIRE_LOOKUPCACHE` | Read-only thresholds for Step 7d (`setup_nodes_audit_nfs`). The script reports `[audit] WARN` when a mount falls below them — **never** remounts. |

### `scopri_progetti_known.conf`

Free-form (one entry per line). Maintained by the operator; consumed by
the deployed `/usr/local/bin/scopri_progetti.sh` to short-circuit known
project paths during discovery.

---

## 3. R runtime configuration touched by these scripts

These are not `.vars.conf` files but they are produced/owned by the
deployment chain and must stay coherent:

| Path | Owner script | Notes |
|---|---|---|
| `/etc/R/Rprofile.site` | `50_setup_nodes.sh` (from `Rprofile_site.R.template`) | Thin v12.4 dispatcher. Sources `Rprofile_site.d/`. Adds flags `ENABLE_FORK_TO_PSOCK`, `ENABLE_TERRA_TODISK_DEFAULT`. |
| `/etc/R/Rprofile_site.d/*.R` | `50_setup_nodes.sh` (from `templates/Rprofile_site.d/`) | Modular feature fragments: 04 (user-lib bootstrap, v12.6+), 05 (thread guard, v12.3+), 20 (cgroup reader), 30 (PSOCK factory + v12.9.4 MALLOC caps), 35 (NIMBLE/Stan compile routing), 40 (wrapper installer), **42 (install-storm safety valve, v12.10, dormant by default)**, 45 (memory guards), 50 (pkg hooks + terra todisk + cgroup-aware terraOptions), **52 (mclapply fork guard, v12.4+PKG-SYNC v12.7+GLOBAL-SYNC v12.9.3)**, 55 (options guard), 60 (safe setwd), 70 (persistent tools), 80 (tools ext). See `templates/Rprofile_site.d/README.md` for full inventory. |
| `/etc/R/Rprofile_site.d/.compiled/{bundle.Rc,manifest.txt}` | `50_setup_nodes.sh` Step 8 (v12.3) | Byte-compiled fragment bundle fast-path. Manifest is md5sum + basename per fragment; mismatch → silent fall-back to legacy `sys.source()` loop. **Derived state** — safe to delete; rebuilt on next deploy. Bypass: `BIOME_DISABLE_BUNDLE=1`. |

| `/etc/R/Rprofile_minimal.R` | `50_setup_nodes.sh` (from `Rprofile_site.minimal.R.template`) | L0/L1 forensic profile launched by `r_minimal`. Does **NOT** source the `.d/` fragments. |
| `/etc/R/Renviron.site` | `50_setup_nodes.sh` (from `Renviron.template`) | Since v12.4: `R_LIBS_USER=/var/lib/biome-Rlibs/%u/%v:${HOME}/R/x86_64-pc-linux-gnu-library/%v` (local-first, NFS fallback). Also `TMPDIR=/Rtmp/$USER`, BLAS env, language locales. |
| `/var/lib/biome-Rlibs/<user>/<R-ver>/` | `50_setup_nodes.sh` Step 7c (`setup_nodes_local_rlibs`) | Local R user-library root with sticky `1777`. Mode A on rootfs, Mode B on dedicated disk via `R_LIBS_LOCAL_DEVICE` (UUID fstab). Eliminates NFS lookupcache storm. |
| `/etc/biome-calc/profile.d/*.sh` | `50_setup_nodes.sh` | Modular shell-side runtime knobs (CORETYPE pin, OPENBLAS thread caps). Sourced by RStudio user login. |
| `/etc/biome-calc/audit/00_audit_v28.R` | `99_audit_r_environment.sh` (from `00_audit_v28.R.template`) | Parameterized R-environment audit. |

---

## 4. Hard rules to remember when editing configs

1. **HR-7** Every `.sh` that consumes a `.vars.conf` already starts with `set -euo pipefail`. Do not weaken this.
2. **HR-8** Passwords (Kerberos admin, GitHub PAT, SMTP) MUST be written to files with `0600` perms — never passed on the CLI.
3. **HR-12** `.env`, real secret/PII values, and `~/.config/biome-calc/secrets/` are **not committed**. The repo carries sanitized `*.example` templates; real site values live in the gitignored `config/site/` overlay (§0). Add new sensitive files to both `.gitignore` and `config/SITE_OVERRIDE.md`.
4. **HR-15** R-runtime BLAS must remain `libopenblas0-serial` — `libopenblas0-pthread` causes SIGSEGV on RStudio fork.
5. **HR-16** Any JSON manipulation in scripts must use `jq`, not `sed`/`awk`.
6. **HR-17** Adapt the system to portable user R code — never silently patch user scripts.

---

## 5. Cross-references

* Per-script entry points → [`SCRIPT_CATALOG.md`](SCRIPT_CATALOG.md)
* Templates rendered by these configs → [`TEMPLATE_GALLERY.md`](TEMPLATE_GALLERY.md)
* Deployment walkthrough → [`../deployment/INSTALLATION_GUIDE.md`](../deployment/INSTALLATION_GUIDE.md)
* Auth backends deep-dive → [`NGINX_AUTH_BACKENDS.md`](NGINX_AUTH_BACKENDS.md)
