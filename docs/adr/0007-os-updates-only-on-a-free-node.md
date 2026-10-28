<!-- docs/adr/0007-os-updates-only-on-a-free-node.md -->
# ADR-0007: OS updates and rstudio-server restarts only in the night window, on a free node

Status: Proposed (PR; not applied on any host yet)
Date: 2026-10-28

## Context

On biome-calc01, 2026-10-28:

- 06:26:25 the stock `apt-daily-upgrade.timer` (Ubuntu: 06:00 plus up to 60 min
  random delay) ran unattended-upgrades, which upgraded `libbrotli1`.
- 06:26:34 needrestart restarted `rstudio-server` because rserver had the old
  library mapped. The journal shows a 140.8 GB memory peak for the service.
- Stopping rstudio-server suspends every RStudio session. Suspending writes the
  session's whole R environment to
  `~/.local/share/rstudio/sessions/active/<id>/suspended-session-data/environment`
  on the NFS home (biome-store03), and the next login reads it back before the IDE
  loads.
- One researcher's environment was 765 MB. From 09:02 his logins hung on
  "Loading…". He pressed Terminate, the session resumed again, and the journal
  logged "The previous R session terminated abnormally" four times.

The repository disables only `~/.RData` save and restore (`load_workspace=false`,
`save_workspace="never"`, `session-save-action-default=no`). Those settings do not
cover suspension: rsession always serialises the environment when it is suspended.
Before this ADR the repository had no rule for needrestart or for the upgrade
timer. The same restart can happen on every host on any morning a library used by
rserver is updated.

The R package sync (`biome_pkg_sync.sh`, ADR-0004) already changes packages only
in 03:30-05:00 and only with no `rsession` and no `R` process.

## Decision

1. needrestart never restarts rstudio-server:
   `/etc/needrestart/conf.d/biome-rstudio.conf` sets
   `$nrconf{override_rc}{qr(^rstudio-server)} = 0`. Other services are still
   restarted as before. The rule also applies to an operator's manual `apt upgrade`.
2. `apt-daily-upgrade.timer` is disabled and replaced by
   `biome-node-maintenance.timer`, which runs every 15 minutes in the night window
   (default 03:30-05:00, the same as the package sync). `apt-daily.timer`, which
   refreshes the package lists, is kept.
3. Each slot runs `scripts/biome_node_maintenance.sh` with the same "node is
   free" test as the package sync: no `rsession` and no `R` process. It also
   defers while the package sync holds its lock or another apt/dpkg frontend runs.
   A deferred run exits 75 and the next slot retries; after the last slot the work
   moves to the next night. Nothing is killed.
4. After `unattended-upgrade`, if `needrestart -b` lists rstudio-server and the node
   is *still* free, the script restarts it. If someone logged in during the
   upgrade, the restart waits for the next slot. A pending kernel reboot is only
   reported.
5. After `MAINT_OVERDUE_NIGHTS` (default 3) nights in a row without a free slot,
   each deferred run logs a journal warning (`biome-node-maintenance`, priority
   warning) and the report says `overdue`.
6. The host's own apt policy is respected: with
   `APT::Periodic::Unattended-Upgrade "0"` nothing is upgraded.

Locks are local to each node. The package sync reads the other hosts' manifests
but never waits for them, so a busy node does not block the others.

## Consequences

- Researchers' sessions are no longer suspended in working hours by an automatic
  upgrade.
- **Security updates can be late.** A node with a long-running R job, or with
  idle sessions kept alive by `session-timeout-minutes` (10080 = 7 days on
  calc01, 2880 in `config/configure_rstudio.vars.conf`: drift), is never free.
  The overdue warning makes this visible, and the operator decides (for example,
  a manual `--force-window` run after warning the users). Making the timeout the
  same on the hosts and in the repository is a separate decision.
- Between the upgrade and the restart, rserver runs with the old library in memory.
  The restart happens at the first free slot.
- An R process in tmux or ssh counts as "busy", as in the package sync. This is
  deliberately conservative.
- Rollback: `biome_node_maintenance.sh --remove-timer` removes the units and the
  needrestart fragment, and puts `apt-daily-upgrade.timer` back in its saved state.

## Alternatives considered

- Only the needrestart exclusion: stops the restart, but upgrades still run at
  06:xx, and nothing ever restarts rserver onto the patched library.
- systemd drop-ins on `apt-daily-upgrade` (new `OnCalendar` + `ExecCondition`
  running the same check): this would work for the gate, because
  apt.systemd.daily's stamp compares calendar days. It was not chosen because the
  deferred rstudio-server restart, the overdue streak and the report still need a
  script. Two mechanisms (drop-ins on a stock unit, plus a script) are harder to
  audit and to roll back than one unit of our own.
- `session-timeout-suspend=0` (quit instead of suspend after the timeout): does
  not affect a service stop, and would drop idle users' environments. This is a
  separate policy decision, not taken here.
