<!-- docs/architecture/rstudio_positron_june_2026_capability_audit.md -->
---
title: "RStudio and Positron Capability Audit"
audience: architect
status: needs-review
tier: T1
source_path: docs/architecture/rstudio_positron_june_2026_capability_audit.md
last_verified: 2026-10-06
---

# RStudio and Positron Capability Audit

## 1. Audit status

The original 2026-06-04 audit combined repository facts with a point-in-time
reading of Posit release notes. This revision revalidates every project claim
against the repository on 2026-10-06. It does not present June release-note
claims as current upstream facts.

**Status: needs-review.** The repository baseline is verified. Upstream RStudio,
Positron, and Workbench capabilities require a new official-source review
before publication as a current product capability matrix.

## 2. Verified project baseline

| Item | Repository value | Source |
|---|---|---|
| Deployment tier | T1 host is authoritative | `.ai/project.yml` |
| T2 status | `MIGRATION_IN_PROGRESS` | `.ai/project.yml` |
| T3 status | `SKELETON_NOT_READY` | `.ai/project.yml` |
| RStudio fallback version | `2026.01.1+403` | `config/r_env_manager.conf` |
| RStudio fallback architecture | `amd64` | `config/r_env_manager.conf` |
| CRAN mirror | `https://cloud.r-project.org` | `config/r_env_manager.conf` |
| T1 RStudio listener | `127.0.0.1:8787` | `config/configure_rstudio.vars.conf` |
| T1 RStudio edition | RStudio Server OSS | scripts and project context |
| T1 identity | PAM through SSSD **or** Samba/Winbind | `scripts/20_configure_rstudio.sh` |
| T1 reverse proxy | Host Nginx | `scripts/30_install_nginx.sh` |
| T1 OIDC | Not implemented | no T1 oauth2-proxy or `auth_request` source |
| T2 OIDC | Optional oauth2-proxy v7.6.0-alpine profile | `docker-deploy/docker-compose.yml` |
| Rprofile | 12.10 with 14 active fragments | `config/setup_nodes.vars.conf`, `templates/Rprofile_site.d/` |
| R temp | `/Rtmp`, 400 GiB local ext4 | `config/setup_nodes.vars.conf`, `templates/Renviron.template` |
| BLAS | `libopenblas0-serial` | `scripts/50_setup_nodes.sh`, `.ai/project.yml` |
| Positron project status | `EVALUATION_PENDING`, T2/T3 only | `.ai/project.yml` |
| Workbench | No implementation or license configuration in repo | repository search |

`RSTUDIO_VERSION_FALLBACK` is a configuration fallback, not proof of the
version installed on a running host.

**Unverified:** the RStudio Server version currently installed on each
deployed node.

## 3. Changes since the June audit

The June document predates 47 commits on the current branch after 2026-06-08.
Relevant merged changes include:

- site-local secret and PII overlays under gitignored `config/site/`;
- replacement of false-green CI with active T1, R runtime, Nginx, T2, and
  package-manifest gates;
- corrections to the HC-13 diagnostic ladder and process cleanup;
- fixes for the RStudio login script reintroducing `R_LIBS_USER`;
- self-contained T2/T3 directories vendored by Infra-Iam-PKI;
- exact T2 image pins and Step-CA trust bootstrap;
- T2 build fixes and permanent removal of bspm/r2u from container images;
- oauth2-proxy and docker-socket-proxy health checks;
- docker-socket-proxy v0.5.0 on a loopback-published bridge;
- T3 NetworkPolicies and pinned custom images;
- a quota diagnostic that writes and fsyncs 1 MiB to detect TrueNAS `EDQUOT`.

The June finding that `scripts/20_configure_rstudio.sh` had strict mode
commented out is still true on 2026-10-06. It must not be reported as fixed.

## 4. June 2026 upstream snapshot

The following values are retained only to explain what the original audit
reviewed:

| Product | June document claimed | Current verification state |
|---|---|---|
| RStudio OSS | 2026.05.0 “Golden Wattle” | **Unverified:** not rechecked against current official release notes |
| Positron desktop | 2026.06.0-211 | **Unverified:** not rechecked against current official release notes |
| Positron Pro | Bundled with Posit Workbench | **Unverified:** current packaging and licensing not rechecked |

The original audit listed Data Viewer changes, project trust dialogs, R 4.6
support, Unix-domain socket support, package-management changes, and editor
improvements. Those remain a historical June release-note summary, not a
statement that BIOME-CALC enables or configures each feature.

## 5. Capabilities active in BIOME-CALC

These capabilities are supported by project code, independent of newer IDE
release notes:

- RStudio Server OSS behind host Nginx TLS.
- RStudio PAM authentication through one AD backend.
- RStudio wrapper at `/rstudio/` and backend root path `/rstudio-inner`.
- WebSocket proxying, disabled proxy buffering, 10 GiB upload limit, and long
  read/send timeouts.
- systemd per-user cgroup controls.
- Rprofile 12.10 runtime guards and diagnostic helpers.
- local `/Rtmp` and local per-user compiled package libraries.
- host ttyd, telemetry, node exporter, and optional Ollama.

The active T1 `rsession.conf` writer configures session timeout, WebSocket log
level, offline handling, connection/external-pointer suspend blocking,
Copilot disabled by default, and `session-save-action-default=no`.

The repository does **not** currently configure the June audit's proposed
`project-trust-dialogs`, `data_viewer_max_columns`, `r-max-connections`, or
RStudio `www-socket` settings.

## 6. Capabilities not present

No repository implementation exists for:

- browser-hosted Positron sessions;
- Posit Workbench;
- Job Launcher;
- Workbench load balancing or session-state database;
- Workbench multi-IDE home page;
- Workbench audit database or administrative dashboard;
- Workbench-managed cloud credentials;
- Workbench SCIM/JIT provisioning;
- Positron server deployment;
- Positron-specific configuration, dependency, or CI rule.

These must not be described as current T1, T2, or T3 capabilities.

## 7. R and RStudio version governance

HC-15 requires R and RStudio versions to map dynamically from the canonical
configuration files rather than being silently overridden in deployment code.

- T1 uses `config/r_env_manager.conf` for the RStudio fallback.
- T3 currently declares `RSTUDIO_VERSION=2026.01.1+403` and
  `R_VERSION=4.6.0` in `kubernetes-deploy/configmaps.yaml`.
- The canonical T1 Rprofile template describes R 4.5.x.

The T1/T3 R version values are not aligned in source. Because T3 is a skeleton,
this is not evidence that production runs R 4.6.0; it is a parity issue that
must be resolved before T3 promotion.

**Unverified:** the exact R version installed on each T1 host. Do not infer it
from the T3 ConfigMap.

## 8. T2 and T3 implications

### 8.1 T2

T2's RStudio images are based on pinned `rocker/geospatial:4.4.2`, not the T1
host installer. T2 remains behind T1's R runtime (`TD-T2-01`) and has no
bspm/r2u (`TD-T2-05`). An IDE version change in T1 does not become a T2
capability until images are rebuilt and parity is verified.

### 8.2 T3

T3 is not a delivery vehicle for Workbench or Positron. Its current manifests
do not add those products, and the tier remains blocked from production use.

## 9. Positron decision boundary

The repository decision is explicit:

```text
Status: EVALUATION_PENDING
Scope: T2 and T3 only
Trigger: adopt only if Positron demonstrably resolves a known T1 issue
Do not add Positron files, dependencies, or rules before that trigger
```

No merged patch has changed that decision. Positron must therefore remain
outside current deployment instructions and current capability lists.

## 10. Items requiring external re-verification

Before this document can be marked `current`, verify against official Posit
sources and record the access date:

1. Latest supported RStudio Server OSS release and its Linux requirements.
2. Current support status of `project-trust-dialogs`, `www-socket`, and
   `r-max-connections` in the OSS edition.
3. Current Positron desktop release and supported operating systems.
4. Whether any browser-hosted Positron offering is available without Posit
   Workbench.
5. Current Workbench-only boundaries for multi-session, Job Launcher,
   load balancing, metrics, audit, and managed credentials.
6. R version compatibility for the intended RStudio release.

Until that review is complete, do not describe `2026.05.0` or
`2026.06.0-211` as latest.

## 11. Project compliance findings

| Finding | State on 2026-10-06 |
|---|---|
| T1 first, then T2/T3 | Active project rule |
| Rprofile 12.10 changelog coupling | Active |
| `/Rtmp` for T1 R temp | Active invariant |
| OpenBLAS serial | Active invariant |
| `20_configure_rstudio.sh` strict mode | Non-compliant: commented out |
| Portal external Google Fonts | Non-compliant with HC-11 |
| T1 OIDC | Not implemented |
| T2 OIDC | Optional profile, end-to-end behavior unverified |
| Positron | Not implemented; evaluation pending |
| T3 production readiness | Not ready |

## 12. Sources

Repository sources used for the 2026-10-06 revalidation:

- `.ai/project.yml`
- `CHANGELOG.md`
- `config/r_env_manager.conf`
- `config/configure_rstudio.vars.conf`
- `config/setup_nodes.vars.conf`
- `scripts/20_configure_rstudio.sh`
- `scripts/50_setup_nodes.sh`
- `templates/Rprofile_site.R.template`
- `templates/Rprofile_site.d/`
- `docker-deploy/docker-compose.yml`
- `docker-deploy/Dockerfile*`
- `kubernetes-deploy/configmaps.yaml`
- `git log --since=2026-06-08`

Historical external sources from the June snapshot, not revalidated here:

- <https://docs.posit.co/ide/news/>
- <https://positron.posit.co/release-notes.html>

---

*Repository baseline verified 2026-10-06. Upstream product capability claims remain marked Unverified pending a new official-source review.*
