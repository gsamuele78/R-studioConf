<!-- docs/developer/CONFIGURATION_REFERENCE.md -->
# Developer Configuration Reference

This page describes the committed T1 configuration surface as of 2026-10-06. Code is authoritative. For an operator-oriented map, see [`../reference/CONFIGURATION_MAP.md`](../reference/CONFIGURATION_MAP.md).

## Configuration loading rules

- `r_env_manager.sh` sources `config/r_env_manager.conf`.
- Numbered scripts source their matching `config/*.vars.conf` or resolve a site-local file with `resolve_site_config`.
- Sensitive AD, mail, address, and PII values belong in gitignored `config/site/` files copied from committed `*.example` files. `assert_site_configured` rejects empty values and `__FILL_ME__` sentinels.
- Do not commit `.env` files or real site overlays.
- R and RStudio version defaults must come from canonical configuration, not new literals in scripts (HC-15).

See [`../../config/SITE_OVERRIDE.md`](../../config/SITE_OVERRIDE.md) for overlay precedence and deployment.

## Active files

| File | Primary consumer | Active content |
|---|---|---|
| `config/r_env_manager.conf` | `r_env_manager.sh` | CRAN/r2u endpoints, RStudio fallback version, R package lists, GitHub token slot, minimum RAM/disk |
| `config/setup_nodes.vars.conf` | `scripts/50_setup_nodes.sh` | storage, R runtime, cgroups, orphan cleanup, archive manager, packages, Ollama, local R libraries, NFS audit |
| `config/configure_time_sync.vars.conf` | `scripts/02_configure_time_sync.sh` | chrony/systemd-timesyncd/NTP paths and fallback pools |
| `config/install_secure_access.vars.conf` | `scripts/03_install_secure_access.sh` | web-terminal port and legacy Nextcloud target consumed by that script |
| `config/configure_rstudio.vars.conf` | `scripts/20_configure_rstudio.sh` | RStudio paths, listen address/port, login bootstrap, session timeout, thread values, groups |
| `config/install_nginx.vars.conf` | `scripts/30_install_nginx.sh` | TLS mode, Nginx paths, upstream ports, auth backend, AD-derived values, Let's Encrypt settings |
| `config/optimize_system.vars.conf` | `scripts/31_optimize_system.sh` | sysctl path, Nginx workers/connections, proxy timeouts and buffering |
| `config/optimize_system_proxmox.vm.vars.conf` | `scripts/01_optimize_system.sh` | optional Proxmox VM identifiers, CPU, storage, bridge, guest template |
| `config/pin_r_version.vars.conf` | `scripts/pin_r_version.sh` | apt pin file, R package names, default R version |
| `config/lib_kerberos_setup.vars.conf.example` | `scripts/12_lib_kerberos_setup.sh` | realm/KDC/OU/group placeholders and NTP defaults |
| `config/join_domain_sssd.vars.conf.example` | `scripts/10_join_domain_sssd.sh` | SSSD home, FQDN, and GPO mapping defaults |
| `config/join_domain_samba.vars.conf.example` | `scripts/11_join_domain_samba.sh` | Samba/Winbind idmap, workgroup, home, backend, and access defaults |
| `config/setup_nodes.site.vars.conf.example` | `scripts/50_setup_nodes.sh` | six site-local mail/contact overrides |
| `config/admin_recipients.txt.example` | orphan cleanup and telemetry | one administrative address per non-comment line |
| `config/user_email_map.txt.example` | orphan notifications | whitespace-separated `username address` overrides |
| `config/scopri_progetti_known.conf.example` | archive discovery | colon-separated known user/supervisor/project mappings |
| `config/scopri_theme_map.conf.example` | archive discovery | semicolon-separated group-regex/supervisor/theme mappings |
| `config/SITE_OVERRIDE.md` | maintainers/operators | overlay contract and required setup |

## Canonical version and runtime values

### `config/r_env_manager.conf`

- `RSTUDIO_VERSION_FALLBACK="2026.01.1+403"`
- `RSTUDIO_ARCH_FALLBACK="amd64"`
- `MIN_MEMORY_MB=2048`
- `MIN_DISK_MB=5120`
- `CRAN_MIRROR_URL`, `CRAN_REPO_URL_BIN`, `CRAN_APT_KEY_URL`, and `CRAN_APT_KEYRING_FILE`
- `R2U_REPO_URL_BASE` and `R2U_APT_SOURCES_LIST_D_FILE`
- `R_USER_PACKAGES_CRAN`, `R_USER_PACKAGES_GITHUB`, and `GITHUB_PAT`

Known code drift: `r_env_manager.sh` still contains a generated default with `RSTUDIO_VERSION_FALLBACK="2023.06.0"` and uses that literal as an internal fallback. `scripts/pin_r_version.sh` and `config/pin_r_version.vars.conf` both contain `DEFAULT_R_VERSION="4.6.0"`. These are open HC-15 findings; do not copy those literals into new code.

### `config/setup_nodes.vars.conf`

Current core values:

| Area | Variables and current defaults |
|---|---|
| Host/storage | `BIOME_HOST=""`, `BIOME_IP=""`, `NFS_HOME="/nfs/home"`, `CIFS_ARCHIVE="/mnt/ProjectStorage"`, `BIOME_CONF="/etc/biome-calc"` |
| R scratch | `RAMDISK_SIZE="0"`, `RAMDISK_GB=0`, `TMP_DISK_GB=400`, `TMP_WARN_THRESHOLD_PCT=80`; `/Rtmp` is local disk, not tmpfs |
| R profile | `RPROFILE_VERSION="12.10"`, `RSESSION_CONF_PATH="/etc/rstudio/rsession.conf"` |
| BLAS | `MAX_BLAS_THREADS=16`, `MAX_THREADS=16`, serial BLAS/LAPACK paths under `/usr/lib/x86_64-linux-gnu/openblas-serial/` |
| Local R libraries | `ENABLE_R_LIBS_LOCAL=true`, `ENABLE_R_LIBS_LOCAL_WARMUP=true`, `R_LIBS_LOCAL_ROOT="/var/lib/biome-Rlibs"`, optional block device, ext4, 80 GB size hint |
| NFS audit | `NFS_AUDIT_REQUIRE_NCONNECT_MIN=4`, `NFS_AUDIT_REQUIRE_VERS_MIN="4.1"`, `NFS_AUDIT_HINT_LOOKUPCACHE_ALL=true` |
| User cgroups | `MemoryHigh=300G`, `MemoryMax=400G`, swap `4G`, tasks `4096`, CPU/IO weight `100` |
| System cgroups | memory minimum `16G`, memory low `24G`, CPU weight `200`, Ollama CPU weight `80` |
| Swap | `SWAP_FILE="/swap.img"`, `SWAP_SIZE_GB=32` |
| Python | `PYTHON_ENV="/opt/r-geospatial"` and `PYTHON_PACKAGES` array |
| R packages | `R_PACKAGES` array |
| Ollama | `SKIP_OLLAMA=false`, model names, `OLLAMA_RAM_LIMIT="24G"`, `OLLAMA_THREADS=24` |

### Orphan cleanup

- Mail/contact values: `SMTP_HOST`, `SMTP_PORT`, `SENDER_EMAIL`, `MAIL_DOMAIN`, `MAIL_DOMAINS_USER`, `SMTP_DNS_SERVERS`, `BIOME_CONTACT`.
- Runtime: `KILL_TIMEOUT="30"`.
- Cron: `ORPHAN_CRON_CLEANUP="15 * * * *"`, `ORPHAN_CRON_NOTIFY="00 18 * * *"`, `ORPHAN_CRON_REPORT="00 08 * * 1-5"`.
- Real mail/contact values come from `config/site/setup_nodes.site.vars.conf`; the committed values are examples.

### Archive manager

- `ARCHIVE_STORAGE_ROOT="/mnt/ProjectStorage"`
- `ARCHIVE_LOG_DIR="/var/log/biome-log/biome_archive"`
- `ARCHIVE_CONF_DIR="${BIOME_CONF}/conf"`
- `ARCHIVE_CSV_FILE="${ARCHIVE_CONF_DIR}/biome_supervisor_map.csv"`
- `ARCHIVE_CRON_SCHEDULE="00 03 * * *"`

## Adding or changing a variable

1. Add the documented default to the owning committed config file.
2. If the value is site-specific or sensitive, add only a sanitized entry to the appropriate `*.example` file and resolve it from `config/site/`.
3. Source the configuration before first use; guard optional values with `${NAME:-}` under strict mode.
4. Pass only the required names to `process_template` or a narrowly scoped `envsubst` allow-list.
5. Update the operator and reference maps when behavior or deployment paths change.
6. If changing `RPROFILE_VERSION`, follow HC-14 in the same commit.
7. Port the behavior T1 -> T2 -> T3 or record the tier delta.

Unverified: the repository proves defaults and loading paths, but not the values present in an operator's gitignored `config/site/` directory or the effective configuration on a live host.
