# plan/home_quota_visibility/implementation_plan.md

# Home quota visible to users (status(), ttyd)

Status: **IMPLEMENTED — TrueNAS rollout pending after merge** (2026-10-07)
Tier: T1 first; T2 port after T1 is verified; T3 deferred (SKELETON_NOT_READY).
Decisions taken: SSH with a forced command (no TrueNAS API key); show the
personal quota only (space + file count), not group quotas.

## 1. Problem

Homes are on TrueNAS SCALE (`biome-store03`, dataset `zpool/home`, NFSv4.2,
`sec=sys`) with per-user ZFS quotas (`userquota@<uid>`, `userobjquota@<uid>`).
A user who hits the quota gets `Disk quota exceeded` on every write, while
every tool they can run says the disk is nearly empty:

- `df` on the client shows the whole dataset (2.2 TB free in the 2026-10
  incident, user at 153 MB of a 150 MB quota);
- `quota` / `rpc.rquotad` do not support ZFS (openzfs/zfs#2207; TrueNAS
  forum threads "View user quotas in NFS client"), so the Linux client has no
  way to read ZFS user quotas;
- `biome_save_session()` warns on low `df` space only, so it never warns
  about the quota.

The data exists only on the storage server: `zfs userspace`.

## 2. Design

```
TrueNAS (biome-store03)                         compute node (T1, every 5 min)
  user biomequota                                 cron (/etc/cron.d/biome_quota)
  sudo NOPASSWD: exact zfs userspace              root: biome_quota_collect.sh
  command only; NO zfs allow                        ssh restricted key
  authorized_keys: restrict, forced command          parse + validate + atomic write
                                                 /var/lib/biome-quota/ (local ext4, 0711)
                                                   <uid>             (0400 <uid>:root)
                                                   .collected_at     (0644, epoch)
                                                 R   : status(), biome_quota(), save warning
                                                 ttyd: biome-quota, profile.d warning
```

Why this shape:

- **Read-only, least privilege on TrueNAS.** The service user has one exact
  `NOPASSWD` sudo command: `zfs userspace -Hpn -o
  name,used,quota,objused,objquota zpool/home`. It has no `zfs allow` delegation
  (delegating `userquota` could permit changes). The SSH key is forced to that
  same command (`command=` + `restrict`: no shell, port/X11/agent forwarding or
  pty). The client cannot pass arguments.
- **Per-user privacy without depending on NFS ACLs.** The cache is on the
  node's local disk, not on NFS. Directory `0711` (no listing), file `0400`
  owned by the user: each user reads only their own line. The NFSv4 ACLs of
  `zpool/home` play no part, and the cache files do not consume the user's
  quota.
- **Pessimistic.** The collector never edits anything on TrueNAS, never
  blocks a login, never raises an error in R. Every reader shows the age of
  the data and degrades to "quota information not available" with the
  reason.

## 3. Components (T1)

| File | Kind | What |
|---|---|---|
| `templates/biome_quota_collect.sh.template` | new script → `${BIOME_CONF}/script/biome_quota_collect.sh` | `#!/usr/bin/env bash` + `set -euo pipefail`. `flock` against overlap; `ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes -o UserKnownHostsFile=${BIOME_CONF}/secrets/quota_known_hosts`; whole run under `timeout 60`. Validates each line (5 TAB fields, numeric uid, numeric or `-`/`none`); rejects the whole snapshot if fewer than `QUOTA_MIN_LINES` lines (protects against an empty/partial answer wiping the cache). Writes each `<uid>` via `mktemp` in the same dir + `chown <uid>` + `chmod 0400` + `mv`. Only uids that exist in NSS (`getent passwd <uid>`) are written. On SSH failure keeps the previous files and logs to `${ARCHIVE_LOG_DIR}`/journal; `.collected_at` is only advanced on success. |
| `/etc/cron.d/biome_quota` | written by 50_setup_nodes | `*/5 * * * * root ${BIOME_CONF}/script/biome_quota_collect.sh` (schedule from `QUOTA_CRON`), same pattern as `/etc/cron.d/r_orphan_cleanup`. |
| `templates/biome-quota.sh.template` | new → `/usr/local/bin/biome-quota` | Shell reader for ttyd: prints the same line as `status()`. Exit 0 always. |
| `templates/zz-biome-quota.profile.template` | new → `/etc/profile.d/zz-biome-quota.sh` | On interactive login shells (ttyd uses `login -f`) prints one line only when usage ≥ `QUOTA_WARN_PCT`. Silent otherwise. Never fails the login. |
| `templates/Rprofile_site.d/70_persistent_tools.R.template` | edit | (a) `biome_quota()` helper; (b) one `Home:` line in `status()`; (c) `biome_save_session()` uses the quota when available instead of `df` only. |
| `config/setup_nodes.vars.conf` | edit | `ENABLE_HOME_QUOTA_VIEW=false` (default off until TrueNAS side is ready), `QUOTA_SSH_HOST`, `QUOTA_SSH_USER=biomequota`, `QUOTA_CRON="*/5 * * * *"`, `QUOTA_WARN_PCT=90`, `QUOTA_STALE_MIN=30`, `QUOTA_MIN_LINES=1`. Host/user are site values; documented in the `.example`/site overlay. |
| `scripts/50_setup_nodes.sh` | edit: new step "11g: Home quota view" | Skipped unless `ENABLE_HOME_QUOTA_VIEW=true`. Creates `/var/lib/biome-quota` (0711), deploys the scripts, writes the cron file, checks key + known_hosts exist with mode 0600/0644 and **exits 1** if permissions cannot be set (hard rule 14). Runs the collector once and reports the line count. Uninstall path removes cron, scripts, cache. |
| `scripts/99_troubleshoot_env.sh` | edit `--storage` | Shows cache age and the user's line for `--test-user`; on EDQUOT prints the cached quota next to the error. |

The key is generated on the node by the operator (`ssh-keygen -t ed25519 -N ''
-f ${BIOME_CONF}/secrets/quota_ssh_key`), never by a script argument, never
committed (HC-04, HC-08).

## 4. What the user sees

R, `status()` (new line, after `/Rtmp`):

```
 Home (~):    147.2 GB of 150 GB used (98%)  | files: 361 (no limit) | updated 3 min ago
              ⚠ almost full: new files will fail with "Disk quota exceeded".
                See biome_quota() for what to do.
```

`biome_quota()` (and `biome-quota` in the terminal):

```
Your home folder (/nfs/home/<user>) on the storage server
  Space : 147.2 GB of 150 GB  (98%)  — 2.8 GB left
  Files : 361 (no limit)
  Data  : updated 3 min ago (refreshed every 5 minutes)

It counts every file you own on the home storage, also files you placed in a
colleague's folder. Files a colleague writes into your folder count for them.
When it is full: delete what you no longer need, keep intermediate files in
tempdir() (fast scratch disk, not counted), or ask the admins for more space.
```

Degraded cases (one plain sentence, never an R error):

| Situation | Text |
|---|---|
| no quota set | `Home (~): 12.4 GB used (no personal limit)` |
| cache older than `QUOTA_STALE_MIN` | value + `(data from 2 h ago, may be out of date)` |
| no file for this uid / feature off | `Home (~): quota information not available on this server` |
| file present but unreadable | same as above (no path or permission details shown to users) |

`biome_save_session()`: if usage + estimated object size > quota, warn
`Save will probably fail: your home has ~X GB left of your quota.`

Wording goes into `docs/user_guides/COMMON_PROBLEMS.md §1` and the cheat
sheet ("check with `status()`"), replacing "you cannot see the quota".

## 5. TrueNAS SCALE and node steps

Moved to the operator runbook
[`docs/operations/HOME_QUOTA_VIEW_SETUP.md`](../../docs/operations/HOME_QUOTA_VIEW_SETUP.md):
TrueNAS 25.04 user/sudo/SSH settings, one key per node bound with `from=`,
staggered cron, UID consistency check across nodes, Ubuntu 24.04
prerequisites, a CHECK after every step, add/remove/replace a node,
troubleshooting and rollback.

## 6. Tests

- **bats** (`tests/unit/`): collector parser on fixtures (valid, `none` quota,
  malformed line, empty answer, partial answer below `QUOTA_MIN_LINES`, uid not
  in NSS) — asserts files written/not written, modes, previous cache kept on
  failure. SSH replaced by a stub via `QUOTA_SSH_CMD` override (test-only).
- **R**: `biome_quota()` formatting on fixture files (quota, no quota, stale,
  missing, unreadable), and `status()` still runs when the directory does not
  exist. Added to the "R runtime static" CI job.
- **shellcheck** + `tests/check_exec_bits.sh` for the new scripts.
- **On a node** (operator): collector run, `sudo -u <user> biome-quota`,
  `status()` in RStudio, another user cannot `cat /var/lib/biome-quota/<uid>`
  and cannot `ls /var/lib/biome-quota`.

## 7. Rollout

1. TrueNAS steps (§5) and key on one node.
2. Merge with `ENABLE_HOME_QUOTA_VIEW=false`; enable on one node; run
   `50_setup_nodes.sh` step 11g; verify (§6 on-node).
3. Enable on the other nodes. Update user docs in the same PR as the R change.
4. T2: bind-mount `/var/lib/biome-quota` read-only into the RStudio
   container (collector stays on the host); record as a T2 mirror, not a delta.

## 8. Open items

- **O1** TrueNAS UI and the `command=` prefix: if the UI strips it, put the
  key in `~biomequota/.ssh/authorized_keys` by hand and note that TrueNAS
  upgrades may reset it (re-check after each upgrade).
- **O2** uid mapping: the collector trusts that TrueNAS stores quotas under the
  same numeric uid the client uses (true today: quota for 165192219 matched
  `id enrico.tordoni`). If a quota exists only for an unknown uid, the
  collector logs it so the admin can spot a wrong mapping.
- **O3** RPROFILE_VERSION bump (70_persistent_tools change) with matching
  CHANGELOG section in the same commit (hard rule 18).
- **O4** `templates/motd_biome_rules.template` is not deployed by any script
  today, so the login hint uses `/etc/profile.d` instead of the MOTD.
