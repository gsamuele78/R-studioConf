# Changelog

All notable repo-wide changes are recorded here. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
R-runtime profile changes have their own log: [`docs/reference/Rprofile_site.CHANGELOG.md`](docs/reference/Rprofile_site.CHANGELOG.md).

## [Unreleased]

### Security

- **Site-local config overlay (PII/secret scrub).** AD topology, third-party PII,
  PI/contact emails, internal IPs and the AD group/OU prefixes were removed from
  all tracked files (T1 `scripts/`,`templates/`,`config/`,`lib/`,`tests/` and the
  T2 `docker-deploy/` mirror). Real values now live in the gitignored
  `config/site/` overlay; the repo ships sanitized `*.example` templates.
  - Added `resolve_site_config` / `assert_site_configured` to `lib/common_utils.sh`
    (fail-fast on the `__FILL_ME__` sentinel; warn routed to stderr).
  - De-tracked 6 config files (`admin_recipients.txt`, `user_email_map.txt`,
    `scopri_progetti_known.conf`, `lib_kerberos_setup.vars.conf`,
    `join_domain_{sssd,samba}.vars.conf`); working copies kept on disk.
  - `setup_nodes.vars.conf` keeps its 6 sensitive keys sanitized, overridden at
    deploy by `config/site/setup_nodes.site.vars.conf`.
  - Externalized the scopri theme→supervisor map (was hardcoded PII) to
    `config/site/scopri_theme_map.conf` (`templates/scopri_progetti.sh.template`
    now reads it; no match → `_UNKNOWN_`).
  - Parameterized `test_rstudio_login.sh` (username/IP via env); removed the
    hardcoded institutional mail domain from `telemetry_api.py` (sender domain now
    from `MAIL_DOMAIN` / `BIOME_MAIL_DOMAIN`) and `ttyd_login_wrapper.sh`
    (`TTYD_DOMAIN_SUFFIX`).
  - Scrubbed real names/IPs/UIDs from `docs/` (incl. consistent role placeholders),
    `.ai/agents.md`, `kubernetes-deploy/env/.env.example`; removed the stray
    `archive/docker-deploy/.env copy` and the pre-scrub archive original; untracked
    `plan/Test/` real-user research code (kept on disk).
  - Verified: full-tree `git grep` for every real token returns nothing in tracked
    files; fresh clone aborts on placeholder; live overlay resolves real values.
  - **Pending (operator):** real values still exist in **git history** until
    `git filter-repo` is run after merge — treat as already-disclosed. Migration
    runbook: [`plan/secret_scrub_site_overlay_plan.md`](plan/secret_scrub_site_overlay_plan.md);
    overlay reference: [`config/SITE_OVERRIDE.md`](config/SITE_OVERRIDE.md).

### Added

- `CHANGELOG.md` (this file) — repo-wide change history.
- `config/SITE_OVERRIDE.md` — site-local overlay reference + first-time/migration steps.
