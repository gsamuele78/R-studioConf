<!-- docs/developer/TEMPLATES_REFERENCE.md -->
# Templates Reference

This page describes the T1 `templates/` tree as of 2026-10-06. `scripts/50_setup_nodes.sh` is the principal runtime-template deployer. For a broader gallery, see [`../reference/TEMPLATE_GALLERY.md`](../reference/TEMPLATE_GALLERY.md).

## Rendering mechanisms

### `process_template`

Defined in `lib/common_utils.sh`:

```bash
process_template template_path output_variable NAME=value ...
```

It replaces explicit `%%NAME%%` tokens and assigns the rendered text to a shell variable. The caller writes that variable to the destination. There is no `__process_template` function.

### `process_systemd_template`

This separate function replaces `{{NAME}}` tokens from caller variables and writes a destination file, setting `root:root` and mode `0644`. It is not the same engine as `process_template`; the divergent implementations remain an open audit item.

### Allow-listed `envsubst`

`50_setup_nodes.sh` uses restricted `envsubst` variable lists for the orphan-cleanup and archive-manager templates. This is active code, not an obsolete path.

## R runtime templates

| Template | Active role/destination |
|---|---|
| `Rprofile_site.R.template` | Thin dispatcher rendered to `/etc/R/Rprofile.site`; current configured version is 12.11. |
| `Renviron.template` | Managed R environment source containing `/Rtmp`, local R library, fork/thread, GDAL/PROJ, allocator, Python, and compiler settings. The audit records a remaining discrepancy between this file and the live generation path. |
| `Rprofile_site.minimal.R.template` | Minimal forensic profile used by diagnostics. |
| `00_audit_v28.R.template` | Rendered to `${BIOME_CONF}/audit/00_audit_v28.R`. v28 is active on T1. |
| `rstudio_user_login_script.sh.template` | User login/bootstrap script deployed by RStudio configuration. Uses `jq` for preference merging inside the template. |
| `r_profile_site_welcome.R.template` | Welcome/profile support template. |
| `Rprofile_site_optimized.R.template` | Retained non-canonical alternative; canonical dispatcher is `Rprofile_site.R.template`. |

### Active `Rprofile_site.d/` fragments

`50_setup_nodes.sh` deploys the modular fragment directory to `/etc/biome-calc/profile.d/`. Lexical order is behaviorally significant.

| Fragment | Role |
|---|---|
| `04_user_lib_bootstrap.R.template` | Creates/repairs the per-user local R library path. |
| `05_thread_guard.R.template` | Native thread limits and core awareness. |
| `20_cgroup_reader.R.template` | Reads effective cgroup CPU/memory limits. |
| `30_psock_factory.R.template` | Public PSOCK cluster factory. |
| `35_compile_routing.R.template` | Routes NIMBLE/TMB compilation scratch to `/Rtmp`. |
| `40_wrapper_installer.R.template` | Installs managed wrappers. |
| `42_install_block.R.template` | Opt-in installation blocker introduced by the v12.10 line. |
| `45_memory_guards.R.template` | Preflight guards for large allocations. |
| `50_pkg_hooks.R.template` | Package-specific runtime hooks. |
| `52_mclapply_guard.R.template` | Fork guard for `mclapply`. |
| `55_options_guard.R.template` | Managed-option guard. |
| `60_safe_setwd.R.template` | Safe working-directory behavior. |
| `70_persistent_tools.R.template` | Persistent public helper functions. |
| `80_tools_ext.R.template` | Extended tools. |

`Rprofile_site.d/README.md` documents fragment-specific behavior. Any `RPROFILE_VERSION` change must follow HC-14 and update the Rprofile changelog and cross-references in the same commit.

## Identity, RStudio, Nginx, and portal

| Templates | Role |
|---|---|
| `sssd.conf.template`, `smb.conf.template`, `krb5.conf.template` | SSSD or Samba/Winbind identity and Kerberos configuration. SSSD and Samba are alternatives, not a combined deployment. |
| `chrony.conf.template` | Time synchronization configuration. |
| `rstudio_logging.conf.template` | RStudio logging configuration. |
| `nginx_site.conf.template`, `nginx_proxy_location.conf.template`, `nginx_performance.conf.template` | Nginx virtual host, upstream location, and performance configuration. |
| `nginx_ssl_params.conf.template`, `nginx_ssl_certificate.conf.template` | TLS settings and certificate paths. |
| `portal_index.html.template`, `portal_index_simple.html.template`, `portal_style.css.template` | Portal UI. The two HTML templates still load Google Fonts and therefore remain open HC-11 defects. |
| `rstudio_wrapper.html.template`, `terminal_wrapper.html.template`, `nextcloud_wrapper.html.template`, `server_status_wrapper.html.template` | Wrapper pages retained by the active web/secure-access code paths. `server_status_wrapper.html.template` also still loads Google Fonts. |
| `ttyd.service.override.template`, `motd_biome_rules.template` | ttyd override and MOTD policy content. |
| `sysctl_optimization.conf.template`, `guest_optimizer.sh.tpl` | Host/guest tuning. |

The presence of terminal and Nextcloud variables/templates reflects active repository code paths in `03_install_secure_access.sh` and Nginx configuration. It does not make them part of the T2/T3 maturity claim.

## Archive manager

`50_setup_nodes.sh::setup_nodes_project_archiver` renders and deploys:

| Source | Destination |
|---|---|
| `scopri_progetti.sh.template` | `/etc/biome-calc/script/scopri_progetti.sh` |
| `unibo_archive_manager.sh.template` | `/etc/biome-calc/script/unibo_archive_manager.sh` |

The committed source headers identify the discovery template as **BIOME AD Group Inspector V4** and the archive manager as **BIOME Precision Archiver V23**. Older documentation names such as `scopri_progetti_v5.sh` and `unibo_archive_manager_v23.sh` are not the deployed filenames.

Site-local `scopri_progetti_known.conf` and `scopri_theme_map.conf` are copied into `${BIOME_CONF}/conf`; their real contents are not committed.

## Orphan-process cleanup

`50_setup_nodes.sh::setup_nodes_orphan_cleanup` deploys:

- `cleanup_r_orphans.sh.template` -> `/etc/biome-calc/script/cleanup_r_orphans.sh`
- `notify_r_orphans.sh.template` -> `/etc/biome-calc/script/notify_r_orphans.sh`
- `r_orphan_report.sh.template` -> `/etc/biome-calc/script/r_orphan_report.sh`
- `send_email.sh.template` -> `/etc/biome-calc/script/send_email.sh`
- `orphan_cleanup_helpers.sh.template` -> `/etc/biome-calc/script/orphan_cleanup_helpers.sh`
- `r_orphan_cleanup.conf.template` -> `/etc/biome-calc/conf/r_orphan_cleanup.conf`

The declared script headers are cleanup v4.5 (with later v4.6/v4.7 comments), notifier v4.3, and report v4.3. Do not relabel them as newer versions unless the source headers are updated.

## Canonical versus retained legacy files

Canonical Rprofile sources are `Rprofile_site.R.template`, `Renviron.template`, `Rprofile_site.minimal.R.template`, `00_audit_v28.R.template`, and the 14 fragment templates.

The following are retained legacy or duplicate artifacts and are not canonical deployment inputs:

- everything under `templates/old/`
- `cleanup_r_orphans.sh copy.template`
- versioned monoliths such as `Rprofile_site.R.template_v11.2`, `Rprofile_site.R.template_v11.4`, `Rprofile_site.R.template_v11.4_final`, `Rprofile_site.R.template_v12_nimble_router`, `Rprofile_site_R.template_v11.3`, and `Rprofile_site_R.v11.3.template`
- `Rprofile_site.R.template_original`

Do not delete or migrate these files as part of documentation work. Their consolidation remains an open codebase audit item.

## Authoring rules

1. Modify T1 templates first.
2. Preserve active placeholder syntax and use an explicit allow-list.
3. Do not add external CDN dependencies.
4. Use `jq` for JSON manipulation.
5. Keep large R scratch paths on `/Rtmp`, not `/tmp`.
6. Keep OpenBLAS on the serial implementation.
7. Preserve executable shebang/strict-mode requirements for rendered shell scripts.
8. Update T2/T3 mirrors or record a tier delta.

Unverified: rendered files on a production host were not compared byte-for-byte with these sources during this audit.
