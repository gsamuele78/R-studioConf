<!-- docs/SHAREPOINT_PUBLICATION.md -->
# SharePoint / Wiki Publication Guide — BIOME-CALC Documentation

> **Audience:** sysadmin / documentation maintainer
> **Status:** interim — created 2026-06-08
> **Principle:** Markdown files in `docs/` are the **authoritative source**.
> SharePoint pages are **published copies**, regenerated from Markdown when
> the source changes.

---

## 1. Information Architecture for SharePoint

The documentation is organized into two audience-specific hubs:

### Researcher Hub ("BIOME-CALC User Guide")

Target: botanists, ecologists, data scientists running R on the platform.

| SharePoint Section | Source Markdown | Notes |
|---|---|---|
| Getting Started | `docs/user_guides/BOTANIST_CHEATSHEET.md` | One-page quick reference |
| User Guide (Italian) | `docs/user_guides/User_guide.md` | Full Italian-language guide |
| Understanding the Server | `docs/user_guides/understanding_the_new_server.md` | Why the platform behaves as it does |
| Safe Parallel R | `docs/user_guides/PARALLEL_R_DOS_AND_DONTS.md` | Do's and Don'ts for parallel code |
| Large Spatial Data | `docs/user_guides/large_spatial_matrices.md` | terra/sf workflows for large rasters |
| NIMBLE MCMC Guide | `docs/user_guides/NIMBLE_User_Guide.md` | Parallel Bayesian modeling |
| Advanced Helpers | `docs/user_guides/SERVER_NATIVE_API.md` | biome_*() helper functions |
| Session Isolation | `docs/user_guides/rstudio_session_isolation.md` | How sessions are isolated |
| Session FAQ (Italian) | `docs/user_guides/risposta_ricercatore_sessioni_rstudio.md` | Italian session FAQ |
| User Contract | `docs/architecture/USER_CONTRACT.md` | What "portable R" means |

### Sysadmin / Operator Hub ("BIOME-CALC Operations")

Target: IT officers, system administrators, operators.

| SharePoint Section | Source Markdown | Notes |
|---|---|---|
| Architecture Overview | `docs/architecture/SYSTEM_OVERVIEW.md` | High-level design |
| Security Model | `docs/architecture/SECURITY_MODEL.md` | Auth flows, isolation |
| Installation Guide | `docs/deployment/INSTALLATION_GUIDE.md` | From-scratch deployment |
| Configuration Reference | `docs/deployment/CONFIGURATION_REFERENCE.md` | All config keys |
| Compose Runbook | `docs/deployment/COMPOSE_OPERATOR_RUNBOOK.md` | T2 Docker operations |
| Tier Promotion | `docs/deployment/TIER_PROMOTION.md` | T1→T2→T3 fix flow |
| Operator Quickstart | `docs/operations/OPERATOR_QUICKSTART.md` | Day-2 cheat sheet |
| Troubleshooting | `docs/operations/TROUBLESHOOTING.md` | Symptom-indexed runbook |
| Diagnostics Index | `docs/operations/DIAGNOSTICS_INDEX.md` | All diagnostic scripts |
| Maintenance | `docs/operations/MAINTENANCE.md` | Scheduled tasks |
| User Quotas | `docs/operations/USER_QUOTAS_AND_RESOURCES.md` | cgroup resource controls |
| Script Catalog | `docs/reference/SCRIPT_CATALOG.md` | Complete script inventory |
| Template Gallery | `docs/reference/TEMPLATE_GALLERY.md` | Template reference |
| Rprofile Changelog | `docs/reference/Rprofile_site.CHANGELOG.md` | Version history |
| Future Migration | `docs/FUTURE_MIGRATION.md` | Roadmap |

### Internal / Not for SharePoint

These documents contain operator-only internals and should **not** be published
to researcher-facing SharePoint pages:

- `docs/DOCUMENTATION_AUDIT.md` — internal audit register
- `docs/developer/*` — internal development reference
- `docs/operations/LUSSU_HANG_BISECTION.md` — worked example with user data
- `docs/operations/CLEAN_VM_BASELINE.md` — internal SOP
- `docs/operations/diagnostic_logs.md` — internal log paths
- `docs/operations/sysadmin_troubleshooting_guide.md` — internal handbook
- `docs/archiver/*` — internal archive procedures
- `docs/orphan_cleanup/*` — internal cleanup procedures

---

## 2. Markdown Conventions for SharePoint Conversion

### 2.1 Front Matter

Every Markdown file intended for SharePoint publication should include
a YAML front matter block at the top. This is stripped during conversion
and used to populate SharePoint metadata columns.

```yaml
---
title: "Safe Parallel R — Do's and Don'ts"
audience: researcher
status: current
tier: T1
source_path: docs/user_guides/PARALLEL_R_DOS_AND_DONTS.md
last_verified: 2026-06-08
sharepoint_section: Researcher Hub
---
```

**Required fields:**

- `title` — page title as it appears in SharePoint navigation
- `audience` — one of: `researcher`, `sysadmin`, `operator`, `developer`, `architect`
- `status` — one of: `current`, `needs-review`, `draft`, `legacy`
- `source_path` — relative path from repo root to the authoritative Markdown file
- `last_verified` — ISO date of last accuracy verification

**Optional fields:**

- `tier` — deployment tier: `T1`, `T2`, `T3`
- `sharepoint_section` — which SharePoint hub/section this belongs to
- `tags` — comma-separated keywords for SharePoint search

### 2.2 Source Path Footer

Every SharePoint page should include a footer block identifying the
authoritative Markdown source:

```markdown
---
*Authoritative source: [`docs/user_guides/PARALLEL_R_DOS_AND_DONTS.md`](https://github.com/gsamuele78/R-studioConf/blob/main/docs/user_guides/PARALLEL_R_DOS_AND_DONTS.md) — last verified 2026-06-08. This SharePoint page is a published copy; the Markdown file in git is the source of truth.*
```

### 2.3 Internal Links

All cross-references within `docs/` use **relative paths**:

```markdown
See [User Contract](../architecture/USER_CONTRACT.md) for details.
```

During SharePoint conversion, these are rewritten to point to the
corresponding SharePoint page URLs. The conversion tool must maintain
a mapping table of `source_path → sharepoint_url`.

### 2.4 Images and Assets

All images referenced in documentation must be stored in `assets/`
and referenced with relative paths:

```markdown
![BIOME-CALC Architecture](../assets/composite_logo_transparent.png)
```

During SharePoint conversion, images are uploaded to a SharePoint
Document Library and links are rewritten.

---

## 3. Conversion Workflow

### 3.1 Recommended Tooling

For converting Markdown to SharePoint pages while keeping Markdown
authoritative, use one of:

**Option A: PnP PowerShell (recommended for automation)**

```powershell
# Example: publish a single Markdown file to SharePoint
$mdContent = Get-Content -Path "docs/user_guides/PARALLEL_R_DOS_AND_DONTS.md" -Raw
$htmlContent = ConvertFrom-Markdown -Markdown $mdContent
# Use PnP PowerShell to create/update SharePoint page
Add-PnPPage -Name "Safe-Parallel-R" -LayoutType Article
Set-PnPPage -Identity "Safe-Parallel-R" -Content $htmlContent
```

**Option B: Microsoft 365 CLI**

```bash
# Example: upload Markdown and create page
m365 spo page add --webUrl https://unibo.sharepoint.com/sites/BIOME-CALC \
  --name "Safe-Parallel-R.aspx" \
  --title "Safe Parallel R — Do's and Don'ts"
```

**Option C: Manual copy-paste (for small updates)**

1. Open the Markdown file in a Markdown previewer (VS Code, Typora).
2. Copy the rendered HTML.
3. Paste into the SharePoint modern page as a "Markdown" or "Text" web part.
4. Update the source path footer with the current date.

### 3.2 Publication Script (future)

A publication script (`scripts/tools/publish_to_sharepoint.sh`) should:

1. Read `docs/SHAREPOINT_PUBLICATION.md` for the file→section mapping.
2. For each file marked for publication:
   - Extract front matter.
   - Convert Markdown to HTML (using `pandoc` or a Node.js converter).
   - Rewrite internal relative links to SharePoint URLs.
   - Upload images to SharePoint Document Library.
   - Create or update the SharePoint page via PnP PowerShell or M365 CLI.
3. Log which pages were updated and their new versions.

This script is **not yet implemented** — the workflow above is the
design specification.

---

## 4. Maintaining Authoritative Markdown

### 4.1 Edit Flow

1. **Edit the Markdown file** in `docs/` (the authoritative source).
2. **Commit to git** with a descriptive message.
3. **Regenerate the SharePoint page** from the updated Markdown.
4. **Never edit SharePoint pages directly** — changes will be overwritten
   by the next regeneration.

### 4.2 Version Tracking

The `last_verified` field in the front matter and the source path footer
serve as the version marker. When a Markdown file is updated:

1. Update `last_verified` to the current date.
2. Update the footer date.
3. Regenerate the SharePoint page.

### 4.3 Audit Trail

The `docs/DOCUMENTATION_AUDIT.md` register tracks the status of every
documentation file. After each publication cycle, update the register
to reflect which files were published and any issues found.

---

## 5. SharePoint Page Templates

### 5.1 Researcher-Facing Page

```
┌──────────────────────────────────────────────┐
│ [BIOME-CALC Logo]  Researcher Hub            │
├──────────────────────────────────────────────┤
│ Breadcrumb: Home > Researcher Hub > Page     │
├──────────────────────────────────────────────┤
│                                              │
│  # Page Title                                │
│                                              │
│  > **Audience:** botanists / researchers     │
│  > **Last verified:** 2026-06-08             │
│                                              │
│  [Page content — converted from Markdown]    │
│                                              │
├──────────────────────────────────────────────┤
│  *Authoritative source: docs/.../file.md*    │
│  *This page is a published copy.*            │
└──────────────────────────────────────────────┘
```

### 5.2 Sysadmin/Operator Page

```
┌──────────────────────────────────────────────┐
│ [BIOME-CALC Logo]  Operations Hub            │
├──────────────────────────────────────────────┤
│ Breadcrumb: Home > Operations > Page         │
├──────────────────────────────────────────────┤
│                                              │
│  # Page Title                                │
│                                              │
│  > **Audience:** sysadmin / operator         │
│  > **Tier:** T1 (host authoritative)         │
│  > **Last verified:** 2026-06-08             │
│                                              │
│  [Page content — converted from Markdown]    │
│                                              │
├──────────────────────────────────────────────┤
│  *Authoritative source: docs/.../file.md*    │
│  *This page is a published copy.*            │
└──────────────────────────────────────────────┘
```

---

*This guide is hand-maintained. Update as the publication workflow matures.*
