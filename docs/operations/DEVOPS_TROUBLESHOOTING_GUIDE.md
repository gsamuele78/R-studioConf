<!-- docs/operations/DEVOPS_TROUBLESHOOTING_GUIDE.md -->
---
title: "BIOME-CALC DevOps Troubleshooting Guide"
audience: operator
status: current
tier: T1
source_path: docs/operations/DEVOPS_TROUBLESHOOTING_GUIDE.md
last_verified: 2026-10-28
---

# DevOps Troubleshooting Guide

This guide is the **method** layer on top of the per-symptom runbook. Use it when you do not yet know which layer is broken, when you need the reference values to judge an output, or when you want a worked example of a full investigation.

| Need | Document |
|---|---|
| How to approach an incident, values to judge outputs, worked example | this guide |
| Symptom → diagnosis → fix → verification for a known problem | [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) |
| Flags, safety class and exit codes of every diagnostic script | [`DIAGNOSTICS_INDEX.md`](DIAGNOSTICS_INDEX.md) |
| Where each log lives | [`diagnostic_logs.md`](diagnostic_logs.md) |
| An unchanged user R script fails | [`USER_SCRIPT_TROUBLESHOOTING.md`](USER_SCRIPT_TROUBLESHOOTING.md) |

All commands run on the T1 host from the source checkout (`/home/ladmin/configServices/R-studioConf` on the production nodes) unless stated otherwise. Only open-source RStudio Server features apply; Posit Workbench options do not exist on these hosts.

## 1. Ground rules

1. **Read-only first.** Every first-round command in this guide is read-only. Change nothing until the cause is written down.
2. **Read NFS homes as the user.** Homes are on TrueNAS over NFSv4.2 (`sec=sys`); root may be squashed. Use `sudo -u <user> ...` for `ls`, `du`, `find`, `mv` inside `/nfs/home/<user>`. Running them as root can fail or give partial results.
3. **Know which processes are the user's work.** A user can have an `rsession` (the IDE) *and* R processes in `tmux`/`ssh`/Background Jobs. Stop only the process you have identified as the problem. List first: `ps -u <user> -o pid,ppid,stat,etime,rss,args`.
4. **Move, never delete.** User state goes into a dated backup or the `--reset-profile` quarantine, so every step can be undone.
5. **One change, then verify.** Re-run the same diagnostic after each change and compare with the value before.
6. **Find the trigger, not just the victim.** A stuck user is usually the symptom of a host event (restart, upgrade, NFS outage). Look for the host event before closing the incident.
7. **Record the evidence.** Keep the outputs (sanitized: no usernames, IPs, ACL principals in public places) for the incident note and the changelog.

## 2. Triage: "a user cannot use RStudio"

Walk the layers top-down. Stop at the first layer that is not healthy and open the matching runbook section.

| # | Layer | Question | Command (read-only) | Healthy | Not healthy → |
|---|---|---|---|---|---|
| 1 | Identity | Does the account resolve? | `getent passwd <user>; id <user>` | uid/gid printed | [Runbook §3.1](TROUBLESHOOTING.md#31-ad-user-no-longer-resolves-or-authenticates) |
| 2 | Authentication | Did PAM/winbind accept the login? | `sudo journalctl -u rstudio-server --since '-1 hour' --no-pager \| grep -i <user>`; `sudo grep -i <user> /var/log/auth.log \| tail` | `granted access` / `session opened` | [Runbook §2](TROUBLESHOOTING.md#2-pam-and-password-operations), §3 |
| 3 | Home storage | Is the home mounted, writable, under quota? | `findmnt -T /nfs/home/<user>`; `sudo bash scripts/99_troubleshoot_env.sh --storage --test-user <user>` | nfs4 mount, 1 MiB+fsync write OK | [Runbook §4.2](TROUBLESHOOTING.md#42-nfs-home-is-unavailable-stale-or-slow), [§4.4](TROUBLESHOOTING.md#44-writes-to--fail-with-disk-quota-exceeded-but-df-shows-free-space) |
| 4 | rsession process | Is there an `rsession`, and what is it doing? | `pgrep -u <user> -a rsession`; `ps -o pid,etime,stat,%cpu,rss -p <pid>` | none (fresh login) or `S`, low CPU | §4 of this guide |
| 5 | Session state | Is RStudio trying to resume a large/corrupt suspended session? | `sudo bash scripts/99_check_rprofile_health.sh --user <user>` (section 7); `sudo -u <user> du -sh /nfs/home/<user>/.local/share/rstudio/sessions/active/*/` | small state, no suspended payload | [Runbook §1.8](TROUBLESHOOTING.md#18-rstudio-stays-on-loading-after-a-suspended-session) |
| 6 | R profile | Does the system/user R startup load cleanly? | same health check, sections 1–9 | `VERDICT` clear | [Runbook §1.1](TROUBLESHOOTING.md#11-rstudio-login-loops-or-session-failed-to-start), [§8.1](TROUBLESHOOTING.md#81-welcome-bannerguardstools-are-missing) |
| 7 | Crash history | Did the session crash (OOM, SIGSEGV) rather than hang? | `sudo bash scripts/99_postmortem_forensics.sh --user <user> --hours 72 --output /tmp/pm_<user>.txt` | no OOM/signal entries | [Runbook §1.2](TROUBLESHOOTING.md#12-r-session-exits-with-sigsegv-during-matrix-work), [§1.3](TROUBLESHOOTING.md#13-r-session-is-oom-killed-or-exits-137) |
| 8 | Host event | What happened on the host at the time the problem started? | §5 of this guide | no service stop, no NFS errors | §5 |

Ask the user for the exact symptom: login rejected (layers 1–2), "Loading…" forever or a Terminate/Reload loop (layers 4–5), "R session aborted" (layer 7), or a new empty session where they expected the old one (normal after the idle timeout).

## 3. Reference values

Use these to judge what a command prints. "Source" says where the number comes from, so you can check it has not changed.

### 3.1 RStudio session

| Item | Value | Source / meaning |
|---|---|---|
| Idle timeout before suspend, repo | `2880` min (2 days) | `RSESSION_TIMEOUT_MINUTES` in `config/configure_rstudio.vars.conf` |
| Idle timeout, live hosts | `10080` min (7 days) | `/etc/rstudio/rsession.conf` on biome-calc01, 2026-10-28. **Drift from the repo**, not yet aligned |
| rsession built-in default | `120` min | `rsession --help` (`--session-timeout-minutes`) |
| Nginx proxy timeout | same as the session timeout | `proxy_read_timeout %%RSESSION_TIMEOUT_SECONDS%%` in `templates/nginx_proxy_location.conf.template`; a slow resume is not cut by the proxy |
| Suspend on idle | on (`--session-timeout-suspend=1`, default) | when the timeout expires, the R environment is written to disk |
| Suspend on `rstudio-server` stop/restart | always | every live session is suspended, whatever its size |
| Where the suspended environment goes | `~/.local/share/rstudio/sessions/active/session-*/suspended-session-data/environment` | on NFS: written at suspend, read back at the next login |
| `~/.RData` save/restore | off | `load_workspace=false`, `save_workspace=never`, `session-save-action-default=no`. This does **not** cover suspend |

### 3.2 Thresholds used by the tools

| Tool / check | Value | Level |
|---|---|---|
| `99_check_rprofile_health.sh` §7, RStudio state total | ≥ 1 GiB | WARN |
| `99_check_rprofile_health.sh` §7, single suspended payload | ≥ 256 MiB | WARN — health 2.1, [PR #53](https://github.com/gsamuele78/R-studioConf/pull/53) (open); health 2.0 on main does not check it |
| `99_check_rprofile_health.sh` §7, `~/.RData` restored at login (`load_workspace=true`) | any size / ≥ 1 GiB | WARN / FAIL |
| `99_check_rprofile_health.sh` §7, user session start | > 5 s and > 2 s over the system baseline / > 30 s | WARN / FAIL |
| `99_check_rprofile_health.sh` §9, system profile load | > 2 s "moderate" / > 5 s "slow" | WARN (a fresh bundle usually brings it under 1 s) |
| `99_postmortem_forensics.sh` §4, any file in a session dir | > 50 MB | HIGH |
| `99_postmortem_forensics.sh` §1, RAM used | > 75% / > 90% | HIGH / CRITICAL |
| `99_postmortem_forensics.sh` §8, orphan R processes | > 4 GB RSS total | HIGH |
| User slice (cgroup) | `MemoryHigh=300G`, `MemoryMax=400G`, `MemorySwapMax=4G`, `TasksMax=4096` | `config/setup_nodes.vars.conf` |

### 3.3 Reading a live `rsession`

`ps -o pid,etime,stat,%cpu,rss -p <pid>`:

| `STAT` / `%CPU` | Meaning | Action |
|---|---|---|
| `R` or `D`, high CPU or rising RSS | still deserializing the suspended environment (`D` = waiting on I/O, usually NFS) | wait; do not kill yet |
| `S`/`Sl`, CPU < 1%, RSS stable | resume finished, waiting for the browser | user opens **one** tab and waits 2–3 min |
| process gone, user still on "Loading…" | rsession crashed or was terminated | check the journal and the health check again |

Rule of thumb from the 2026-10-28 incident: a 765 MB suspended environment gave an `rsession` of about 1.6 GB RSS after resume (about 2×), plus a child R process for RStudio's package indexing.

### 3.4 Storage signals

| Signal | Meaning |
|---|---|
| `ENOLCK (No locks available)` in the RStudio journal | NFS lock request refused. Seen when two browser tabs started two rsessions in the same second on the same session dir. Isolated unless `dmesg` also shows NFS errors |
| `nfs: server biome-store03 not responding, still trying` | NFS outage; with `hard` mounts I/O blocks until `server ... OK`, then resumes |
| `NFS: state manager: check lease failed ... error 13` | NFSv4 lease renewal refused during an outage; expect `EIO` in sessions open at that time |
| Mount options on the nodes | `nfs4 vers=4.2, hard, nconnect=4, timeo=600, retrans=3, local_lock=none` |

## 4. Tool kit for a session that will not resume

| Tool | Reads | Safety | Use for |
|---|---|---|---|
| `scripts/99_check_rprofile_health.sh --user <u>` | profile chain, user startup files, RStudio state (as the user) | read-only | first check; section 7 shows the session state and its size |
| `... --user <u> --reset-profile` | same | dry-run | shows what would move and **refuses** while an rsession runs |
| `... --user <u> --reset-profile --commit` | moves `~/.local/share/rstudio`, `~/.Rprofile`, `~/.Renviron`, `~/.RData` into `~/.biome-profile-quarantine/<STAMP>/` | mutating, reversible (`--undo-reset <STAMP>`) | last step of the ladder |
| `scripts/99_postmortem_forensics.sh --user <u> --hours 72` | journal, OOM, signals, BIOME syslog, `/Rtmp`, BLAS, NFS, orphans | read-only (`--incident` appends the incident log) | crash history and host state |
| `journalctl -u rstudio-server` | rserver/rsession messages | read-only | login, resume, abnormal terminations |
| `sudo -u <u> ls/du/find` on `~/.local/share/rstudio` | session dirs | read-only | size of each suspended payload |

Known limits (2026-10-28):

- `99_postmortem_forensics.sh` does not filter the journal by user and does not check home quota or writability. Its section-4 `FIX:` line suggests `mv ~/.local/share/rstudio ...`: do **not** run it as root on NFS and do not run it while the rsession is alive. Use the ladder below or `--reset-profile`.
- Health 2.0 (on main) reported PASS for 769 MiB of state because it only compared the total with 1 GiB. Health 2.1 ([PR #53](https://github.com/gsamuele78/R-studioConf/pull/53)) adds the 256 MiB per-payload check.

### 4.1 Escalation ladder (least invasive first)

1. **Let the resume finish.** If the rsession is in `S` with low CPU (table 3.3), the user closes all RStudio tabs, opens **one**, and waits 2–3 minutes without pressing Terminate or Reload. Once in, they save big objects with `saveRDS()` (or `qs2`/parquet) into their project and clear them with `rm()`, so the next suspend is small.
2. **Move only the suspended payload.** Keeps open tabs and preferences.

   ```bash
   U=<user>; D=/nfs/home/$U/.local/share/rstudio/sessions/active/session-<id>
   P=$(pgrep -u "$U" -x rsession); echo "rsession: ${P:-none}"
   [ -n "$P" ] && sudo kill "$P"
   # wait until it is really gone; SIGTERM is not instant on a large session
   for i in $(seq 1 12); do pgrep -u "$U" -x rsession >/dev/null || break; sleep 5; done
   pgrep -u "$U" -x rsession && sudo kill -9 "$P"   # only if still alive after 60 s
   pgrep -u "$U" -a rsession || echo "no rsession"   # must print "no rsession"
   sudo -u "$U" ls -la "$D"                           # suspended-session-data still there?
   sudo -u "$U" mv "$D/suspended-session-data" "/nfs/home/$U/suspended-session-data.bak-$(date +%F)"
   sudo -u "$U" ls -la "$D"                           # must NOT list suspended-session-data
   ```

   Do not move the directory while the rsession is still alive: an exiting rsession may write session state again. If `suspended-session-data` reappears after the move, stop the process with `kill -9` and move it again under another name (`.bak-$(date +%F)-2`).
3. **Reset the RStudio profile** (reversible quarantine):

   ```bash
   sudo bash scripts/99_check_rprofile_health.sh --user <user> --reset-profile           # dry-run
   sudo bash scripts/99_check_rprofile_health.sh --user <user> --reset-profile --commit
   sudo bash scripts/99_check_rprofile_health.sh --user <user> --undo-reset list         # rollback point
   ```

   It also moves `~/.Renviron`. If that file holds settings the user needs, copy it back from the quarantine as the user.

**Verification after any step.**

```bash
U=<user>
sudo bash scripts/99_check_rprofile_health.sh --user "$U"        # section 7: no suspended-payload WARN
# while the user logs in with one tab:
sudo journalctl -u rstudio-server --since '-10 min' --no-pager | grep -iE "$U|error|abnormal"
ps -o etime,stat,%cpu,rss -p "$(pgrep -u "$U" -x rsession)"
```

Healthy: an rsession of a few hundred MB, state `S`, and no "terminated abnormally" in the journal. The user gets an empty environment; their files and scripts are unchanged. The objects are still in the `.bak` directory or the quarantine; restoring them is a separate, supervised step (not yet a documented procedure).

## 5. Finding the host event

A session that was fine yesterday and is stuck today was suspended by something. Two possible triggers:

- **Idle timeout:** the user was inactive for longer than `session-timeout-minutes`. No service event in the journal.
- **Service stop/restart:** `rstudio-server` was stopped or restarted. All sessions on the node are suspended at the same second.

```bash
grep -E '^session-timeout' /etc/rstudio/rsession.conf
sudo journalctl -u rstudio-server --since '<day> 00:00' --until '<day> 23:59' --no-pager | grep -E 'Stopping|Stopped|Started|Consumed'
grep -E '^<YYYY-MM-DD>' /var/log/dpkg.log | grep -E ' upgrade | install '
sudo zgrep -h -A3 'Start-Date: <YYYY-MM-DD>' /var/log/apt/history.log*
sudo journalctl --since '<day> 05:00' --until '<day> 08:00' --no-pager | grep -iE 'needrestart|unattended|apt-daily|restart'
sudo zgrep -hE 'rstudio-server|Restarting' /var/log/unattended-upgrades/unattended-upgrades*.log* | tail
systemctl list-timers 'apt-daily*' --no-pager
sudo dmesg -T | grep -iE 'nfs|lockd|lease' | tail -20
```

A `Stopping rstudio-server.service` line that follows an `apt-daily-upgrade.service` start within seconds means unattended-upgrades upgraded a library used by rserver and needrestart restarted the service. The `Consumed ... memory peak` line shows how much memory the sessions held at that moment.

**Prevention:** [ADR-0007 and `scripts/biome_node_maintenance.sh`](https://github.com/gsamuele78/R-studioConf/pull/53) (PR #53, open) stop needrestart from restarting rstudio-server and run OS upgrades only 03:30–05:00 on a node with no R sessions. Until it is merged and installed (`--install-timer`, one host at a time), any unattended upgrade of an rserver library can repeat this incident on any node.

## 6. Worked example: biome-calc01, 2026-10-28

A researcher (called *user A* here) reported that RStudio no longer opened on biome-calc01. Times are local (CET), as printed by the host journal and `ls`.

### 6.1 Timeline

| Time | Event | Evidence |
|---|---|---|
| 2026-10-27 15:50 | Last edit by user A in the IDE | mtimes in `sources/session-*/` |
| 2026-10-28 06:26:25 | `apt-daily-upgrade.service` starts | `journalctl` |
| 06:26:32 | unattended-upgrades upgrades `libbrotli1`, `libbrotli-dev` | `/var/log/dpkg.log` |
| 06:26:34 → 06:26:51 | needrestart restarts `rstudio-server`; "Consumed 1d 54min CPU, 140.8G memory peak" | `journalctl -u rstudio-server` |
| 06:26 | every session suspended; user A's environment written to NFS: `suspended-session-data/environment`, **765 MB** | `sudo -u <u> find ... -size +20M` |
| 08:02 | two rsessions start in the same second (two browser tabs); one gets `ENOLCK` on the session lock | `journalctl -u rstudio-server` |
| 08:02 → ~09:15 | loop: the IDE stays on "Loading…", the user presses Terminate/Reload, a new resume starts; "previous R session terminated abnormally" four times | `journalctl -u rstudio-server` |
| 09:58 | the current rsession (started 09:17) alive for 41 min, `Sl`, 0.6% CPU, 1.6 GB RSS: the resume had finished | `ps -o etime,stat,%cpu,rss` |
| 10:17 | ladder step 2: rsession stopped, `suspended-session-data` moved to `~/suspended-session-data.bak-2026-10-28` | operator shell |

### 6.2 What each check showed

| Check | Result | Conclusion |
|---|---|---|
| Authentication (journal) | `granted access` at every login | not an identity problem |
| Home (health check §7, `df`) | writable, 22% used, no `~/.RData` | not storage or quota |
| Health check (v2.0) | 62 PASS, 1 WARN (profile load 2.1 s); §7 "RStudio session state: 769.1 MiB" **PASS** | tool gap → health 2.1 in PR #53 |
| Session dir sizes (`du`, `find -size +20M`) | one 765 MB `suspended-session-data/environment` | **cause** |
| `--reset-profile` dry-run | would move 770 MB; `BLOCKED: rsession running` | the guard worked as designed |
| Child process of the rsession | `R --vanilla ... .rs.getPackageInformation('DALEXtra','data.table',...,'tidyverse')` | RStudio package indexing after resume; extra load, not the cause |
| `dmesg` | NFS outage on 2026-10-05 only | `ENOLCK` was the two-tab race, not an outage |
| Host event (§5 commands) | dpkg upgrade + rstudio-server restart at 06:26 | **trigger** |
| `rsession.conf` | `session-timeout-minutes=10080` | idle timeout excluded; drift from repo (2880) found |

### 6.3 Mistake to avoid

In the first fix attempt, `pgrep` still printed the rsession pid 5 s after `kill`, and the `mv` ran anyway. On a large session `SIGTERM` is not instant. The ladder in §4.1 now waits for the process to exit and checks that `suspended-session-data` did not come back.

### 6.4 Follow-ups opened by this incident

| Item | Status |
|---|---|
| Health check must warn on a large suspended payload | [PR #53](https://github.com/gsamuele78/R-studioConf/pull/53), health 2.1 (open) |
| No rstudio-server restart by needrestart; OS upgrades only on a free node (ADR-0007) | [PR #53](https://github.com/gsamuele78/R-studioConf/pull/53) (open) |
| Large sessions: session state on local disk, in-session RSS warning, nightly report (ADR-0008) | Proposed, not yet a PR; point 1 (state on local disk) **not verified**. An earlier test found that `XDG_*` variables exported in `rsession-profile` did not move RStudio state on OSS ([`rstudio_session_isolation.md`](rstudio_session_isolation.md) §2); the ADR now tests a `rsession-path` wrapper on calc04 and drops point 1 if that fails |
| Align `session-timeout-minutes` on the hosts (10080) with the repo (2880) | decision pending |
| `99_postmortem_forensics.sh` §4 `FIX:` hint (root `mv`, no rsession stop) | open; use §4.1 instead |
| Restoring objects from a moved `suspended-session-data` | not yet documented or tested |
| Home-directory ACLs on TrueNAS | under review separately |

## 7. Unverified

- Whether `SIGTERM` makes `rsession` write a new suspended state on these RStudio versions is not verified. The ladder is written so that it is safe either way.
- Live session-timeout values, package versions and timers on calc02–calc04 were not captured during this incident. Check them per host with the §5 commands.
