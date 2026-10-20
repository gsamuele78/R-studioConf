<!-- docs/operations/PKG_SYNC.md -->
# Nightly R package sync across hosts

Decision: [ADR-0004](../adr/0004-replicated-local-r-libraries.md) step 4.
Script: `scripts/biome_pkg_sync.sh`. Settings: `config/pkg_sync.vars.conf`, with site
values in `config/site/pkg_sync.site.vars.conf` (gitignored).

Every night each host publishes the list of its `r-cran-*` packages to a shared
directory on biome-store03. When no R session is running, it installs the packages
the other hosts have and it lacks, after aligning the versions of what it has. It
never removes a package and never changes R itself.

## What it does, per timer slot (01:00, 01:30 … 04:30)

| Time | Action |
|---|---|
| any slot | write `hosts/<host>.json` (manifest) |
| 01:00 | manifest only, so every host has published before any host reads |
| 01:30 – 04:30 | once per night: plan, then (mode `apply`) align versions + install missing |
| sessions running | exit 75 ("deferred"), the next slot retries |
| after 05:00 | nothing starts; the next night runs (a missed night is not caught up) |

Refusals (exit 3, host unchanged): R not at the pinned version
(`config/pin_r_version.vars.conf`), a plan that removes packages, touches
`r-base*`/`r-recommended`, or upgrades a package without a saved `.deb`.

## One-time setup

1. **Shared directory on biome-store03.** Create a directory used only for this,
   for example `/mnt/zpool/biome-pkg-sync`, and export it to the four calc hosts
   so that **root on the hosts can write it** and nobody else can:
   - either `no_root_squash` on this export only, restricted to the hosts' IPs;
   - or `all_squash,anonuid=<uid>,anongid=<gid>` with the directory owned `0755`
     by that dedicated account.

   Researchers must not be able to write it: whoever can write a manifest decides
   what every host installs (from the configured apt repositories only).
2. **Mount it** on every host at the same path (fstab, `_netdev`).
3. **Site config** on every host, in `config/site/pkg_sync.site.vars.conf`:

   ```bash
   PKG_SYNC_DIR="/mnt/biome-pkg-sync"
   PKG_SYNC_MODE="dry-run"
   ```

4. **Timer**: `sudo bash scripts/biome_pkg_sync.sh --install-timer`, then
   `systemctl list-timers biome-pkg-sync.timer`.

## Rollout

1. All four hosts in `dry-run` for at least two nights. Check each morning:
   `bash scripts/biome_pkg_sync.sh --status` and
   `journalctl -u biome-pkg-sync --since yesterday`.
2. calc03 must be on the pinned R first; until then it is refused (it still
   publishes its manifest).
3. calc04 to `apply`. Next morning: `--status`, then a researcher test on calc04.
4. calc01-03 to `apply`, one per night.

Metric: `--status` prints packages that differ in version, the sum of missing
packages and the number of R versions. Target 0 / 0 / 1. Baseline 2026-10-15
(`99_check_pkg_host_drift.sh`): 426 of 690 packages drift.

## Manual run and rollback

```bash
sudo bash scripts/biome_pkg_sync.sh --plan                 # publish + plan, no change
sudo bash scripts/biome_pkg_sync.sh --force-window         # one run now (mode from config)
sudo bash scripts/biome_pkg_sync.sh --rollback /var/backups/biome-calc/r-pkg-sync-<ts>
sudo bash scripts/fix_r_pkg_versions_inplace.sh --rollback /var/backups/biome-calc/r-pkg-align-<ts>
sudo bash scripts/biome_pkg_sync.sh --remove-timer         # stop the job
```

`--rollback` removes exactly what that run installed and refuses if apt would also
remove anything else. Version alignment has its own backup, named in the run's
`align_backup` file.

## Excluding a package

`<PKG_SYNC_DIR>/policy.json`:

```json
{"exclude": ["r-cran-somepkg"]}
```

## Files

| Path | Content |
|---|---|
| `<PKG_SYNC_DIR>/hosts/<host>.json` | manifest: `r-cran-*` with versions, R version, packages apt does not manage |
| `<PKG_SYNC_DIR>/reports/<host>.json` | last run: status, note, what it installed or planned, packages not in apt |
| `/var/lib/biome-pkg-sync/` | `last_report.json`, `done_date` |
| `/var/backups/biome-calc/r-pkg-sync-<ts>/` | `before.tsv`, `after.tsv`, `new.tsv`, `install.log`, `align.log` |
