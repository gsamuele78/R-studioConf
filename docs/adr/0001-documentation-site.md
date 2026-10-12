<!-- docs/adr/0001-documentation-site.md -->
# ADR-0001: Documentation site — docs-as-code with MkDocs, no GitHub Wiki

Status: Proposed
Date: 2026-10-12

## Context

- `docs/` holds about 60 Markdown files (researcher guides, operator runbooks,
  developer references, architecture) indexed by role in
  [`docs/README.md`](../README.md). Markdown in git is already declared the
  single source of truth ([`SHAREPOINT_PUBLICATION.md`](../SHAREPOINT_PUBLICATION.md)).
- Researchers already receive their documentation through the institutional
  SharePoint wiki: four docx guides generated from `docs/` by
  `scripts/tools/build_wiki_docx.sh`. That channel is behind university
  login, which matters because some operator documents contain internal
  details (the "Internal / Not for SharePoint" list).
- Nothing checks the documentation in CI today. `make audit` checks only the
  Rprofile changelog (HC-14). Broken links between pages, broken `#anchors`
  and links to renamed scripts reach `main` unnoticed. Project rule: every PR
  that changes behaviour updates the docs, so the docs need a gate like code.
- The repository is **public**. The GitHub Wiki is enabled but empty.
- Sibling repos (read-only reference): `Proxmox_biome_log_collector` and
  `AI-Platform-Infrastructure` keep docs as Markdown in `docs/` with ADRs in
  `docs/adr/`; `Proxmox_biome_log_collector` and `Infra-Iam-PKI` gate Markdown
  with `markdownlint-cli2` in CI. None of them publishes a site or uses the
  GitHub Wiki. The ADR template here is taken from
  `Proxmox_biome_log_collector/docs/adr/0000-template.md`.
- Tooling landscape as of 2026-10 (checked, not assumed):
  - MkDocs 1.6.1 is the last 1.x release. MkDocs 2.0 is a ground-up rewrite
    announced as backward-incompatible (plugin system removed) and, per the
    Material team's analysis of 2026-02-18, currently without a licence.
  - Material for MkDocs (MIT) 9.7.6 is in maintenance mode since early 2026:
    security and critical fixes for at least 12 months, no new features.
  - Its successor, Zensical (MIT, same team), reads `mkdocs.yml` but is at
    0.0.x — too young for a production dependency today.

## Decision

Render `docs/` as a static site with **MkDocs 1.6.1 + Material for MkDocs
9.7.6, pinned**, built in **strict mode in CI on every PR that touches docs**,
and do **not** use the GitHub Wiki. Publication to GitHub Pages is
implemented but **off by default**; turning it on is a separate maintainer
decision (see Publication).

Implementation (this PR):

- `mkdocs.yml` at repo root, `docs_dir: docs`, no third-party plugins (keeps
  the config portable to Zensical). `docs/` is not restructured: `README.md`
  becomes the site home page, existing relative links keep working on
  GitHub, in the docx build and on the site.
- `scripts/tools/docs_site/mkdocs_hooks.py`: links from `docs/` to repo files
  outside `docs/` (CHANGELOG, `config/`, `scripts/`) are rewritten to GitHub
  URLs at build time, only if the target exists. Everything else is
  validated by MkDocs.
- Heading ids use a GitHub-compatible slug, so `#anchors` written for GitHub
  resolve on the site too (without it, a valid GitHub anchor in
  `archiver/BIOME_Admin_Guide.md` was rejected as broken).
- `theme.font: false`: no Google Fonts, per HC-11 (no external font/CSS CDN).
- `.github/workflows/docs.yml`: job `build` installs the pinned toolchain
  (`scripts/tools/docs_site/requirements.txt`), runs
  `tests/docs_site_test.sh` (real tree + negative controls: broken page link,
  broken anchor, missing outside file must each fail), builds strict and
  uploads the rendered site as a run artifact for preview.

### Publication

Job `deploy` publishes to GitHub Pages only when **both** are true:
repository variable `DOCS_PAGES_ENABLED=true` and Pages source set to
"GitHub Actions" in repo settings. Neither is set by this PR.

Before turning it on, the maintainer decides the audience:

- The repo is public, so the Markdown is already readable by anyone. A Pages
  site does not add new information but makes it **searchable and
  indexed**, including operator internals listed as "not for SharePoint".
- Default recommendation: keep SharePoint as the researcher channel; if Pages
  is enabled, publish it as the operator/developer reference and exclude the
  internal list via `exclude_docs`, or keep the site as a CI gate plus
  downloadable preview only.

## Consequences

Positive:

- Docs get a real CI gate: broken internal links and anchors fail the PR,
  which makes the "every PR updates the docs" rule enforceable.
- One source (Markdown) feeds three outputs: GitHub view, docx for
  SharePoint, HTML site. No content duplication.
- Search, navigation and dark mode for operators, if Pages is enabled.

Negative / accepted:

- **Toolchain on borrowed time.** MkDocs 1.x is frozen and Material is in
  maintenance mode. We pin exact versions, accept that, and plan the exit:
  re-evaluate Zensical when it reaches 1.0, or when Material's security
  window closes (about early 2027), whichever comes first. Because the
  config uses no plugins, the migration is expected to be small; that is an
  expectation, not a tested fact.
- Material prints a notice about MkDocs 2.0 on every build; CI silences it
  with `NO_MKDOCS_2_WARNING`, since it is acknowledged here.
- Material's JavaScript bundle can fetch a polyfill or Mermaid from
  `unpkg.com` only on very old browsers or Mermaid diagrams; neither is used
  today. Material's built-in `privacy` plugin can self-host these if needed.
- Links from docs to files outside `docs/` point at `main` on GitHub, not at
  the commit that built the site.
- The site navigation is generated from the folder tree; a curated `nav:`
  is possible later, but every new file must then also be added there.
- One more workflow (about a minute of CI) on docs PRs.

## Alternatives considered

- **GitHub Wiki** — rejected. It is a separate git repo edited in the browser,
  outside PR review and CI, so docs would drift from code (the exact problem
  to solve). It cannot be scoped to an audience on a public repo. Recommend
  disabling it in repo settings so there is no second, unreviewed source.
- **Read the Docs (hosted)** — rejected. Adds an external service and account;
  the free community tier shows ads; nothing it offers is needed beyond what
  GitHub Actions + Pages give.
- **Sphinx + MyST (BSD)** — viable and long-term stable, but heavier
  configuration for a pure-Markdown tree and a second syntax (MyST
  directives) for authors. Kept as the fallback if both MkDocs 1.x and
  Zensical become untenable.
- **Zensical now** — rejected for now: 0.0.x on a production project's CI.
- **mdBook (MPL-2.0)** — requires a hand-maintained `SUMMARY.md` for 60+ files
  and has weaker anchor validation.
- **markdownlint only (as in sibling repos)** — useful, but it checks style,
  not whether links resolve. Complementary; can be added later.
- **Status quo (SharePoint docx only)** — leaves the docs without any CI gate.

## Rollback

Delete `mkdocs.yml`, `scripts/tools/docs_site/`, `tests/docs_site_test.sh`
and `.github/workflows/docs.yml`. No content under `docs/` depends on the
site. If Pages was enabled: set `DOCS_PAGES_ENABLED` to false (or delete it)
and unpublish the site in Settings → Pages.
