<!-- docs/deployment/INSTALLATION_GUIDE.md -->
# Installation Guide (T1 Host — Authoritative)

> **Tier:** T1 host — `AUTHORITATIVE_CONTINUOUSLY_FIXED`. T2 (`docker-deploy/`)
> and T3 (`kubernetes-deploy/`) mirror T1. Always fix here first, then port
> forward.  
> **Target OS:** Ubuntu **24.04 LTS** (server). Debian 12 is best-effort
> only — the PAM segfault fix and the modular Rprofile chain are tuned
> for 24.04.  
> **Last updated:** 2026-05-09.

This guide walks an operator through deploying the full
**Botanical Big Data Calculus Portal** (RStudio Server + Nginx Portal +
SSSD-or-Samba AD + ttyd + telemetry + node R runtime) onto a freshly
provisioned VM.

---

## 1. Prerequisites

* Ubuntu 24.04 LTS, root or `sudo` access.
* Joined-able to the AD domain (DIR/PERSONALE/STUDENTI realms).
* Open egress to: AD DCs (88/389/636), CRAN mirror, posit.co (RStudio
  download), Let's Encrypt (if `CERT_MODE=letsencrypt`), GitHub (R user
  packages from `R_USER_PACKAGES_GITHUB`).
* `/Rtmp` mount point: a dedicated **400 GB ext4 virtio disk** is
  expected. See [`../operations/add_storage_no_reboot.md`](../operations/add_storage_no_reboot.md).
* `apt`, `git`, `curl`, `jq` available.
* If on Proxmox: the VM should already exist; `01_optimize_system.sh`
  optimizes it from the **host side**.

---

## 2. Repository layout (only what the operator touches)

```
R-studioConf/
├── init.sh                 # bootstrap entry point
├── r_env_manager.sh        # idempotent orchestrator (v2.0.0)
├── Makefile                # `make audit` constraint gate
├── lib/common_utils.sh     # shared bash utilities
├── scripts/                # all numbered phase scripts + diagnostics
├── config/                 # 12 *.vars.conf + 2 *.txt + r_env_manager.conf
└── templates/              # 40+ rendered configs (Rprofile_site.d/, nginx_*, sssd, smb, krb5, portal HTML, …)
```

The full inventory is in [`../reference/SCRIPT_CATALOG.md`](../reference/SCRIPT_CATALOG.md),
[`../reference/CONFIGURATION_MAP.md`](../reference/CONFIGURATION_MAP.md), and
[`../reference/TEMPLATE_GALLERY.md`](../reference/TEMPLATE_GALLERY.md).

---

## 3. Bootstrap

```bash
git clone https://github.com/gsamuele78/R-studioConf.git
cd R-studioConf
bash init.sh
```

`init.sh` chmods every `scripts/*.sh` and `sudo`-execs
`r_env_manager.sh`. The manager:

1. acquires `/var/run/r_env_manager.sh.lock`,
2. validates min memory/disk from `config/r_env_manager.conf`,
3. opens an interactive menu over the numbered phases.

**Logs:** `/var/log/biome-log/core/r_env_manager.sh.log`  
**State:** `/var/lib/r_env_manager/r_env_state` (idempotency markers)  
**Backups:** `/var/backups/r_env_manager/files/<rotated-config-snapshots>`

---

## 4. Pre-deployment configuration

Edit the `.vars.conf` files for the components you intend to run.
**Do not edit secrets in-tree** — write Kerberos admin passwords,
GitHub PATs, and SMTP credentials to `0600` files outside the repo
(HR-8, HR-12).

| You will edit | If you are deploying |
|---|---|
| `config/optimize_system_proxmox.vm.vars.conf` | Proxmox-side VM tuning |
| `config/configure_time_sync.vars.conf` | Any node (Kerberos requires ≤5 min skew) |
| `config/lib_kerberos_setup.vars.conf` | All AD-joined nodes |
| `config/join_domain_sssd.vars.conf` **OR** `config/join_domain_samba.vars.conf` | Pick **one** auth backend |
| `config/configure_rstudio.vars.conf` | RStudio Server hosts |
| `config/install_nginx.vars.conf` | Public-facing portal node |
| `config/install_secure_access.vars.conf` | ttyd terminal node |
| `config/optimize_system.vars.conf` | Same node as Nginx |
| `config/setup_nodes.vars.conf` | All compute nodes (R runtime, /Rtmp, mail relay, orphan cron) |
| `config/r_env_manager.conf` | CRAN mirror, baseline R packages, GitHub PAT, min resources |

Per-variable explanation: [`../reference/CONFIGURATION_MAP.md`](../reference/CONFIGURATION_MAP.md).

---

## 5. Recommended deployment order

Run via the `r_env_manager.sh` menu (or directly if you know what you're
doing). Each script is idempotent and re-runnable.

### Phase 0 — System & time

1. `01_optimize_system.sh` *(Proxmox host only — applies VM-side tuning)*
2. `02_configure_time_sync.sh`

### Phase 1 — Identity (AD / Kerberos / PAM)

1. `12_lib_kerberos_setup.sh` *(sourced — but you can run it explicitly to render `/etc/krb5.conf` standalone)*
2. **Choose one:** `10_join_domain_sssd.sh` **or** `11_join_domain_samba.sh`
3. `13_harden_pam_password.sh` *(Ubuntu 24.04 — eliminates the `passwd` SIGSEGV for uid<10000. See [`PAM_HARDENING.md`](PAM_HARDENING.md).)*
4. `99_verify_domain_join.sh` *(sanity)*

### Phase 2 — RStudio Server

1. `20_configure_rstudio.sh`
2. `21_helper_rstudio_version.sh` *(invoked transparently by 20; can be run standalone to refresh the cached download URL)*

### Phase 3 — Web tier

1. `31_optimize_system.sh` *(Nginx-side kernel tuning — note this is NOT `01_optimize_system.sh`)*
2. `30_install_nginx.sh`
3. `03_install_secure_access.sh` *(ttyd + login wrapper)*
4. `15_setup_nginx_cleanup.sh` *(daily cron for proxy temp files)*
5. `31_setup_web_portal.sh`
6. `32_setup_letsencrypt.sh` *(only when `CERT_MODE=letsencrypt[-staging]`)*

### Phase 4 — Telemetry & node R runtime

1. `40_install_telemetry.sh`
2. `50_setup_nodes.sh` *(deploys `/etc/R/Rprofile.site` dispatcher + `/etc/R/Rprofile_site.d/*` fragments + `/etc/R/Renviron.site` + `/Rtmp` wiring + `r_minimal` launcher + (since v12.4) `/var/lib/biome-Rlibs/` local R-libs root + read-only NFS mount audit + optional Ollama AI; supports `--dry-run`, `--skip-ollama`, `--verify`; menu option `L` runs only the v12.4 R-libs + NFS-audit steps)*

### Phase 5 — Verification

1. `99_health_check.sh`
2. `99_audit_r_environment.sh`
3. `scripts/test_rstudio_login.sh` *(manual smoke test of PAM)*

---

## 6. R runtime hard rules (DO NOT VIOLATE)

These are baked into `Renviron.template`, the `Rprofile_site.d/`
fragments, and `setup_nodes.vars.conf`. Any deviation will cause
SIGSEGV, OOM-kill, or silent wrong-answer regressions.

| Rule | Why | Where |
|---|---|---|
| **BLAS = `libopenblas0-serial`** (NEVER `pthread`) | `pthread` BLAS forks unsafely under RStudio sessions → SIGSEGV. | `50_setup_nodes.sh`, `Rprofile_site.d/05_thread_guard.R.template`. |
| **R temp files in `/Rtmp`** (NEVER `/tmp`) | `/tmp` is small/tmpfs; spatial/MCMC code overruns it within minutes. `/Rtmp` is a 400 GB ext4 virtio disk. | `Renviron.template` (`TMPDIR=/Rtmp/$USER`), `Rprofile_site.d/35_compile_routing.R.template`, `60_safe_setwd.R.template`. |
| **Modular shell config in `/etc/biome-calc/profile.d/`** | Shell-side CORETYPE pin and OPENBLAS thread caps must apply BEFORE R starts. | `50_setup_nodes.sh`, sourced by `rstudio_user_login_script.sh.template`. |
| **HC-13 — Adapt System, Not User Script** | User R code is portable + read-only. System patches go into fragments / Renviron / mounts / cgroups. | All `99_diagnose_*` outputs steer fixes here. |
| **Forensic profile is `/etc/R/Rprofile_minimal.R`** | Used by `r_minimal` to prove a hang is in pure R, not in the dispatcher / fragments / user script. | `Rprofile_site.minimal.R.template`. |

> **Legacy env-var notice.** `BIOME_FORCE_NFS_TMP` from older Rprofile
> templates is **a no-op** in v12.2 — nodes have `/Rtmp` directly. Do
> not advertise it to users.

---

## 7. Known fix points (already applied by the scripts above)

| Bug | Fix script | Doc |
|---|---|---|
| `passwd` SIGSEGV on AD-joined Ubuntu 24.04 (uid<10000) | `13_harden_pam_password.sh` (new install) / `fix_pam_segfault_inplace.sh` (retrofit) | [`PAM_HARDENING.md`](PAM_HARDENING.md) |
| OpenBLAS-pthread SIGSEGV in RStudio fork | `50_setup_nodes.sh` pins `libopenblas0-serial` | rule above |
| `/tmp` overflow under spatial/MCMC | `/Rtmp` 400GB disk + `Renviron.template` | rule above |
| Lussu-style hang in `mclapply` over `terra::rast` | `99_diagnose_lussu_hang.sh` + `Rprofile_site.d/30_psock_factory.R.template` + (since v12.4) `Rprofile_site.d/52_mclapply_guard.R.template` | [`../operations/LUSSU_HANG_BISECTION.md`](../operations/LUSSU_HANG_BISECTION.md), [`../operations/UPGRADE_TO_v12.4.md`](../operations/UPGRADE_TO_v12.4.md) |
| NFS library-lookup storm on `library()` | (since v12.4) `R_LIBS_USER` defaults to local `/var/lib/biome-Rlibs/<user>/<R-ver>` with NFS fallback; deployed by `50_setup_nodes.sh` Step 7c | [`../operations/UPGRADE_TO_v12.4.md`](../operations/UPGRADE_TO_v12.4.md) |
| Silent CRAN drift between nodes | `99_check_pkg_drift.sh` + cron schedule from `setup_nodes.vars.conf` | [`../operations/MAINTENANCE.md`](../operations/MAINTENANCE.md) |
| Nginx temp dir bloat | `15_setup_nginx_cleanup.sh` daily cron | — |
| chrony pool newline edge case (Debian 12) | `02_configure_time_sync.sh` (FIXED) | — |

---

## 8. Verification checklist

Run after Phase 5 and after every R-version bump:

* [ ] `systemctl is-active rstudio-server nginx ttyd botanical-telemetry` → all `active`.
* [ ] `realm list` shows joined domain; `kinit administrator@<REALM>` succeeds.
* [ ] `id <ad-user>` resolves with the expected fallback homedir.
* [ ] `passwd <local-uid<10000>` runs to completion **without SIGSEGV**.
* [ ] `Rscript -e 'sessionInfo()'` shows `libRblas.so.3 -> libopenblas-serial.so.*`.
* [ ] `Rscript -e 'tempdir()'` returns a path under `/Rtmp/$USER`.
* [ ] `r_minimal -e 'cat(R.version.string,"\n")'` works (forensic launcher).
* [ ] `bash scripts/99_health_check.sh` → all green.
* [ ] Public portal URL serves the SPA over HTTPS with the expected cert.

---

## 9. Updates & re-runs

* Re-run `r_env_manager.sh` to pick up new R / RStudio versions
  (consults `21_helper_rstudio_version.sh`). Idempotent — touches only
  what changed.
* Re-render Nginx after editing a template:
  `sudo bash scripts/update_nginx_templates.sh`.
* Re-run `50_setup_nodes.sh` after editing any `Rprofile_site.d/*.R.template`.
* Backup snapshots accumulate in `/var/backups/r_env_manager/files/`;
  rotate manually per your retention policy.

---

## 10. Cross-references

* Tier model + ethos → `.ai/agents.md`, `.ai/project.yml`
* PAM segfault deep-dive → [`PAM_HARDENING.md`](PAM_HARDENING.md)
* Nginx auth backends comparison → [`../reference/NGINX_AUTH_BACKENDS.md`](../reference/NGINX_AUTH_BACKENDS.md)
* Operator quickstart (one-pager) → [`../operations/OPERATOR_QUICKSTART.md`](../operations/OPERATOR_QUICKSTART.md)
* Troubleshooting runbook → [`../operations/TROUBLESHOOTING.md`](../operations/TROUBLESHOOTING.md)
* Diagnostic toolbox → [`../operations/DIAGNOSTICS_INDEX.md`](../operations/DIAGNOSTICS_INDEX.md)
* T2 (Docker) walkthrough → [`COMPOSE_OPERATOR_RUNBOOK.md`](COMPOSE_OPERATOR_RUNBOOK.md)
* T1 → T2 → T3 promotion path → [`TIER_PROMOTION.md`](TIER_PROMOTION.md)
