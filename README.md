<!-- README.md -->
# BIOME-CALC — RStudio Server + Nginx Portal + AD/OIDC Deployment Kit

![Shell](https://img.shields.io/badge/Shell-Bash-blue)
![OS](https://img.shields.io/badge/OS-Ubuntu%2024.04%20LTS-orange)
![Tier](https://img.shields.io/badge/T1-host%20authoritative-success)
![Rprofile](https://img.shields.io/badge/Rprofile__site-v12.10-blueviolet)
![License](https://img.shields.io/badge/License-GPL--3.0-green)

**BIOME-CALC / R-studioConf** is the host-tier (T1) automation kit for a shared,
multi-user **botanical big-data calculus platform**: RStudio Server (OSS) behind
an Nginx TLS portal, OIDC via oauth2-proxy, Active Directory identity via
**SSSD *or* Samba**, a `ttyd` web terminal, a telemetry API, and a hardened,
cgroup-bounded R runtime tuned for large spatial (`terra`/`sf`) and Bayesian
(`nimble`/`stan`) workloads.

It is built on **pessimistic system engineering**: assume failure, bound every
resource, fail fast, and keep the smallest blast radius. Documentation describes
the system *as it actually is* — not as we wish it were.

---

## ⚠️ Read this first

- **This README is a landing page.** The authoritative, role-indexed
  documentation lives in **[`docs/README.md`](docs/README.md)**.
- **To deploy:** follow
  **[`docs/deployment/INSTALLATION_GUIDE.md`](docs/deployment/INSTALLATION_GUIDE.md)**
  (Ubuntu 24.04, 5 phases, idempotent).
- **Known-defect register:** the deep audit at
  [`docs/audits/T1_HOST_DEPLOYMENT_AUDIT.md`](docs/audits/T1_HOST_DEPLOYMENT_AUDIT.md)
  tracks open correctness/hygiene items — read it before trusting any single
  script blindly (e.g. `restore_config()` and Uninstall are currently known-broken).

---

## Tier model

| Tier | Location | Status |
|------|----------|--------|
| **T1** | host (this repo: `scripts/`, `config/`, `templates/`, `lib/`) | **AUTHORITATIVE — continuously fixed** |
| **T2** | [`docker-deploy/`](docker-deploy/) | mirror of T1 — migration in progress |
| **T3** | [`kubernetes-deploy/`](kubernetes-deploy/) | skeleton — not production-ready |

**Rule:** every bug is fixed in **T1 first**, then ported forward T1 → T2 → T3.
A T2/T3 workaround must never mask a T1 defect. Full ethos: `.ai/agents.md`,
`.ai/project.yml`.

---

## Quickstart (T1 host)

```bash
git clone https://github.com/gsamuele78/R-studioConf.git
cd R-studioConf
bash init.sh        # chmods scripts/*, sudo-execs the orchestrator
```

`init.sh` launches **`r_env_manager.sh`** — an idempotent, lock-guarded
orchestrator that validates minimum memory/disk, then drives the numbered phase
scripts from an interactive menu.

| | |
|---|---|
| **Entry point** | `init.sh` → `r_env_manager.sh` |
| **Logs** | `/var/log/biome-log/core/r_env_manager.sh.log` |
| **State (idempotency)** | `/var/lib/r_env_manager/r_env_state` |
| **Config backups** | `/var/backups/r_env_manager/files/` |

> **Site-local secrets (since 2026-06-19).** Files carrying AD topology / PII
> are **not committed** — they ship as `*.example` and are sourced from a
> gitignored `config/site/` overlay with a fail-fast `__FILL_ME__` gate. Create
> the overlay once before deploying — see
> [`config/SITE_OVERRIDE.md`](config/SITE_OVERRIDE.md) and the
> [Installation Guide §4](docs/deployment/INSTALLATION_GUIDE.md).

---

## Repository layout (what the operator touches)

```
R-studioConf/
├── init.sh                 # bootstrap entry point
├── r_env_manager.sh        # idempotent orchestrator (v2.0.0)
├── Makefile                # `make audit` constraint gate, `make doc-coherence`
├── lib/common_utils.sh     # shared bash utilities (logging, backup, templating)
├── scripts/                # numbered phase scripts (01..50) + 99_* diagnostics + tools/
├── config/                 # *.vars.conf + r_env_manager.conf (+ *.example site overlay)
├── templates/              # rendered configs: Rprofile_site.d/, nginx_*, sssd/smb/krb5, portal HTML
├── docker-deploy/          # T2 — Docker Compose mirror (migration in progress)
├── kubernetes-deploy/      # T3 — manifests skeleton (not production-ready)
└── docs/                   # authoritative documentation library (start at docs/README.md)
```

Full inventories: [`docs/reference/SCRIPT_CATALOG.md`](docs/reference/SCRIPT_CATALOG.md),
[`docs/reference/CONFIGURATION_MAP.md`](docs/reference/CONFIGURATION_MAP.md),
[`docs/reference/TEMPLATE_GALLERY.md`](docs/reference/TEMPLATE_GALLERY.md).

### Deployment phases (run via the menu)

| Phase | Scripts | Purpose |
|------|---------|---------|
| 0 — System & time | `01_optimize_system.sh`, `02_configure_time_sync.sh` | VM tuning, ≤5 min Kerberos skew |
| 1 — Identity | `12_lib_kerberos_setup.sh`, `10_join_domain_sssd.sh` **or** `11_join_domain_samba.sh`, `13_harden_pam_password.sh` | AD join (pick one backend), PAM segfault fix |
| 2 — RStudio | `20_configure_rstudio.sh`, `21_helper_rstudio_version.sh` | RStudio Server + version pin |
| 3 — Web tier | `31_optimize_system.sh`, `30_install_nginx.sh`, `03_install_secure_access.sh`, `31_setup_web_portal.sh`, `32_setup_letsencrypt.sh` | Nginx, ttyd, portal, TLS |
| 4 — Telemetry & R runtime | `40_install_telemetry.sh`, `50_setup_nodes.sh` | Telemetry API + R runtime / Rprofile chain / `/Rtmp` |
| 5 — Verify | `99_health_check.sh`, `99_audit_r_environment.sh`, `test_rstudio_login.sh` | Smoke + audit |

---

## Engineering leverage — why this exists (infrastructure + R runtime)

The platform's value is not "installs R" — it is a set of deliberate
infrastructure and R-runtime decisions that make *portable, unmodified* user
code fast and crash-resistant on a contended multi-user host. The system adapts;
the researcher's `.R` is never edited (**HC-13**).

### Infrastructure choices

| Decision | Research / ops advantage | Reference |
|---|---|---|
| **cgroup user slices** (systemd) | Per-user CPU/RAM bounds enforced by the kernel — one runaway job cannot starve the host; OOM is contained, not catastrophic. | [`USER_QUOTAS_AND_RESOURCES.md`](docs/operations/USER_QUOTAS_AND_RESOURCES.md), [`architecture_analysis.md`](docs/architecture/architecture_analysis.md) |
| **`/Rtmp` 400 GB local ext4 scratch** (not `/tmp`, not NFS) | Spatial/MCMC temp I/O stays on fast local disk; `/tmp` overflow and NFS scratch latency disappear. | [`SYSTEM_OVERVIEW.md §7`](docs/architecture/SYSTEM_OVERVIEW.md), [`large_spatial_matrices.md`](docs/user_guides/large_spatial_matrices.md) |
| **Per-user local R-libs** `/var/lib/biome-Rlibs/<user>/<R-ver>/` (v12.4) | Kills the NFS lookup-storm when many PSOCK workers `library()` at once — measurable session-startup and parallel-launch speedup. | [`UPGRADE_TO_v12.4.md`](docs/operations/UPGRADE_TO_v12.4.md) |
| **OpenBLAS *serial*** (never `pthread`) | `pthread` BLAS forks unsafely under RStudio sessions → SIGSEGV; serial BLAS + explicit thread caps is correct *and* predictable. | [`INSTALLATION_GUIDE.md §6`](docs/deployment/INSTALLATION_GUIDE.md) |
| **Nginx TLS gateway + oauth2-proxy (OIDC)** | Auth delegated to an audited proxy; no credentials in JS; long-lived RStudio sessions get tuned proxy buffers/timeouts. | [`NGINX_GATEWAY.md`](docs/components/NGINX_GATEWAY.md), [`SECURITY_MODEL.md`](docs/architecture/SECURITY_MODEL.md) |
| **SSSD *XOR* Samba** AD backend per host | One identity path per node — no half-converted NSS/PAM stacks. | [`NGINX_AUTH_BACKENDS.md`](docs/reference/NGINX_AUTH_BACKENDS.md) |
| **Bind mounts only, pinned upstreams** (T2) | No Docker-managed volume lifecycle surprises; reproducible images. | [`COMPOSE_OPERATOR_RUNBOOK.md`](docs/deployment/COMPOSE_OPERATOR_RUNBOOK.md) |

### Modular Rprofile_site.d/ — the R-runtime "kernel" (v12.10)

`50_setup_nodes.sh` deploys a thin dispatcher (`/etc/R/Rprofile.site`) that
sources independent, versioned, `tryCatch`-isolated fragments in lexical order.
Each fragment is a safety/optimization guard that can be disabled per-session
(`BIOME_DISABLE_FRAGMENTS=45`) without touching user code — making it both an
operational kill-switch and a clean A/B surface for performance triage.

| Fragment | Optimization / research advantage |
|---|---|
| `05_thread_guard.R` | Cgroup-aware `detectCores()`; prevents BLAS thread-pool exhaustion from `mclapply`. |
| `20_cgroup_reader.R` | Reads real cgroup v1/v2 quota → R sees its *effective* core/RAM budget, not the host's. |
| `30_psock_factory.R` | `biome_make_cluster()` — NFS-safe, `MALLOC_ARENA_MAX`-aware PSOCK clusters. |
| `35_compile_routing.R` | Routes NIMBLE/TMB compile scratch to `/Rtmp` (`safe_compileNimble`). |
| `45_memory_guards.R` | Pre-flight RAM guards on `solve`/`dist`/`outer`/`expand.grid` — fail *before* OOM, not after. |
| `50_pkg_hooks.R` | Deferred per-package tuning (terra `todisk=TRUE`, cgroup-aware `terraOptions`, sf/stan/arrow/future…). |
| `52_mclapply_guard.R` | **Fork Guard** — auto-reroutes `mclapply` → PSOCK when fork-unsafe packages (terra/sf/GDAL) are loaded; PKG-SYNC + GLOBAL-SYNC replicate state to workers. |
| `55_options_guard.R` | Clamps `options(mc.cores)` to the slice's vcores — prevents oversubscription. |
| `60_safe_setwd.R` | Hard-fails `setwd()` on a missing path (the "Martina-gate" class of silent bug). |
| `04_user_lib_bootstrap.R` | Auto-creates + prepends the per-user local R-lib (the NFS-storm fix, runtime side). |

Authoring contract, load order, disable mechanisms and rollback:
[`templates/Rprofile_site.d/README.md`](templates/Rprofile_site.d/README.md).
Version history (HC-14, changelog-coupled):
[`docs/reference/Rprofile_site.CHANGELOG.md`](docs/reference/Rprofile_site.CHANGELOG.md).
Safe parallel patterns for users:
[`docs/user_guides/PARALLEL_R_DOS_AND_DONTS.md`](docs/user_guides/PARALLEL_R_DOS_AND_DONTS.md).

### HC-13 diagnostic harness — adapt the system, not the script

When a user job fails, `scripts/99_diagnose_user_script.sh` bisects the failure
across **L0** (minimal forensic profile, `r_minimal`) → **L2** (all fragments
off) → **L3** (full profile). A verdict of *"L3 FAILED, L2 PASSED"* pinpoints the
guilty fragment, which is patched and redeployed — the researcher re-runs their
**unchanged** `.R`. Worked example: [`LUSSU_HANG_BISECTION.md`](docs/operations/LUSSU_HANG_BISECTION.md).

---

## Documentation map

Start at **[`docs/README.md`](docs/README.md)** — it is role-indexed. Highlights:

| Audience | Entry point |
|---|---|
| Sysadmin (deploy/upgrade) | [`deployment/INSTALLATION_GUIDE.md`](docs/deployment/INSTALLATION_GUIDE.md) |
| Operator (day-2) | [`operations/OPERATOR_QUICKSTART.md`](docs/operations/OPERATOR_QUICKSTART.md), [`operations/TROUBLESHOOTING.md`](docs/operations/TROUBLESHOOTING.md) |
| On-call / incident | [`operations/DIAGNOSTICS_INDEX.md`](docs/operations/DIAGNOSTICS_INDEX.md) |
| Architect | [`architecture/SYSTEM_OVERVIEW.md`](docs/architecture/SYSTEM_OVERVIEW.md), [`architecture/architecture_analysis.md`](docs/architecture/architecture_analysis.md) |
| Developer | [`developer/README.md`](docs/developer/README.md), [`reference/SCRIPT_CATALOG.md`](docs/reference/SCRIPT_CATALOG.md) |
| End-user / botanist | [`user_guides/BOTANIST_CHEATSHEET.md`](docs/user_guides/BOTANIST_CHEATSHEET.md) |

Repo-wide change history: [`CHANGELOG.md`](CHANGELOG.md). Roadmap (OIDC,
Kubernetes, Open OnDemand, Positron): [`docs/FUTURE_MIGRATION.md`](docs/FUTURE_MIGRATION.md).

---

## Hard rules (excerpt)

Full list in `.clinerules` / `.cursorrules` / `.windsurfrules` and `.ai/project.yml`.
The most consequential:

- **HC-13** — Adapt the system to portable user R code; **never silently patch user scripts.**
- **HC-03** — Fix in T1 first, then port forward; no T2/T3 workaround masks a T1 defect.
- **HC-08** — `.env` / secret files are never committed; templates use placeholders only.
- **HC-14** — `RPROFILE_VERSION` bumps land with a matching CHANGELOG section + cross-doc refs in the same commit.
- R runtime invariants — BLAS = `libopenblas0-serial`; R temp = `/Rtmp` (never `/tmp`).

---

## License

GPL-3.0 — see [`LICENSE`](LICENSE).
