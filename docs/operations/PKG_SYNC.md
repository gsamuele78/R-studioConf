<!-- docs/operations/PKG_SYNC.md -->
# Nightly R package sync across hosts

Decision: [ADR-0004](../adr/0004-replicated-local-r-libraries.md) step 4.
Script: `scripts/biome_pkg_sync.sh`. Settings: `config/pkg_sync.vars.conf`, with site
values in `config/site/pkg_sync.site.vars.conf` (gitignored).

Every night each host publishes the list of its `r-cran-*` packages to a shared
directory on biome-store03. When no R session is running, it installs the packages
the other hosts have and it lacks, after aligning the versions of what it has. It
never removes a package and never changes R itself.

## What it does, per timer slot (every 15 minutes, 03:00 … 04:45)

| Time | Action |
|---|---|
| any slot | write `hosts/<host>.json` (manifest) |
| 03:00, 03:15 | manifest only, so every host has published before any host reads |
| 03:30 – 04:45 | once per night: plan, then (mode `apply`) align versions + install missing |
| sessions running | exit 75 ("deferred"), the next slot retries (log: `retry at HH:MM`) |
| still busy at 04:45 | exit 75, log `last slot tonight, the sync moves to the next night` |
| after 05:00 | nothing starts; the next night runs (a missed night is not caught up) |

The window is in `config/pkg_sync.vars.conf` (`PKG_SYNC_WINDOW_START=0300`,
`PKG_SYNC_APPLY_FROM=0330`, `PKG_SYNC_WINDOW_END=0500`). A run started at 04:45
can end after 05:00; at most 50 binary installs keep it short.

Refusals (exit 3, host unchanged): R not at the pinned version
(`config/pin_r_version.vars.conf`), a plan that removes packages, touches
`r-base*`/`r-recommended`, or upgrades a package without a saved `.deb`.

## One-time setup

Whoever can write the shared directory decides what every host installs (from the
configured apt repositories only). So root on the four hosts writes it, and nobody
else does.

1. **On biome-store03, as root**: create a directory used only for this and
   export it to the four hosts only. Replace the path and the addresses with the
   real ones.

   ```bash
   install -d -o root -g root -m 0755 /srv/biome-pkg-sync
   install -d -o root -g root -m 0755 /srv/biome-pkg-sync/hosts /srv/biome-pkg-sync/reports
   # /etc/exports: root of the hosts stays root on this export only
   echo '/srv/biome-pkg-sync <calc01-ip>(rw,sync,no_subtree_check,no_root_squash) <calc02-ip>(rw,sync,no_subtree_check,no_root_squash) <calc03-ip>(rw,sync,no_subtree_check,no_root_squash) <calc04-ip>(rw,sync,no_subtree_check,no_root_squash)' >> /etc/exports
   exportfs -ra && exportfs -v | grep biome-pkg-sync
   ```

   If `no_root_squash` is not acceptable, use `all_squash,anonuid=<uid>,anongid=<gid>`
   with a dedicated account that owns the directory (`0755`): only these four
   hosts can reach the export, and on them only root runs the job.
2. **On every host, as root**: mount it at the same path.

   ```bash
   install -d -m 0755 /mnt/biome-pkg-sync
   echo 'biome-store03:/srv/biome-pkg-sync /mnt/biome-pkg-sync nfs defaults,_netdev,nofail,hard,timeo=600 0 0' >> /etc/fstab
   mount /mnt/biome-pkg-sync
   ```

3. **Site config** on every host, in `config/site/pkg_sync.site.vars.conf`:

   ```bash
   PKG_SYNC_DIR="/mnt/biome-pkg-sync"
   PKG_SYNC_MODE="dry-run"
   ```

4. **Check access from every host** (calc01, calc02, calc03, calc04):
   `sudo bash scripts/biome_pkg_sync.sh --check-dir`. It checks that the
   directory is an NFS mount, that root can write it, that it is not writable by
   group/others, and that user `nobody` cannot write it. Then it publishes the
   host's manifest and lists the hosts that reached the directory: after the
   fourth host the list must show all four. Exit 1 means fix the export first.
5. **Timer**: `sudo bash scripts/biome_pkg_sync.sh --install-timer`, then
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
