---
title: "Home quota view: setup on TrueNAS SCALE 25.04 and the Ubuntu 24.04 nodes"
audience: operator
status: current
tier: T1
source_path: docs/operations/HOME_QUOTA_VIEW_SETUP.md
last_verified: 2026-10-08
sharepoint_section: Operations Hub
---
<!-- docs/operations/HOME_QUOTA_VIEW_SETUP.md -->
# Home quota view: setup on TrueNAS and the compute nodes

This runbook turns on the Rprofile v12.11 home-quota view
(`status()`, `biome_quota()`, `biome-quota`) for **one or more compute
nodes** that mount their homes from the same TrueNAS server. Design and
rationale: `plan/home_quota_visibility/implementation_plan.md`.

## What was and was not verified

| Item | Status |
|---|---|
| TrueNAS 25.04 UI fields used below (Users: *Authorized Keys*, *Shell*, *Disable Password*, *Allowed sudo commands with no password*; Services → SSH: *Password Login Groups*, *Allow Password Authentication*, *Bind Interfaces*, *Auxiliary Parameters*) | Checked against the official 25.04 documentation (Users Screens, SSH Service Screen) |
| Collector, R helper and `biome-quota` logic | Unit tests (bats, R) and CI |
| Ubuntu 24.04 prerequisites (`cron`, `flock`, `timeout`, `ssh`, `getent`, `/etc/profile.d` via `login -f`) | Standard Ubuntu 24.04 packages; checked with the commands in step N1 |
| **Not verified on a live system:** whether the TrueNAS UI keeps the `from=`/`command=` options in *Authorized Keys* after saving; the exact `zfs` path; sudo argument matching on TrueNAS | Each step below has a check that proves it on your system before you go on |

Do not skip the checks marked **CHECK**: they are where an unverified
assumption is turned into a fact for your installation.

## How it works with several nodes

```
                      TrueNAS (one user: biomequota)
   authorized_keys:   from="<node1 IP>" ... node1 key  ─┐
                      from="<node2 IP>" ... node2 key  ─┼─ all forced to the SAME
                      from="<node3 IP>" ... node3 key  ─┘  read-only zfs userspace
        ▲                  ▲                  ▲
   node1 cron :00,:05  node2 cron :01,:06  node3 cron :02,:07
        │                  │                  │
   /var/lib/biome-quota  /var/lib/biome-quota  /var/lib/biome-quota   (local to each node)
```

- **One TrueNAS service user**, **one SSH key per node.** A key that leaks
  or a node that is retired is revoked by deleting one line, without
  touching the other nodes.
- Every key is bound to the node's source IP (`from=`) and forced to the
  same single command. The command is read-only: it cannot change quotas.
- Each node runs its own collector and keeps its own local cache. Nodes do
  not depend on each other. Five nodes at a 5-minute interval mean one tiny
  `zfs userspace` per minute on TrueNAS.
- **UIDs must be identical on every node.** The quota on TrueNAS is stored
  by numeric UID, and every node writes to NFS (`sec=sys`) with its own
  numeric UID. This is already a requirement for the NFS homes to work;
  step N2 checks it.

## Values used in this guide

Replace them with yours; write them down before starting.

| Name | Example | Where it comes from |
|---|---|---|
| TrueNAS address the nodes use | `172.30.192.163` (`biome-store03`) | `findmnt -no SOURCE /nfs/home` and `addr=` in `mount` output |
| Home dataset | `zpool/home` | `zfs list -o name,mountpoint` on TrueNAS |
| Service user | `biomequota` | new |
| Service home (NOT under the home dataset) | `/mnt/zpool/svc/biomequota` | new dataset `zpool/svc` |
| Node source IP towards TrueNAS | `172.30.192.20` | step N3 |

---

## Part A — TrueNAS SCALE 25.04 (once)

### A1. Find the exact command

In **System → Shell** (as root/admin):

```bash
command -v zfs                      # expect /usr/sbin/zfs
zfs list -H -o name,mountpoint | grep /home
/usr/sbin/zfs userspace -Hpn -o name,used,quota,objused,objquota zpool/home | head -3
```

**CHECK:** the last command prints TAB-separated lines such as
`165192219  160432128  161061273600  361  -`. The command line you just
ran is **the** command. Use it character for character in A3 and A4; if
`zfs` is elsewhere or the dataset has another name, change it everywhere.

### A2. Dataset for the service user's home

The service user needs a real home directory (TrueNAS stores the
authorized keys there; the default `/var/empty` cannot hold them). It must
**not** be inside `zpool/home`: that dataset is exported to every node, and
the key file must not be visible over NFS.

**Datasets** → select the pool → **Add Dataset** → Name `svc`, Preset
*Generic*. No NFS or SMB share on it.

### A3. Create the user

**Credentials → Users → Add**:

| Field | Value |
|---|---|
| Full Name | `BIOME quota reader` |
| Username | `biomequota` |
| Disable Password | **Yes** |
| User ID | next free ≥ 3000, any value not used by AD/SSSD ranges |
| Create New Primary Group | yes |
| Auxiliary Groups | none (no `builtin_administrators`) |
| Home Directory | `/mnt/zpool/svc` with **Create Home Directory** selected (gives `/mnt/zpool/svc/biomequota`) |
| Home Directory Permissions | User: Read/Write/Execute; Group and Other: none |
| Shell | `sh` (not `nologin`: sshd runs the forced command through the user's shell) |
| Allowed sudo commands | empty |
| Allow all sudo commands | **no** |
| Allowed sudo commands with no password | the exact A1 line: `/usr/sbin/zfs userspace -Hpn -o name,used,quota,objused,objquota zpool/home` |
| Allow all sudo commands with no password | **no** |
| SMB User | **no** |
| Authorized Keys | leave empty for now (Part B creates the keys) |

Save.

**CHECK** in System → Shell:

```bash
sudo -l -U biomequota
```

Must list exactly one entry, `(ALL) NOPASSWD: /usr/sbin/zfs userspace -Hpn
-o name,used,quota,objused,objquota zpool/home`, and nothing else. sudo
matches arguments exactly: the same command with other arguments (for
example `zfs set ...`) is refused.

Do **not** use `zfs allow` for this user: delegating `userquota` grants
the right to *set* quotas, not only to read them.

### A4. SSH service

**System → Services → SSH → Edit**:

- **Running** and **Start Automatically**: on.
- **Bind Interfaces** (Advanced): the interface on the network the nodes
  use for NFS (the one with `172.30.192.163`), if you want SSH reachable only
  from there.
- **Allow TCP Port Forwarding**: off.
- **Password Login Groups**: do not add `biomequota`'s group.
- **Allow Password Authentication**: leave it as the admins need it today.
  `biomequota` has no password, so it can only log in with a key either way.
  Note the TrueNAS warning: with Active Directory joined and this option on,
  every AD user can try password SSH logins.

Leave **Auxiliary Parameters** empty unless step B5 shows that the UI drops
the key options (fallback there).

---

## Part N — Every compute node (Ubuntu 24.04), before Part B

Run on **each** node, as root.

### N1. Prerequisites

```bash
lsb_release -ds                                   # Ubuntu 24.04.x LTS
systemctl is-active cron                          # active
command -v flock timeout ssh ssh-keygen ssh-keyscan getent
```

**CHECK:** all commands found, `cron` active. If cron is missing:
`apt-get install -y cron && systemctl enable --now cron`.

### N2. Same UIDs on every node

```bash
for u in enrico.tordoni <another-user> <a-third-user>; do printf '%s ' "$u"; id -u "$u"; done
```

**CHECK:** run it on all nodes; the numbers must be identical node by node,
and must match what TrueNAS stores:

```bash
# on TrueNAS
/usr/sbin/zfs userspace -Hpn -o name,used zpool/home | grep -w 165192219
```

If a node shows different numbers, stop: the SSSD id-mapping differs
between nodes, and the NFS homes are already being written with wrong
owners. Fix SSSD first (`10_join_domain_sssd.sh`, same `ldap_id_mapping`
and ranges on every node).

### N3. Source IP towards TrueNAS

```bash
ip -4 route get 172.30.192.163 | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}'
```

Write it down for this node; it goes into the `from=` option.

---

## Part B — Keys (repeat B1–B3 per node, then B4–B6 once)

### B1. Key for this node

```bash
install -d -m 0700 -o root -g root /etc/biome-calc/secrets
ssh-keygen -t ed25519 -N '' -C "biomequota@$(hostname -s)" \
    -f /etc/biome-calc/secrets/quota_ssh_key
chmod 0600 /etc/biome-calc/secrets/quota_ssh_key
cat /etc/biome-calc/secrets/quota_ssh_key.pub
```

The private key never leaves the node. Do not copy one node's key to
another node.

### B2. TrueNAS host key (known_hosts)

```bash
ssh-keyscan -t ed25519 172.30.192.163 > /etc/biome-calc/secrets/quota_known_hosts
chmod 0644 /etc/biome-calc/secrets/quota_known_hosts
ssh-keygen -lf /etc/biome-calc/secrets/quota_known_hosts
```

**CHECK:** compare the fingerprint with the one TrueNAS itself reports
(System → Shell): `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`.
They must be identical. The name in `known_hosts` must be exactly the value
you will put in `QUOTA_SSH_HOST` (here the IP). If you prefer the host name,
scan the host name and use the same name in B6.

### B3. The authorized-keys line for this node

Build one line, all on one line, with this node's IP from N3 and the
public key from B1:

```
from="172.30.192.20",restrict,command="sudo -n /usr/sbin/zfs userspace -Hpn -o name,used,quota,objused,objquota zpool/home" ssh-ed25519 AAAA... biomequota@biome-calc01
```

### B4. Put all lines on TrueNAS

**Credentials → Users → biomequota → Edit → Authorized Keys**: paste one
line per node (B3), one per line. Save.

### B5. CHECK that TrueNAS kept the options

In System → Shell:

```bash
cat /mnt/zpool/svc/biomequota/.ssh/authorized_keys
stat -c '%U %a %n' /mnt/zpool/svc/biomequota /mnt/zpool/svc/biomequota/.ssh /mnt/zpool/svc/biomequota/.ssh/authorized_keys
```

Every line must still start with `from="...",restrict,command="..."`.
Owner `biomequota`; modes 700 / 700 / 600 (sshd refuses keys with looser
permissions).

**If the options were removed**, put the restriction in sshd instead.
Keep the plain keys in *Authorized Keys* and add to **Services → SSH →
Advanced → Auxiliary Parameters** (TrueNAS marks this field unsupported;
re-check after every TrueNAS update):

```
Match User biomequota Address *,!172.30.192.20,!172.30.192.21
    DenyUsers biomequota
Match User biomequota
    ForceCommand sudo -n /usr/sbin/zfs userspace -Hpn -o name,used,quota,objused,objquota zpool/home
    PermitTTY no
    AllowTcpForwarding no
    X11Forwarding no
    AllowAgentForwarding no
```

The first block refuses `biomequota` from every address except the listed
node IPs (in an sshd pattern list a negated entry that matches makes the
whole list fail). The second forces the read-only command for the allowed
connections. Update the IP list when you add or retire a node. Then
**CHECK** on TrueNAS: `sshd -T -C user=biomequota,addr=172.30.192.20,host=x
| grep -iE 'forcecommand|permittty|denyusers'` must show the forced command
and no `denyusers biomequota`; with an address that is not a node it must
show `denyusers biomequota`.

### B6. CHECK from each node

```bash
ssh -o BatchMode=yes -o StrictHostKeyChecking=yes \
    -o UserKnownHostsFile=/etc/biome-calc/secrets/quota_known_hosts \
    -o IdentitiesOnly=yes -i /etc/biome-calc/secrets/quota_ssh_key \
    biomequota@172.30.192.163 | head -3                                # quota lines
ssh ... biomequota@172.30.192.163 'zfs set userquota@1=1 zpool/home'  # same quota lines: the requested command is ignored
ssh -t ... biomequota@172.30.192.163                                  # "PTY allocation request failed", quota lines, connection closes
```

(`...` = the same options as the first line.) All three must print the
quota lines and nothing else (the third adds only the PTY refusal). Anything else (a shell prompt, an error from
`zfs set`, `Permission denied`) means a step above is wrong; do not go on.

---

## Part C — Enable on each node

### C1. Site variables

In the repo checkout on the node, `config/site/setup_nodes.site.vars.conf`
(gitignored, per node):

```bash
ENABLE_HOME_QUOTA_VIEW=true
QUOTA_SSH_HOST="172.30.192.163"       # exactly the name/IP used in known_hosts
QUOTA_SSH_USER="biomequota"
QUOTA_MIN_LINES=1
# Stagger the nodes so they do not all ask TrueNAS at the same second:
QUOTA_CRON="0-59/5 * * * *"           # node1; node2 "1-59/5 * * * *", node3 "2-59/5 * * * *" ...
```

### C2. Deploy step 11g and the R profile

```bash
sudo bash scripts/50_setup_nodes.sh      # choose QH  (quota view)
sudo bash scripts/50_setup_nodes.sh      # choose 3   (redeploy Rprofile with ENABLE_HOME_QUOTA_VIEW=true)
```

Option 3 is needed: the `Home (~)` line in `status()` is switched on at
render time. Step 11g alone deploys the collector, cron and `biome-quota`.

**CHECK** the step output: `collector: N quota rows cached` with N > 0.

### C3. Verify on the node

```bash
cat /etc/cron.d/biome_quota
ls -ld /var/lib/biome-quota                                 # drwx--x--x root root
stat -c '%U %a %n' /var/lib/biome-quota/$(id -u enrico.tordoni)   # enrico.tordoni 400
sudo -u enrico.tordoni biome-quota                          # his quota
sudo -u <other-user> cat /var/lib/biome-quota/$(id -u enrico.tordoni)  # Permission denied
sudo -u <other-user> ls /var/lib/biome-quota                # Permission denied
date -d @"$(cat /var/lib/biome-quota/.collected_at)"         # within the last 5 minutes
sudo -u enrico.tordoni Rscript -e 'status()'                # shows "Home (~): ..."
sudo bash scripts/99_troubleshoot_env.sh --storage --test-user enrico.tordoni
```

In RStudio the user sees the line after **Session → Restart R**.

### C4. Docker nodes (T2)

On a node that runs the docker tier, nothing extra is installed in the
containers: do Parts N, B, C on the host, then recreate the RStudio
container so it gets the new read-only mount (a plain `restart` does not
add mounts): `docker compose --profile sssd up -d rstudio-sssd` (or the
`samba` profile). The mount source is `HOST_QUOTA_CACHE_DIR` in `.env`,
default `/var/lib/biome-quota`. **CHECK:** `docker exec <container> ls -ld
/var/lib/biome-quota`.

---

## Adding, removing or replacing a node

| Change | What to do |
|---|---|
| Add a node | Parts N, B1–B3 on the new node; add its line in B4; B5, B6; Part C with the next cron offset |
| Retire a node | Delete its line in *Authorized Keys* (and its IP in the `Match` block if you used B5's fallback); on the node `50_setup_nodes.sh --uninstall` or remove `/etc/cron.d/biome_quota` |
| Node IP changes | Update `from=` (or the `Match Address` list) |
| Key compromised | Delete the line on TrueNAS first, then B1–B4 on that node |
| TrueNAS reinstalled / host key changed | Collector fails closed (`StrictHostKeyChecking=yes`); redo B2 on every node after verifying the new fingerprint |
| TrueNAS update | Re-run B5 and B6 on one node |

## Troubleshooting

The collector logs to `/var/log/biome-log/r_biome_system.log`
(`grep biome_quota_collect`). Run it by hand to see the error:

```bash
sudo QUOTA_SSH_HOST=172.30.192.163 QUOTA_SSH_USER=biomequota \
     /etc/biome-calc/script/biome_quota_collect.sh; echo rc=$?
```

| Symptom | Cause | Fix |
|---|---|---|
| `Host key verification failed` | known_hosts missing, wrong name, or host key changed | B2 with the same name as `QUOTA_SSH_HOST`; verify fingerprint |
| `Permission denied (publickey)` | key not in TrueNAS, wrong `from=` IP, bad modes on `.ssh` | B4, N3, B5 |
| `sudo: a password is required` | sudo entry does not match the forced command exactly | A3 CHECK: compare character by character |
| `fetch failed (cache kept)` with a timeout | firewall / SSH bound to another interface | A4 *Bind Interfaces*, `nc -vz 172.30.192.163 22` |
| `only 0 valid lines` | UIDs on TrueNAS not known on this node | N2 |
| `status()` has no `Home (~)` line | Rprofile not redeployed after enabling | C2 option 3, then Restart R |
| `biome-quota`: "information not available" | no cache file for this uid (no quota entry yet, or collector failing) | collector by hand; check the uid on TrueNAS |
| Data marked "may be out of date" | collector failing for > 30 min | log above |

## Rollback

On the node: `ENABLE_HOME_QUOTA_VIEW=false` in the site file, then
`50_setup_nodes.sh` option 3 (removes the line from `status()`) and
`rm -f /etc/cron.d/biome_quota`. On TrueNAS: delete the node's key line,
or the whole `biomequota` user when no node uses it.
