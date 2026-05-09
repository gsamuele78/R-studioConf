<!-- docs/reference/TEMPLATE_GALLERY.md -->
# Template Gallery (T1 Host)

> **Tier:** T1. Authoritative.  
> **Last updated:** 2026-05-09.

Templates live in `/templates/` and are rendered by the numbered phase
scripts via `process_template` (in `lib/common_utils.sh`), which performs
`%%VAR%%` placeholder substitution from the consuming `.vars.conf`.

---

## 1. CURRENT vs LEGACY (read first)

The repository carries several historical Rprofile snapshots for forensic
purposes. **Only one is canonical at a time.** When you edit, edit the
canonical one only; the others are reference history.

| File | Status | Notes |
|---|---|---|
| `Rprofile_site.R.template` | **CANONICAL (v12.2)** | Thin dispatcher; sources `Rprofile_site.d/`. Deployed to `/etc/R/Rprofile.site`. |
| `Rprofile_site.d/*.R.template` | **CANONICAL (v12.2)** | Modular feature fragments. Deployed to `/etc/R/Rprofile_site.d/`. |
| `Rprofile_site.minimal.R.template` | **CANONICAL** | L0/L1 forensic profile. Deployed to `/etc/R/Rprofile_minimal.R`. **Does NOT source `.d/`.** |
| `Renviron.template` | **CANONICAL** | Deployed to `/etc/R/Renviron.site`. |
| `00_audit_v28.R.template` | **CANONICAL** | Audit script run by `99_audit_r_environment.sh`. |
| `Rprofile_site.R.template_v11.4_final` | LEGACY | Last v11 monolithic profile. Reference for the v12.2 split. |
| `Rprofile_site.R.template_v11.4` | LEGACY | Pre-final. |
| `Rprofile_site.R.template_v11.2` | LEGACY | Older. |
| `Rprofile_site_R.template_v11.3`, `Rprofile_site_R.v11.3.template` | LEGACY | Naming variants of v11.3. |
| `Rprofile_site.R.template_v12_nimble_router` | LEGACY | NIMBLE-router experiment, folded into `35_compile_routing.R.template`. |
| `Rprofile_site.R.template_original` | LEGACY | Earliest committed snapshot. |
| `Rprofile_site_optimized.R.template` | LEGACY | Carries the obsolete `BIOME_FORCE_NFS_TMP` env var. **Do not deploy.** |
| `templates/old/*.template` | LEGACY | Quarantined; safe to ignore. |

> **Env-var legacy notice.** `BIOME_FORCE_NFS_TMP` was the v9-era
> opt-in to route R `tempfile()` to NFS instead of `/tmp`. The current
> design ships every node with a dedicated **`/Rtmp` 400 GB ext4 virtio
> disk** wired through `Renviron.template` (`TMPDIR=/Rtmp/$USER`), so
> the env var is a no-op and should not appear in user scripts. The
> only reason it still appears in legacy templates is forensic.

---

## 2. R-side templates

### Modular dispatcher chain (canonical)

| Template | Deploys to | Purpose |
|---|---|---|
| `Rprofile_site.R.template` | `/etc/R/Rprofile.site` | v12.2 thin dispatcher: integrity check, BLAS safety, PSOCK fast-path, bspm pre-load, defines `.biome_env` / `sys_log` / `ENABLE_*` flags / `.C_*` colors / `MAX_THREADS`, then `sys.source()`s every `[0-9][0-9]_*.R` in `/etc/R/Rprofile_site.d/`. |
| `Rprofile_site.d/05_thread_guard.R.template` | `/etc/R/Rprofile_site.d/05_thread_guard.R` | Caps OpenBLAS/OMP/MKL threads; wraps `parallel::detectCores()` to honor cgroup quota. |
| `Rprofile_site.d/20_cgroup_reader.R.template` | `…/20_cgroup_reader.R` | Reads `/sys/fs/cgroup/...` to derive the user's effective CPU/memory share. |
| `Rprofile_site.d/30_psock_factory.R.template` | `…/30_psock_factory.R` | Hardened `makeCluster` factory: forces PSOCK on RStudio (fork is unsafe), inherits BLAS pin into workers. |
| `Rprofile_site.d/35_compile_routing.R.template` | `…/35_compile_routing.R` | Per-package routing for compile-heavy ops: NIMBLE/cmdstanr/TMB output dirs default to `/Rtmp` not `/tmp`. |
| `Rprofile_site.d/40_wrapper_installer.R.template` | `…/40_wrapper_installer.R` | Installs guarded wrappers (`mclapply` → `parLapply` on RStudio, etc.). |
| `Rprofile_site.d/45_memory_guards.R.template` | `…/45_memory_guards.R` | OOM-aware allocation gates; pre-empts `cannot allocate vector of size`. |
| `Rprofile_site.d/50_pkg_hooks.R.template` | `…/50_pkg_hooks.R` | `setHook(packageEvent(...))` patches: `terra` memfrac, `data.table` threads, `future` plan defaults, etc. |
| `Rprofile_site.d/55_options_guard.R.template` | `…/55_options_guard.R` | Whitelists/normalizes `options()` to safe defaults. |
| `Rprofile_site.d/60_safe_setwd.R.template` | `…/60_safe_setwd.R` | Refuses `setwd()` to `/tmp`-rooted paths; redirects to `/Rtmp/$USER`. |
| `Rprofile_site.d/70_persistent_tools.R.template` | `…/70_persistent_tools.R` | User-facing helpers: `biome_help()`, `biome_tutorial()`, `biome_diag()`, `biome_status()`. |
| `Rprofile_site.d/80_tools_ext.R.template` | `…/80_tools_ext.R` | Extension surface for ad-hoc helpers. |
| `Rprofile_site.minimal.R.template` | `/etc/R/Rprofile_minimal.R` | Forensic profile: BLAS pin + `/Rtmp` only. **No `.d/` sourcing.** Used by `r_minimal` / HC-13 L0/L1. |
| `Renviron.template` | `/etc/R/Renviron.site` | Sets `R_LIBS_SITE`, `R_LIBS_USER`, `TMPDIR=/Rtmp/$USER`, `R_DEFAULT_PACKAGES`, `OPENBLAS_NUM_THREADS`, `OMP_NUM_THREADS`, locale envs. |
| `r_profile_site_welcome.R.template` | (RStudio splash) | Welcome banner displayed at session start. |
| `00_audit_v28.R.template` | `${BIOME_CONF}/audit/00_audit_v28.R` | Parameterized R-environment audit. Run via `99_audit_r_environment.sh`. |

### Modular fragment README

`templates/Rprofile_site.d/README.md` is itself shipped as
documentation of the fragment loader contract. Read it before adding a
new `NN_*.R.template`.

---

## 3. Nginx & web-tier templates

| Template | Rendered by | Purpose |
|---|---|---|
| `nginx_site.conf.template` | `30_install_nginx.sh` | Top-level vhost — server blocks, redirects, ACME challenge. |
| `nginx_proxy_location.conf.template` | `30_install_nginx.sh` | All upstream `location` blocks: `/` (portal), `/rstudio/`, `/terminal/`, `/files/` (Nextcloud iframe), `/auth_pam`. |
| `nginx_ssl_certificate.conf.template` | `30_install_nginx.sh` | Cert paths + `ssl_certificate*` directives. |
| `nginx_ssl_params.conf.template` | `30_install_nginx.sh` | Modern TLS profile (protocols, ciphers, OCSP, HSTS). |
| `nginx_performance.conf.template` | `30_install_nginx.sh` / `31_optimize_system.sh` | `worker_processes`, `worker_connections`, sendfile/tcp_nopush, gzip. |
| `sysctl_optimization.conf.template` | `31_optimize_system.sh` | Kernel tuning for high-conc Nginx (somaxconn, file-max, tcp_*). |

### Portal SPA

| Template | Deployed to | Purpose |
|---|---|---|
| `portal_index.html.template` | `/var/www/html/index.html` | Main portal landing page (cards: RStudio, Terminal, Nextcloud, Status). Includes telemetry strip if `INCLUDE_TELEMETRY_STRIP=true`. |
| `portal_index_simple.html.template` | (alt deploy) | Stripped variant for low-bandwidth or kiosk. |
| `portal_style.css.template` | `/var/www/html/portal.css` | Theme. **No external CDN** (HR-15). |
| `terminal_wrapper.html.template` | `/var/www/html/terminal.html` | iframe wrapper for ttyd. |
| `nextcloud_wrapper.html.template` | `/var/www/html/files.html` | iframe wrapper for Nextcloud. |
| `rstudio_wrapper.html.template` | `/var/www/html/rstudio.html` | iframe wrapper for RStudio. |
| `server_status_wrapper.html.template` | `/var/www/html/status.html` | Live status panel (consumes telemetry API). |

---

## 4. RStudio / ttyd / system templates

| Template | Rendered by | Purpose |
|---|---|---|
| `rstudio_logging.conf.template` | `20_configure_rstudio.sh` | RStudio Server logging level + targets. |
| `rstudio_user_login_script.sh.template` | `20_configure_rstudio.sh` | Per-user login hook deployed to RStudio's login-script slot. Sources `/etc/biome-calc/profile.d/*.sh`. |
| `ttyd.service.override.template` | `03_install_secure_access.sh` | Systemd unit override: pins ttyd port, calls `ttyd_login_wrapper.sh`. |
| `motd_biome_rules.template` | `50_setup_nodes.sh` | `/etc/motd` (and SSH banner) with the BIOME usage etiquette. |

---

## 5. Identity templates

| Template | Rendered by | Purpose |
|---|---|---|
| `krb5.conf.template` | `12_lib_kerberos_setup.sh` | Multi-realm `[realms]` + `[domain_realm]` for DIR / PERSONALE / STUDENTI. |
| `sssd.conf.template` | `10_join_domain_sssd.sh` | SSSD AD provider, `fallback_homedir`, `use_fully_qualified_names`, GPO map. |
| `smb.conf.template` | `11_join_domain_samba.sh` | Winbind AD member, idmap ranges, `template homedir`. |
| `chrony.conf.template` | `02_configure_time_sync.sh` | Chrony with fallback pools (Kerberos ≤5 min skew). |

---

## 6. Orphan-cleanup, archive & email templates

These are deployed by `50_setup_nodes.sh` into `/etc/biome-calc/script/`
and wired into cron/systemd-timer per `setup_nodes.vars.conf`.

| Template | Purpose |
|---|---|
| `cleanup_r_orphans.sh.template` | Daily: kills user R sessions whose ttys/RStudio have closed. |
| `cleanup_r_orphans.sh copy.template` | (Stale duplicate — candidate for cleanup; verify before deleting.) |
| `notify_r_orphans.sh.template` | Emails the user (via `user_email_map.txt`) before kill, after `KILL_TIMEOUT`. |
| `r_orphan_report.sh.template` | Periodic admin report (CSV + email to `admin_recipients.txt`). |
| `orphan_cleanup_helpers.sh.template` | Shared helpers used by the three above. |
| `r_orphan_cleanup.conf.template` | Operator-tunable knobs for the orphan trio. |
| `send_email.sh.template` | Generic SMTP relay wrapper. Reads `user_email_map.txt`, `admin_recipients.txt`. |
| `unibo_archive_manager.sh.template` | UniBo CIFS archive lifecycle manager (`ARCHIVE_*` vars). |
| `scopri_progetti.sh.template` | Project-discovery helper. Uses `scopri_progetti_known.conf`. |

---

## 7. Proxmox-side template

| Template | Rendered by | Purpose |
|---|---|---|
| `guest_optimizer.sh.tpl` | `01_optimize_system.sh` | Script pushed into the KVM guest to apply tuning from inside. |

---

## 8. Cross-references

* Variable substitution map → [`CONFIGURATION_MAP.md`](CONFIGURATION_MAP.md)
* Which script renders what → [`SCRIPT_CATALOG.md`](SCRIPT_CATALOG.md)
* Modular fragment loader contract → [`/templates/Rprofile_site.d/README.md`](../../templates/Rprofile_site.d/README.md)
* Rprofile evolution → [`Rprofile_site.CHANGELOG.md`](Rprofile_site.CHANGELOG.md)
