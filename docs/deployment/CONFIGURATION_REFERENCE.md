<!-- docs/deployment/CONFIGURATION_REFERENCE.md -->
# Configuration Reference (T1 Host)

> **Tier:** T1.  
> **Last updated:** 2026-05-09.

This document is a thin operator-facing wrapper around the authoritative
[`../reference/CONFIGURATION_MAP.md`](../reference/CONFIGURATION_MAP.md).
Read that file for the per-variable matrix; this one explains the
**model**, the **R-runtime hard rules**, and the **tier policy**.

---

## 1. Configuration model

* **`config/*.vars.conf`** — bash `KEY=VALUE` files. Each numbered phase
  script reads exactly one (plus `lib_kerberos_setup.vars.conf` for
  Kerberos-aware scripts).
* **`config/r_env_manager.conf`** — orchestrator-level config (CRAN
  mirror, baseline R packages, GitHub PAT, min resources).
* **`config/admin_recipients.txt`, `config/user_email_map.txt`** —
  notification routing.
* **`templates/*.template`** — placeholder-substitution templates,
  rendered by `process_template` (see `lib/common_utils.sh`).

```
.vars.conf  ──source──►  scripts/NN_*.sh  ──process_template──►  rendered config (/etc/...)
```

> **Hard rules (compose-style, but apply to host configs too):**
> HR-7 every script begins `set -euo pipefail`;
> HR-8 passwords/PATs/SMTP creds → file with `0600`, never CLI;
> HR-12 `.env` and populated secret-bearing files are NEVER committed;
> HR-15 R BLAS = `libopenblas0-serial`;
> HR-16 JSON via `jq`, never `sed`/`awk`;
> HR-17 adapt the SYSTEM, not the user's R code.

---

## 2. Tier model (host vs docker vs k8s)

| Tier | Path | Status | Rule |
|---|---|---|---|
| **T1** | `/scripts/`, `/lib/`, `/config/`, `/templates/`, `init.sh`, `r_env_manager.sh` | `AUTHORITATIVE_CONTINUOUSLY_FIXED` | All bugs are fixed here first. |
| **T2** | `docker-deploy/` | `MIGRATION_IN_PROGRESS` (mirrors T1) | Any deviation must be recorded in `.ai/project.yml :: tier_deltas`. |
| **T3** | `kubernetes-deploy/` | `SKELETON_NOT_READY` (mirrors T1+T2) | Defer non-trivial work until T2 stabilizes. |

When a configuration variable changes in T1, the same variable must be
mirrored in `docker-deploy/.env` (or compose env section) and
`kubernetes-deploy/configmaps.yaml` / `secrets.yaml`. See
[`TIER_PROMOTION.md`](TIER_PROMOTION.md) for the porting checklist.

---

## 3. R runtime configuration (the high-blast-radius part)

These four artefacts must remain coherent. Editing any one without
updating the others **will** break sessions.

| Artefact | Owner script | Source template |
|---|---|---|
| `/etc/R/Rprofile.site` (thin **v12.4** dispatcher) | `50_setup_nodes.sh` | `templates/Rprofile_site.R.template` |
| `/etc/R/Rprofile_site.d/[0-9][0-9]_*.R` (modular fragments, incl. v12.4 `52_mclapply_guard.R`) | `50_setup_nodes.sh` | `templates/Rprofile_site.d/*.R.template` |
| `/etc/R/Rprofile_site.d/.compiled/{bundle.Rc,manifest.txt}` (**v12.3** byte-compiled fragment bundle — derived cache, NEVER source) | `50_setup_nodes.sh` Step 8 | (regenerated atomically; manifest mismatch silently demotes to legacy `sys.source()` loop) |

| `/etc/R/Rprofile_minimal.R` (L0/L1 forensic profile, NO `.d/`) | `50_setup_nodes.sh` | `templates/Rprofile_site.minimal.R.template` |
| `/etc/R/Renviron.site` (BLAS + `/Rtmp` + double-path `R_LIBS_USER`) | `50_setup_nodes.sh` | `templates/Renviron.template` |
| `/var/lib/biome-Rlibs/<user>/<R-ver>` (local R user-libs, sticky 1777) | `50_setup_nodes.sh` Step 7c | (created in-place; optional Mode B disk via `R_LIBS_LOCAL_DEVICE`) |

Plus the shell-side companion:

| Artefact | Owner script |
|---|---|
| `/etc/biome-calc/profile.d/*.sh` (CORETYPE pin, OPENBLAS thread caps) | `50_setup_nodes.sh` |

### Hard R-runtime rules

1. **BLAS pinning.** `libopenblas0-serial` package is installed; the
   `update-alternatives` selection is forced to the serial variant.
   `pthread` causes SIGSEGV inside RStudio's forked rsession.
2. **`/Rtmp` over `/tmp`.** A dedicated 400 GB ext4 virtio disk is
   mounted at `/Rtmp` per host. `Renviron.template` sets
   `TMPDIR=/Rtmp/$USER`; `Rprofile_site.d/60_safe_setwd.R` redirects
   stray `setwd("/tmp/...")` attempts.
3. **CORETYPE detection runs before R starts.** Three-level fallback:
   `/etc/biome-calc/profile.d/` → RStudio rsession-profile →
   `Rprofile_site.d/05_thread_guard.R`. Each level reads cgroup-derived
   limits.
4. **PSOCK over fork.** RStudio sessions must use PSOCK clusters
   (`Rprofile_site.d/30_psock_factory.R` + `40_wrapper_installer.R`).
   Since v12.4, `Rprofile_site.d/52_mclapply_guard.R` additionally
   reroutes `parallel::mclapply` to PSOCK whenever `terra`/`sf`/`raster`/
   `stars`/`torch`/`arrow` is loaded — eliminates the Lussu hang without
   editing user scripts (HC-13).
5. **Forensic profile is sacred.** `/etc/R/Rprofile_minimal.R` does NOT
   load `.d/` fragments. It is the L0/L1 isolation surface for the
   HC-13 harness; treat it as test infrastructure.
6. **Local-first `R_LIBS_USER` (v12.4).** `Renviron.site` ships
   `R_LIBS_USER=/var/lib/biome-Rlibs/%u/%v:${HOME}/R/x86_64-pc-linux-gnu-library/%v`.
   First entry is local (eliminates the NFS lookupcache storm); second
   is the legacy NFS fallback so existing user libraries keep working.
   New `install.packages()` lands locally. The `/var/lib/biome-Rlibs/`
   root is created with sticky `1777` by `50_setup_nodes.sh` Step 7c —
   optionally on a dedicated disk via `R_LIBS_LOCAL_DEVICE`.
7. **NFS audit is read-only (v12.4).** `50_setup_nodes.sh` Step 7d
   audits every NFS mount for `vers ≥ 4.1`, `nconnect ≥ 4`,
   `lookupcache=positive`. It **never** remounts — surfaces gaps via
   `[audit] WARN`. Fixes belong on TrueNAS / `/etc/fstab`, not in the
   script (PSE: detect, never silently coerce).

> **Legacy env-var.** `BIOME_FORCE_NFS_TMP` is a no-op since v12.2.
> Do not document it to users; do not test on it.

---

## 4. Where to look up specific variables

| You want to … | Read |
|---|---|
| Find the variable name for X | [`../reference/CONFIGURATION_MAP.md`](../reference/CONFIGURATION_MAP.md) §2 |
| Find which template a variable feeds | [`../reference/TEMPLATE_GALLERY.md`](../reference/TEMPLATE_GALLERY.md) |
| Find which script renders a template | [`../reference/SCRIPT_CATALOG.md`](../reference/SCRIPT_CATALOG.md) §2 |
| Compare SSSD vs Samba auth knobs | [`../reference/NGINX_AUTH_BACKENDS.md`](../reference/NGINX_AUTH_BACKENDS.md) |
| Track Rprofile evolution | [`../reference/Rprofile_site.CHANGELOG.md`](../reference/Rprofile_site.CHANGELOG.md) |

---

## 5. Cross-references

* Step-by-step deployment → [`INSTALLATION_GUIDE.md`](INSTALLATION_GUIDE.md)
* PAM segfault remediation → [`PAM_HARDENING.md`](PAM_HARDENING.md)
* Tier promotion (T1→T2→T3) → [`TIER_PROMOTION.md`](TIER_PROMOTION.md)
* Tier ethos & hard rules → `.ai/agents.md`, `.ai/project.yml`
