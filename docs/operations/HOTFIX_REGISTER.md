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
| biome-calc01 | production | `main` @ 3df2720 (PR #38) | 12: 4 config files with site values, 8 scripts with mode-only changes | v12.11 + bspm hotfix | unknown, before 2026-10-20 |
| biome-calc02 | production | `main` @ 3df2720 (PR #38) | 12: same as calc01 | v12.11 + bspm hotfix | unknown, before 2026-10-20 |
| biome-calc03 | production | `main` @ 3df2720 (PR #38) | 12: same as calc01; also untracked `src/biome_core_rust/target/` (dormant, left alone) | v12.11 + bspm hotfix | unknown, before 2026-10-20 |
| biome-calc04 | test | `claude/project-thread-nb902e` @ e727888 (PR #41, the `v2026.10.0` content) | 12: config values, file modes | v12.11-fix3 | 2026-10-20 |

Check before any redeploy, as ladmin in `/home/ladmin/configServices/R-studioConf`:

```bash
git branch --show-current
git describe --tags --always --dirty
git status --short
```
