<!-- docs/operations/NODE_MAINTENANCE.md -->
# OS updates on a free node (runbook)

Decision and rationale: [ADR-0007](../adr/0007-os-updates-only-on-a-free-node.md).
Script: `scripts/biome_node_maintenance.sh`. Settings:
`config/node_maintenance.vars.conf`, with site overrides in
`config/site/node_maintenance.site.vars.conf`.

## What it changes

| Before | After |
|---|---|
| `apt-daily-upgrade.timer` runs unattended-upgrades at 06:00 + up to 60 min random | disabled; `biome-node-maintenance.timer` runs every 15 min, work only 03:30-05:00 |
| needrestart restarts `rstudio-server` after a library upgrade, which suspends every session | `/etc/needrestart/conf.d/biome-rstudio.conf` excludes it; the script restarts it only on a free node |
| no link with the R package sync | defers while `biome_pkg_sync.sh` holds `/run/lock/biome-pkg-sync.lock` |

"Free" means the same as for the package sync: no `rsession` process and no `R`
process (`pgrep -x`). An R job in tmux or ssh keeps the node busy.

## Install on a host (in-place, idempotent)

Test host first (calc04), then the production hosts one at a time. As ladmin in
`/home/ladmin/configServices/R-studioConf`, on `main`, with an empty
`git status --short templates/`:

```bash
sudo bash scripts/biome_node_maintenance.sh --plan            # read-only: window, sessions, sync, apt, needrestart
sudo bash scripts/biome_node_maintenance.sh --install-timer
systemctl list-timers biome-node-maintenance.timer apt-daily-upgrade.timer
sudo needrestart -b | grep -c rstudio-server                   # whatever it says, it no longer restarts it
```

Check the next morning:

```bash
bash scripts/biome_node_maintenance.sh --status
journalctl -u biome-node-maintenance --since yesterday --no-pager | grep result:
journalctl -u rstudio-server --since yesterday --no-pager | grep -E "Stopping|Started"   # only inside 03:30-05:00
```

## Rollback

```bash
sudo bash scripts/biome_node_maintenance.sh --remove-timer
```

This removes the timer, the service and the needrestart fragment, and puts
`apt-daily-upgrade.timer` back in the state saved at install time. Reports in
`/var/lib/biome-node-maintenance/` are kept.

## Run results (`result:` line, `last_report.json`)

| status | exit | meaning |
|---|---|---|
| `done` | 0 | upgraded; `rstudio_restart` says whether rserver was restarted |
| `skipped` | 0 | `APT::Periodic::Unattended-Upgrade "0"` on this host |
| `deferred` | 75 | sessions / package sync / apt busy, or a restart pending; next slot retries |
| `overdue` | 75 | deferred for `MAINT_OVERDUE_NIGHTS`+ nights; also a journal warning |
| `failed` | 1 | unattended-upgrade or the rserver restart failed; see `/var/log/unattended-upgrades/` |

If the status is `overdue`, find who keeps the node busy
(`ps -eo user,etime,args | grep -E '[r]session|/[R] '`), warn them, then run once
under supervision: `sudo bash scripts/biome_node_maintenance.sh --force-window`.
This ignores the window and the done-marker, but **not** the session check.

A pending kernel (`needrestart_kernel_status` 3) is only reported. Reboot by hand
in a maintenance slot.

## Known limits

- With `session-timeout-minutes=10080` (calc01, 2026-10-28) an idle browser tab
  keeps an rsession alive for up to 7 days, so a node can stay "busy" for a long
  time. The repository value is 2880; aligning the hosts is open.
- A session that the server does suspend (idle timeout) still writes its
  environment to NFS. `99_check_rprofile_health.sh --user` warns at 256 MiB, and
  `--reset-profile --commit` is the reversible fix
  ([DIAGNOSTICS_INDEX](DIAGNOSTICS_INDEX.md)).
