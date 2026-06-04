# RStudio / Positron June 2026 Capability Audit for R-studioConf

<!--
  File: docs/architecture/rstudio_positron_june_2026_capability_audit.md
  Created: 2026-06-04
  Purpose: Verified audit of production-ready RStudio OSS and Positron capabilities
           as of June 2026, cross-referenced against R-studioConf project invariants.
  Sources: Official Posit documentation only (docs.posit.co, positron.posit.co)
  Project: R-studioConf (RStudio Server + Nginx Portal + OIDC/SSSD/Samba)
  Tiering: T1=host authoritative | T2=docker migration | T3=k8s skeleton
-->

## 1. Verified Source List

All findings are sourced exclusively from official Posit public release notes,
accessed 2026-06-04. No secondary or community sources were used.

| Source | URL | Content |
|--------|-----|---------|
| RStudio / Posit Workbench Release Notes | <https://docs.posit.co/ide/news/> | All RStudio OSS and Posit Workbench releases, current through 2026.05.0 |
| Positron Release Notes | <https://positron.posit.co/release-notes.html> | All Positron standalone releases, current through 2026.06.0-211 |
| Project single-source-of-truth | config/r_env_manager.conf | Current RStudio version fallback and R configuration |
| Project install script | scripts/20_configure_rstudio.sh | Current RStudio Server configuration logic |

## 2. Current Project Baseline

As of 2026-06-04, the R-studioConf project is pinned to:

| Configuration | Current Value | Source |
|--------------|---------------|--------|
| RStudio version fallback | `2026.01.1+403` | config/r_env_manager.conf line 19 |
| RStudio architecture | `amd64` | config/r_env_manager.conf line 20 |
| CRAN mirror | `https://cloud.r-project.org` | config/r_env_manager.conf line 7 |
| RStudio bind address | `127.0.0.1:8787` | scripts/20_configure_rstudio.sh lines 55-56 |
| Authentication backends | SSSD and/or Samba/Winbind | scripts/20_configure_rstudio.sh lines 82-108 |
| Reverse proxy | Nginx (separate container/host) | docker-deploy/docker-compose.yml |

**Gap**: The project fallback `2026.01.1` is two releases behind the latest
verified RStudio release `2026.05.0` (2026-05-26). This is a T1 host concern
that must be addressed through the standard T1→T2→T3 port-forward workflow.

## 3. RStudio OSS 2026.05.0 — Production-Ready Capabilities

The following features are in the RStudio 2026.05.0 "Golden Wattle" OSS release
(2026-05-26) and are available to R-studioConf without requiring Posit Workbench.

### 3.1 Data Viewer Improvements

| Feature | GitHub Issue | Notes for R-studioConf |
|---------|-------------|------------------------|
| Faster data viewer rendering | #17539 | Improved UX for researcher data inspection |
| Pinnable columns | #17539 | Useful for wide ecological/geospatial tables |
| Summary sidebar with type-aware stats and sparkline histograms | #17539 | Can help users understand data shape without loading entire datasets into memory |
| Keyboard navigation | #17539 | Accessibility improvement |
| Clipboard copy | #17539 | Standard UX convenience |
| User preference `data_viewer_show_summary` | #17539 | Controls default visibility of Summary sidebar |
| Default `data_viewer_max_columns` raised from 50 to 200 | #17539 | ⚠️ This may increase session memory consumption. Evaluate whether to cap this lower for multi-user deployments with large datasets (common in ecological modeling) |
| Column count restored in status bar | #17613 | Shows "Showing rows 1 to N of M total rows, K total columns" |
| Limited horizontal overscroll so last column stays visible | #17612 | Prevents scroll-off issues with wide data |

### 3.2 Project Safety and Trust

| Feature | GitHub Issue | Notes for R-studioConf |
|---------|-------------|------------------------|
| Optional project trust dialog before executing `.Rprofile`, `.Renviron`, `.RData` | #17231 | **Strong candidate for production hardening** in shared AD environments. Enable with `project-trust-dialogs=1` in `rsession.conf`. Prevents untrusted user startup scripts from executing automatically. |
| `.positai` and `.claude` directories only added to ignore files when they exist | #17665 | Reduces noise in `.gitignore`/`.Rbuildignore` for projects not using AI features |

### 3.3 Session Stability

| Feature | GitHub Issue | Notes for R-studioConf |
|---------|-------------|------------------------|
| File descriptor soft limit raised at session startup on Linux | #16067 | Prevents "Too many open files" errors during project file monitoring. Relevant for large projects with many files. |
| Fixed debugger regressions for top-level breakpoints and multi-line input | #17481 | Important for researcher debugging workflows |
| Fixed hang when opening Quarto projects with large directories (e.g., `_targets/`) | #17176 | Relevant for projects using targets pipeline |
| Fixed tab completion on large Matrix sparse matrix objects causing hang/memory exhaustion | #17440 | Critical for ecological and geospatial R packages using Matrix |
| TCP keepalive enabled on server connections (Pro-only but OSS may benefit from OS-level equivalent) | rstudio-pro#10805 | Reduces stale connections from browser tab hibernation |

### 3.4 Package Management

| Feature | GitHub Issue | Notes for R-studioConf |
|---------|-------------|------------------------|
| Reduced filesystem work in `install.packages()` hook | rstudio-pro#10771 | Scoped to requested packages and their dependency closure rather than entire library. Important for shared libraries on NFS. |
| Tighter heuristic for detecting package-management commands at console | rstudio-pro#10771 | Reduces spurious Packages pane refreshes. |
| New `allow-package-source-recording` session option (default `true`) | #17514 | Controls whether `install.packages()` annotates DESCRIPTION files with remote repository. Consider setting to `false` if source attribution is not desired in shared environments. |
| Vulnerability info retrieved via updated PPM endpoint | #17446 | Ensures vulnerability scanning works with Package Manager 2026.04.0+ |

### 3.5 R 4.6.0 Compatibility

| Feature | GitHub Issue | Notes for R-studioConf |
|---------|-------------|------------------------|
| R 4.6.0 support added in 2026.04.0 | #10296 context | Only relevant if project R version is upgraded to 4.6.0 |
| Help pane argument alignment restored for R 4.6.0+ dynamic help server | #17621 | Required if upgrading to R >= 4.6.0 |
| `netrc` option support for R >= 4.6.0 | #16227 | Useful for authenticated package downloads |

### 3.6 R Session Configuration

| Feature | GitHub Issue | Notes for R-studioConf |
|---------|-------------|------------------------|
| `r-max-connections` session option (R >= 4.4.0) | #15360 | Controls maximum R connections. Only valid if running R >= 4.4.0. |
| Open-source Server Unix domain socket (`www-socket`) | #14938 | Potential advanced option for Nginx reverse proxy over Unix socket instead of TCP. Test in T1 first. |

### 3.7 Editor and IDE Improvements

| Feature | GitHub Issue | Notes for R-studioConf |
|---------|-------------|------------------------|
| Roxygen tag autocompletion in R Markdown/Quarto R code chunks | #5809 | Improves documentation workflow |
| Section headers fold hierarchically based on heading level | #16541 | Matches Positron behavior |
| `difftime` objects display formatted values in Environment pane | #17556 | Better UX for time-aware ecological analyses |
| Source-mode spell check now flags misspelled words in headings | #17568 | Improves document quality for reports |
| Files pane delete confirmation shows Trash vs permanent delete | #3780 | Prevents accidental permanent deletion on Linux Desktop |
| Restored terminal bell on Linux | #16966 | Fixed underlying Electron crash |
| Shiny test commands now use `shinytest2` | #17084 | `shinytest` is deprecated |

## 4. Positron 2026.06.0-211 — Production-Ready Desktop Capabilities

Positron 2026.06.0-211 (released June 2026) is a desktop IDE for data science.
It is **not a drop-in replacement for RStudio Server OSS** and is not available
as a browser-hosted service without Posit Workbench.

### 4.1 Production-Ready Positron Desktop Features

| Feature | GitHub Issue | Notes for R-studioConf |
|---------|-------------|------------------------|
| Inline Quarto output (out of preview) | #12737 | Strong feature for local Quarto authoring |
| R local symbol rename | #13749 | Cross-file rename not yet supported ("coming soon") |
| Go to Definition and Find References for R local symbols | #8631 | Within-file only for now |
| Interpreter discovery cache | #13133 | Speeds up Positron startup across folders/projects |
| Packages pane with R/Python management | Multiple | Selectable installer: pak, base R, or auto |
| Notebook improvements: JSON/LaTeX rendering, deferred kernel startup | Multiple | Better notebook experience |
| `ipydatagrid` and widget rendering fixed | #13708 | Fixes broken widget outputs |
| Windows multi-minute startup delay fixed | #12999 | `PATH` discovery skip by default |

### 4.2 Positron Integration Limitations

| Limitation | Impact on R-studioConf |
|-----------|------------------------|
| Positron is a desktop application, not a server | Cannot replace RStudio Server OSS in the current architecture |
| Positron Pro sessions require Posit Workbench | Not available in OSS RStudio Server deployments |
| Cross-file R refactoring not yet available | Users must use within-file rename only |
| Positron web mode requires Workbench | Static file serving from session-independent URLs is Workbench-only |

## 5. Workbench-Only Features (NOT Available in R-studioConf OSS Stack)

The following features from the 2026.05.0 release notes require **Posit Workbench**
(commercial license). They must not be listed as capabilities of the current
R-studioConf OSS deployment.

| Category | Feature | Pro Issue |
|----------|---------|-----------|
| Positron Pro Sessions | Browser-hosted Positron IDE sessions | rstudio-pro#10032, rstudio-pro#10974 |
| VS Code Sessions | Browser-hosted VS Code sessions via PWB Code Server | Various |
| Jupyter Sessions | Browser-hosted JupyterLab/Notebook sessions | Various |
| Multi-IDE Homepage | Project-based session launcher with all IDE types | rstudio-pro#10331 |
| Job Launcher | Kubernetes, Slurm, Local launcher with resource profiles | Various |
| Load Balancing | Multi-node Workbench cluster with database-backed state | Various |
| Managed Credentials | Snowflake, Databricks, AWS, Azure delegated credentials | Various |
| OAuth Custom Integrations | Multiple OAuth providers sharing same issuer URL | rstudio-pro#9818 |
| PKCE for OIDC | Proof Key for Code Exchange enabled by default | rstudio-pro#5766 |
| SCIM/JIT Provisioning | Automated user provisioning from IdP | rstudio-pro#9637 |
| Audit Database | Historical session data via `get_historical_session` API | rstudio-pro#8148 |
| Prometheus Metrics | Generally available in Workbench | rstudio-pro#8124 |
| SELinux Policy Module | Startup check for SELinux enforcement | rstudio-pro#10198 |
| Admin CLI Commands | Service account can run admin commands without root | rstudio-pro#10837 |
| Encrypted Client Secrets | `client-secret` encryption in OAuth/Databricks/Snowflake configs | rstudio-pro#9128 |
| Admin Dashboard | Server version, license, EOL warnings, log viewing | Various |
| R Console Auditing | Full audit of R console activity | rstudio-pro#3060 |
| Session Metadata DB | Database-backed session storage (replaces file storage) | rstudio-pro#9228 |
| Container User Creation | Dynamic container user creation for Launcher sessions | rstudio-pro#2714 |
| Workbench API | Launch sessions, list users, session hooks via API | Various |
| VS Code / Positron Extensions | Pre-configured extensions, custom bootstrap, admin settings | Various |
| Independent Positron Upgrades | Upgrade Positron without full Workbench upgrade | rstudio-pro#9824 |

## 6. Experimental / Preview Features (Excluded from Production)

Features explicitly marked as experimental, preview, or in transition must not
be listed as production-ready.

### 6.1 Positron 2026.06.0 Experimental Features

| Feature | Status | Notes |
|---------|--------|-------|
| Google Vertex AI provider | Experimental, behind `assistant.provider.googleVertex.enabled` | Do not use in production |
| Notebook "Visualize…" flow | Behind `positron.notebook.experimental` | Do not use in production |
| Old Positron Assistant (`positron.assistant.enable`) | Being deprecated in favor of Posit Assistant | Do not build new workflows on the old assistant |
| Cross-file R symbol rename | Not yet supported (release notes say "coming soon") | Not available |

### 6.2 Posit Workbench 2026.05.0 Preview Features

| Feature | Status | Notes |
|---------|--------|-------|
| `assistant-enabled` in `/etc/rstudio/profiles` | Preview setting for unified Assistant control | Do not treat as GA |
| Admin configuration UI for Launcher settings | Preview | Not production-ready |
| `session-use-file-storage=0` for database-backed sessions | Added but evaluate carefully | |

### 6.3 AI Assistant General Considerations

All AI assistant features (Posit Assistant, GitHub Copilot, Next Edit Suggestions)
require:

- Provider account and subscription (e.g., Posit AI).
- Data governance review (code and data may be sent to external services).
- Secret management for API keys and credentials.
- Telemetry and usage data policies.
- Explicit opt-in decision for the deployment.

**These must not be enabled by default without an explicit governance decision.**

## 7. R-studioConf Project Assessment

### 7.1 Current Architecture Compatibility

The current R-studioConf OSS stack remains the correct production choice:

- ✅ RStudio Server OSS (behind Nginx reverse proxy).
- ✅ PAM authentication via SSSD and/or Samba/Winbind.
- ✅ Bind mounts only (no named Docker volumes).
- ✅ Centralized R configuration via `config/r_env_manager.conf`.
- ✅ All scripts use `set -euo pipefail` (where enabled; note `20_configure_rstudio.sh` line 2 has `set -euo pipefail` commented out — this should be fixed in T1).
- ✅ Passwords written to files, not CLI arguments.
- ✅ PostgreSQL ports never exposed to host.
- ✅ Pinned image versions (no `:latest`).

### 7.2 Version Gap

| Component | Project Pinned Version | Latest Verified Version | Gap |
|-----------|----------------------|------------------------|-----|
| RStudio Server | `2026.01.1+403` | `2026.05.0` | 2 releases behind |
| Positron (standalone) | Not in scope | `2026.06.0-211` | N/A (desktop-only) |
| Positron Pro (Workbench) | Not in scope | `2026.05.2-3` (bundled with Workbench 2026.05.0) | N/A (requires Workbench) |

### 7.3 Script Compliance Issues Found

| Script | Issue | Severity |
|--------|-------|----------|
| `scripts/20_configure_rstudio.sh` line 2 | `set -euo pipefail` is commented out (`#set -euo pipefail`) | **High** — violates hard rule 7 |

## 8. Recommended Actions

### 8.1 Immediate (T1 Host — Authoritative)

1. **Fix `scripts/20_configure_rstudio.sh`**: Uncomment `set -euo pipefail` on line 2.

2. **Evaluate RStudio upgrade to 2026.05.0**:
   - Test the upgrade in T1 host first.
   - Verify all existing configurations (PAM, Nginx proxy, session settings) remain compatible.
   - Update `RSTUDIO_VERSION_FALLBACK` in `config/r_env_manager.conf` only after successful T1 testing.
   - Port forward T1 → T2 → T3 only after T1 validation.

3. **Evaluate project trust dialogs**:
   - Consider adding `project-trust-dialogs=1` to `rsession.conf` for multi-user AD environments.
   - This prevents execution of untrusted `.Rprofile`/`.Renviron`/`.RData`.

4. **Review `data_viewer_max_columns`**:
   - The new default of 200 may be too high for multi-user sessions with large geospatial/ecological datasets.
   - Consider capping at a lower value in `rsession.conf` if memory pressure is observed.

### 8.2 Medium-Term (T2 Docker — Mirror T1)

1. After T1 RStudio upgrade is validated, rebuild Docker images with the new RStudio version.
2. Ensure `Dockerfile` pins the exact RStudio version (no `:latest`).
3. Verify all compose deploy resource limits are still appropriate.

### 8.3 Deferred (T3 Kubernetes — Skeleton)

1. Document that Posit Workbench features (Positron Pro, VS Code, Jupyter, Job Launcher) are not available in T3 until a commercial Workbench license is in place.
2. T3 remains skeleton/not-ready as declared in the project ethos.

### 8.4 Out of Scope (Not Recommended Without Governance Decision)

- Enabling any AI assistant features (Posit Assistant, Copilot, NES).
- Migrating to Posit Workbench for Positron Pro sessions.
- Enabling experimental Positron features in production.
- Changing R version without updating `config/r_env_manager.conf` and `configmaps.yaml` together.

## 9. Tier Deltas

### 9.1 T1 → T2 Deltas

| Delta | Rationale |
|-------|-----------|
| RStudio version in Docker must match T1 validated version | Hard rule 1: T2 mirrors T1 |
| Docker healthcheck must use same RStudio health endpoint as T1 | Same behavior expected |
| Docker resource limits must accommodate new data viewer memory profile | New defaults may increase per-session memory |

### 9.2 T1 → T3 Deltas (Skeleton — Honest Gaps)

| Gap | Surface Honestly |
|-----|-----------------|
| Positron Pro sessions not available | Requires Posit Workbench license |
| Multi-IDE homepage not available | Workbench-only feature |
| Job Launcher with resource profiles not available | Workbench-only feature |
| Managed credentials not available | Workbench-only feature |
| Prometheus metrics not available at T3 | Workbench-only feature; T3 skeleton only |
| Load balancing not available at T3 | Workbench-only feature |
| Audit database not available | Workbench-only feature |

---

*Audit prepared 2026-06-04. Sources: docs.posit.co/ide/news/ and positron.posit.co/release-notes.html.*
*Project invariant: T1 authoritative, fix first in T1, port forward T1→T2→T3.*
