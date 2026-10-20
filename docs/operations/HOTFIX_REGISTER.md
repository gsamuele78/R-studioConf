<!-- docs/operations/HOTFIX_REGISTER.md -->
# Hotfix register and host deployment ledger

Process: [ADR-0006](../adr/0006-versioned-releases-and-hotfix-register.md).
Update this file in the PR that ships a hotfix, and again when it is applied
on a host or when a host is redeployed.

## In-place hotfixes

"Absorbed in" is the first release whose normal deploy gives the same result,
so the hotfix is not needed on a host deployed from that release or newer.
Until then, redeploying an older release undoes the hotfix.

| Hotfix script | What it fixes | Absorbed in | Applied on | Backup / rollback |
|---|---|---|---|---|
| `scripts/fix_bspm_dbus_inplace.sh` | `install.packages()` through bspm's D-Bus service instead of sudo; removes the root escalation (ADR-0005) | `v2026.10.0` (Step 7 + template section 0) | biome-calc01, 02, 03, 04 on 2026-10-19; calc04 again on 2026-10-20 after the stale-checkout redeploy | `/root/bspm-dbus-hotfix-<ts>/`, `--rollback DIR` |
| `scripts/fix_login_script_rlibs_inplace.sh` | login script stops writing `R_LIBS_USER` into `~/.Renviron` | before `v2026.10.0` | unknown, to check | see script `--help` |
| `scripts/fix_pam_segfault_inplace.sh` | SIGSEGV from `libpam-krb5` / `biome-localguard` PAM profile | before `v2026.10.0` | unknown, to check | see script `--help` |
| `scripts/tools/hotfix_smtp_site_overrides.sh` | deployed `setup_nodes.vars.conf` missing the site SMTP keys | before `v2026.10.0` | unknown, to check | see script `--help` |

Manual changes on the hosts (the two `domain_users` sudo lines commented out on
calc01-04, 2026-10-19) are not scripts, so no release absorbs them; they are
recorded in the ADR-0005 rollout log.

## Host deployment ledger

| Host | Role | Checkout (branch @ commit) | Local modified files | R profile deployed | Last Step 8 deploy |
|---|---|---|---|---|---|
| biome-calc01 | production | `main` @ 6157e27 | 13: site values in 4 `config/*.vars.conf`, mode-only changes on 8 scripts, untracked `rstudio_download_page.html` | v12.11-fix3 (`v2026.10.0`) | 2026-10-20 |
| biome-calc02 | production | `main` @ 6157e27 | 13: same as calc01 | v12.11-fix3 (`v2026.10.0`) | 2026-10-20 |
| biome-calc03 | production | `main` @ 6157e27 | 15: same as calc01, plus untracked `src/biome_core_rust/Cargo.lock` and `target/` (dormant, left alone) | v12.11-fix3 (`v2026.10.0`) | 2026-10-20 |
| biome-calc04 | test | `main` @ 6157e27 | 16: same as calc01, plus untracked `patch.sh`, `scripts/999_postmortem_forensics.sh` and its `.bak` (local files, not in the repo) | v12.11-fix3 (`v2026.10.0`) | 2026-10-20 |

Deploy check used on 2026-10-20 (each host): `grep -c 'not newer than'
/etc/R/Rprofile_site.d/50_pkg_hooks.R` = 1, `grep -c biome_ranger_mtry_guard
/etc/R/Rprofile.site` = 5, `grep -c 'bspm.sudo = FALSE' /etc/R/Rprofile.site` = 2.
Backup before deploy: `/root/etc-R-before-v2026.10.0-<ts>.tgz`.

Check before any redeploy, as ladmin in `/home/ladmin/configServices/R-studioConf`:

```bash
git branch --show-current
git describe --tags --always --dirty
git status --short
```

Since `v2026.10.1`, Step 8 checks this itself and records what it deployed in
`/etc/biome-calc/deployed_release` (one line per deploy in
`deployed_release.history`). To read it: `cat /etc/biome-calc/deployed_release`,
or `sudo ./scripts/50_setup_nodes.sh --verify`.

## Rolling back a release

Step 8 refuses to deploy a checkout older than the deployed commit. To roll back
on purpose, for example after a template problem in production:

```bash
cd /home/ladmin/configServices/R-studioConf
sudo tar czf /root/etc-R-before-rollback-$(date +%s).tgz /etc/R /etc/biome-calc
git fetch --tags
git checkout v2026.10.0            # the release to go back to
sudo ./scripts/50_setup_nodes.sh --allow-downgrade   # option 3
cat /etc/biome-calc/deployed_release   # override=true, previous_commit=<newer>
```

Record the rollback in the ledger above. When the fix is on `main`:
`git checkout main && git pull`, then option 3 without the flag (an upgrade).

Faster alternative for one bad deploy, without git: restore the tarball taken
before the deploy, or the `.bak` files Step 8 leaves (`/etc/R/Renviron.site.bak`,
`/etc/R/Rprofile.site.bak`, `/etc/R/Rprofile_site.d.bak.<epoch>`). The stamp then
still names the newer release; the next Step 8 from the older checkout needs
`--allow-downgrade`, and from the newer one it is a plain redeploy.
