<!-- docs/adr/0008-large-rstudio-sessions-local-state-and-early-warning.md -->
# ADR-0008: Large RStudio sessions: session state on local disk, early warning in R, nightly report

Status: Proposed (design and plan only; nothing implemented or applied yet)
Date: 2026-10-28
Scope: RStudio Server **open source** only. Workbench/Pro features (admin
session-save policy, Launcher, load balancing, session quotas) are out of scope
because the hosts do not have them.

## Context

The 2026-10-28 incident on biome-calc01 ([ADR-0007](0007-os-updates-only-on-a-free-node.md)):
a service restart suspended every session; one researcher's suspended
environment was 765 MB on the NFS home and his next logins hung on "Loading…".
ADR-0007 removes the *unplanned* restart. It does not remove the two other ways a
large environment gets suspended:

- the idle timeout (`session-timeout-minutes`, 10080 on calc01, 2880 in the
  repository), after which RStudio OSS suspends the session (default
  `session-timeout-suspend=1`);
- a planned restart in the maintenance window, or an operator's restart.

What the repository has today (audit, 2026-10-28):

| Area | Current state | Gap |
|---|---|---|
| Where the session state lives | `~/.local/share/rstudio` on NFS (biome-store03). The login script writes `XDG_DATA_HOME` / `XDG_CONFIG_HOME` to `~/.Renviron`, but with `R_PROJECTS_ROOT=/nfs/home` they point to the same NFS paths | Suspend writes and resume reads hundreds of MB over NFS before the IDE appears |
| Where rsession gets its environment | `/etc/rstudio/rsession-profile` (50_setup_nodes.sh) only sets `OPENBLAS_CORETYPE` | `~/.Renviron` is read by R inside rsession, so it is not a reliable place to move rsession's own storage. Upstream report: `XDG_DATA_HOME` worked only when set in the rsession launch wrapper ([OOD forum](https://discourse.openondemand.org/t/rstudio-data-home/2667)) |
| Local scratch disk | `/Rtmp`, 400 GB ext4, mode 1777 | `/etc/tmpfiles.d/biome-rtmp-cleanup.conf` has `q /Rtmp 1777 root root 7d`: anything not touched for 7 days is deleted. Session state placed there unprotected would vanish after a week of inactivity |
| Memory warnings in R | 45_memory_guards warns on single large operations (solve, dist, outer, expand.grid). The `biome_resource_monitor` task callback (50_pkg_hooks) already runs after each top-level command | No warning about the total size of the session, which is what a suspend writes |
| Saving big objects | 70_persistent_tools: `biome_save_session()` / `biome_load_session()` (manual `save.image` to `$HOME`, warns over 1.5 GB). 50_pkg_hooks has a parquet sidecar helper | Researchers do not know when they need them |
| Admin visibility | `99_check_rprofile_health.sh --user` v2.1 warns at 256 MiB of suspended payload, per user, on demand. Mail: `send_email.sh` + `admin_recipients.txt` | No proactive, all-users view |
| Orphan cleanup | `cleanup_r_orphans.sh` acts on processes, not files | None for this ADR |

## Missing information (to collect in the audit phase)

1. Does rsession OSS on our version honour `RSTUDIO_DATA_HOME`, `XDG_DATA_HOME`,
   or both, when set in `/etc/rstudio/rsession-profile`? Only `XDG_DATA_HOME`
   in the launch environment is confirmed by a third party; we verify on calc04.
2. Which of the files under `~/.local/share/rstudio` users rely on across nodes
   (console history, project settings, notebook cache). OSS has no separate
   option for the sessions directory alone, so everything moves together.
3. Do users log in to more than one node? Today a session suspended on calc01
   may be found by the same user on calc02 through the shared home. With local
   state that cross-node resume stops.
4. Can root on the hosts read `/nfs/home/*/.local/share/rstudio` on TrueNAS
   (root squash, NFSv4 ACLs)? This decides whether the nightly report can scan
   the current NFS location or only the new local one.
5. Free space and inode headroom on `/Rtmp` on each host, and the largest
   current suspended payloads (input for thresholds).

## Assumptions

- R package licences: `qs2` (GPL-3), `fst` (AGPL-3), `arrow` (Apache-2.0) are
  acceptable FOSS for a recommendation; we install nothing new in this ADR.
- Session state is a cache, not research data. Losing it (disk failure, host
  reinstall) costs a user their unsaved environment, which is already the case
  for an R crash. Scripts and data stay on NFS.
- A threshold of 2 GiB RSS for the in-session warning, and 256 MiB of
  suspended payload for the report (same as the health check), are starting
  points to tune with the measured distribution.

## Decision

1. **Session state on local disk (point 2).** `/etc/rstudio/rsession-profile`
   exports `XDG_DATA_HOME` (and `RSTUDIO_DATA_HOME` if the audit shows it is
   honoured) to `/Rtmp/.biome-rstudio-state/<user>`, created mode 0700 by the
   profile itself if missing. The tmpfiles rule gets an exclusion line
   `x /Rtmp/.biome-rstudio-state` so the 7-day cleanup never touches it.
   `XDG_CONFIG_HOME` (user preferences, `rstudio-prefs.json`) stays on NFS so
   preferences still follow the user. Controlled by a flag
   `RSTUDIO_STATE_LOCAL=true|false` in `config/`, default `false` until the
   validation passes. Existing NFS state is **not** moved or deleted: a user's
   old suspended session is simply not resumed once the flag is on (announced in
   advance; the old directory stays on NFS for manual recovery).
2. **Early warning in R (point 3).** The existing `biome_resource_monitor`
   callback reads `VmRSS` from `/proc/self/status` at most once a minute. When
   it first crosses `BIOME_SESSION_RSS_WARN_GB` (default 2), it prints one
   English message: the session is large, a restart or idle timeout will write
   it to disk and make the next login slow, and how to save big objects
   (`saveRDS(x, compress = FALSE)`, `qs2::qs_save`, `arrow::write_parquet`)
   and remove them with `rm()`. It warns again only after RSS doubles. It never
   blocks or changes the user's code. This is an Rprofile change, so it ships
   with an `RPROFILE_VERSION` bump and its CHANGELOG section (hard rule 18).
3. **Nightly admin report (point 4).** A read-only script on each host lists
   suspended-session payloads at or above 256 MiB (user, size, age, node) under
   the state location(s) it can read, and mails the list through
   `send_email.sh` to `admin_recipients.txt` only when the list is not empty.
   It runs in the night window after the package sync, with `timeout` and
   `nice`/`ionice`, and never deletes anything.
4. Data-format guidance (qs2/fst/parquet versus `.RData`/`.rds` for big
   objects) goes into the user documentation linked from the warning, not into
   code.

## Consequences

- Suspend and resume of a 765 MB environment run against local ext4 instead
  of NFS; the expected gain is to be measured, not assumed.
- Session state is per node. A user who moves to another node starts a fresh
  session there, and console history no longer follows them.
- A host reinstall or `/Rtmp` loss drops suspended sessions. The health check
  and the report must learn the new location.
- `/Rtmp` gains a permanent directory; its space is counted against the scratch
  disk. The report shows the largest consumers.
- The R warning adds one small file read per minute per active session.
- Rollback: set `RSTUDIO_STATE_LOCAL=false` and redeploy rsession-profile (new
  sessions go back to NFS); disable the warning with its flag; remove the timer.
  None of the steps deletes user data.

## Alternatives considered

- `session-timeout-suspend=0` (OSS option): idle sessions quit instead of
  suspending, so nothing large is written at timeout. It also discards every idle
  user's environment without warning, and does not cover a service restart. A
  policy decision for Jfs, not taken here.
- Shorter `session-timeout-minutes`: fewer stale sessions, but suspends happen
  more often; it does not reduce the size of each suspend.
- Blocking or capping large sessions (cgroup memory limit per user): already
  handled by the existing cgroup policy for OOM; it does not address the
  suspend size and would kill work.
- Workbench session-save policy: not available in OSS.

## Plan

### 1. Audit / assessment (read-only, calc04, then a read-only pass on calc01-03)

| Step | Command / method | Output |
|---|---|---|
| rsession version and options | `rstudio-server version`; `/usr/lib/rstudio-server/bin/rsession --help \| grep -i -E 'suspend\|timeout'` | Confirms OSS option names |
| Env var support | Test user on calc04: set `XDG_DATA_HOME` (then `RSTUDIO_DATA_HOME` alone) in rsession-profile, log in, check where `sessions/active` is created | Missing info 1 answered |
| Current payloads | `sudo find /nfs/home/*/.local/share/rstudio/sessions/active -path '*suspended-session-data*' -type f -size +100M -printf '%s %p\n'` (with `timeout`), per host | Distribution, missing info 4 and 5 |
| `/Rtmp` headroom | `df -h /Rtmp; df -i /Rtmp` per host | Missing info 5 |
| Cross-node use | `last`/rserver logs per user across hosts, 14 days | Missing info 3 |

### 2. Development / implementation (small PRs, each with tests and docs)

1. PR A: rsession-profile export behind `RSTUDIO_STATE_LOCAL` + tmpfiles `x`
   line + in-place hotfix script (idempotent, `--dry-run`, backup of the old
   files, rollback) + health check and forensics script aware of the new path.
2. PR B: RSS warning in the resource-monitor callback, flag and threshold in
   config, `RPROFILE_VERSION` bump, CHANGELOG, user doc page on big objects.
3. PR C: nightly report script + systemd timer template + mail, test with
   stubbed `find`/`send_email.sh`.

Order: B and C can go first (no change to where data lives); A last, after the
baseline.

### 3. Testing / validation (calc04 first, metrics before and after)

| Metric | How | Pass criterion |
|---|---|---|
| Suspend time, 765 MB env | Synthetic session (`x <- runif(1e8)`, ~763 MB); `rstudio-server suspend-session <pid>`; time until rsession exits. 3 runs, median, NFS vs local | Recorded; local not slower |
| Resume time to usable console | Same session, login with browser devtools open; time from login POST to console prompt. 3 runs, median | Recorded; target at least 2x faster local |
| tmpfiles safety | `touch -d '10 days ago'` a file in the state dir; `systemd-tmpfiles --clean`; file still there. Same in plain `/Rtmp`: removed | Both hold |
| Permissions | Second test user cannot list another user's state dir | Permission denied |
| Warning | R session allocating 3 GB prints one English warning; allocating 6 GB prints the second; under 2 GB nothing; command timing overhead below 1 ms per prompt | All hold |
| Report | Fixture with one 300 MB and one 10 MB payload: mail contains only the first; empty case sends no mail | Holds |
| Rollback | Flag off, redeploy, new session back on NFS; old local dir untouched | Holds |

Only after calc04 passes for one week: calc01-03, one host at a time, with a
note to users in advance.
