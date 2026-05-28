# CRAN Snapshot Pinning via Posit Public Package Manager (P3M)

Pin all R package installations cluster-wide to a **date-frozen CRAN snapshot** via Posit Public Package Manager. This ensures every `install.packages()` on any of the 4 RStudio nodes resolves to the exact same package version, preventing version drift in the user R library layer.

## How P3M snapshot URLs work

Posit Public Package Manager mirrors CRAN and creates daily snapshots. Replacing the default CRAN URL:

```
https://cloud.r-project.org                               ← always-latest (drifts)
https://p3m.dev/cran/__linux__/noble/2026-05-28            ← frozen to May 28th 2026
```

The `__linux__/noble` path serves **pre-compiled Linux binaries** for Ubuntu 24.04 — installs are fast (no compilation), and every node gets the exact same `.so` artifacts. The date `2026-05-28` is the snapshot; all packages behind that URL are frozen at their state on that date.

## Integration points (3 files, 1 new conf variable)

### What changes where

| File | Change | Purpose |
|------|--------|---------|
| `config/setup_nodes.vars.conf` | Add `CRAN_SNAPSHOT_DATE` variable | Single source of truth for the frozen date |
| `templates/Renviron.template` | Change `R_REPOS` from `cloud.r-project.org` to P3M snapshot URL using `%%CRAN_SNAPSHOT_DATE%%` | Controls where `install.packages()` resolves for ALL R processes |
| `templates/Rprofile_site.R.template` | Update the `options(repos = ...)` line to use the same snapshot URL | Controls where RStudio UI "Install Packages" button resolves |

---

## Proposed Changes

### Config

#### [MODIFY] [setup_nodes.vars.conf](file:///home/jfs/00_Antigravity_workspace/R-studioConf/config/setup_nodes.vars.conf)

Add a new configuration block after the `R_PACKAGES` array (around line 299):

```bash
# =============================================================================
# CRAN SNAPSHOT PINNING (anti-drift)
# =============================================================================
# Freeze all install.packages() calls cluster-wide to a specific CRAN date
# snapshot via Posit Public Package Manager (P3M). Every node resolves the
# same package versions regardless of when or where the user runs install.
#
# Format: YYYY-MM-DD (valid P3M snapshot date) or "latest" (no pin — live CRAN).
# To advance: change the date, re-run 50_setup_nodes.sh on all 4 nodes.
#
# Binary packages for Ubuntu 24.04 (noble) are served pre-compiled — no build
# tools needed for standard CRAN packages. Packages not on P3M fall through
# to source compilation automatically.
#
# Workflow for upgrading:
#   1. Pick a date when your critical packages (nimble, brms, terra, sf) are
#      known-good on the new R version
#   2. Update CRAN_SNAPSHOT_DATE below
#   3. Re-run 50_setup_nodes.sh on all 4 nodes (idempotent)
#   4. Users' next install.packages() gets the new snapshot automatically
CRAN_SNAPSHOT_DATE="2026-05-28"
```

---

### Renviron template

#### [MODIFY] [Renviron.template](file:///home/jfs/00_Antigravity_workspace/R-studioConf/templates/Renviron.template)

Change the `R_REPOS` line (line 151) from:

```diff
-R_REPOS=https://cloud.r-project.org
+# CRAN snapshot via Posit Public Package Manager — frozen to a specific date
+# so all 4 nodes resolve identical package versions. Pre-compiled binaries
+# for Ubuntu 24.04 (noble). Change date in config/setup_nodes.vars.conf.
+# Set CRAN_SNAPSHOT_DATE="latest" to use live CRAN (not recommended).
+R_REPOS=https://p3m.dev/cran/__linux__/noble/%%CRAN_SNAPSHOT_DATE%%
```

---

### Rprofile template

#### [MODIFY] [Rprofile_site.R.template](file:///home/jfs/00_Antigravity_workspace/R-studioConf/templates/Rprofile_site.R.template)

Change the `options(repos = ...)` line (line 531) from:

```diff
-    repos = c(CRAN = "https://cloud.r-project.org"),
+    repos = c(CRAN = "https://p3m.dev/cran/__linux__/noble/%%CRAN_SNAPSHOT_DATE%%"),
```

---

## User Review Required

> [!IMPORTANT]
> **Choosing the initial snapshot date:** I'll default to `2026-05-28` (today). You can change this to any date when you've verified your critical stack (NIMBLE, brms, cmdstanr, terra, sf) works correctly. P3M keeps snapshots going back years.

> [!IMPORTANT]
> **Upgrade workflow:** When you want to advance to newer packages:
> 1. Pick a new date (e.g. after confirming NIMBLE 1.x works with the new Rcpp)
> 2. Change `CRAN_SNAPSHOT_DATE` in `setup_nodes.vars.conf`
> 3. Re-run `50_setup_nodes.sh` on all 4 nodes — this deploys the new `Renviron.site` and `Rprofile.site`
> 4. Users' next `install.packages()` automatically pulls from the new snapshot
> 5. Old packages on local disk keep working until the user explicitly reinstalls

> [!WARNING]
> **bspm interaction:** Your cluster uses `bspm` which routes `install.packages()` through `apt` for available `r-cran-*` packages. bspm checks the system repo, not the R `repos` option. For packages that bspm handles (the ~150 `r-cran-*` debs in Ubuntu), the version comes from **apt**, not P3M. The `pin_r_version.sh` stanza with `Pin: release o=CRAN` / `Pin-Priority: 500` already handles that layer. P3M covers the remaining ~20,000 CRAN packages that bspm doesn't have debs for — which is where most version drift actually happens (nimble, brms, cmdstanr, prioritizr, etc.).

## Open Questions

1. **Snapshot date:** Is `2026-05-28` (today) acceptable as the initial freeze date, or do you have a specific "known good" date in mind?
2. **`50_setup_nodes.sh` template substitution:** Does the deploy script already handle `%%CRAN_SNAPSHOT_DATE%%` placeholder substitution from vars.conf, or does it need a new substitution rule? I need to verify how `process_template` is called for these templates.

## Verification Plan

### Automated Tests
- `bash -n` syntax check on all modified templates
- Dry-run the template substitution to verify `%%CRAN_SNAPSHOT_DATE%%` resolves correctly
- `curl -I https://p3m.dev/cran/__linux__/noble/2026-05-28/src/contrib/PACKAGES` — verify the snapshot URL returns 200

### Manual Verification
- After deploy: `R -e 'getOption("repos")'` on any node should show the P3M snapshot URL
- `install.packages("jsonlite")` on two different nodes should produce identical package versions
