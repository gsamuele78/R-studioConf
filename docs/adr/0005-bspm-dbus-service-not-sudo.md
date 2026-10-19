<!-- docs/adr/0005-bspm-dbus-service-not-sudo.md -->
# ADR-0005: Researchers install R packages through bspm's D-Bus service, not sudo

Status: Accepted (applied on biome-calc01-04, 2026-10-19)
Date: 2026-10-15

## Context

`templates/Rprofile_site.R.template` (section 0) sets `bspm.sudo = TRUE`, so a
researcher's `install.packages()` runs `sudo bspm.py install ...`, which calls apt.
To make that work without a password in RStudio Web, `scripts/50_setup_nodes.sh`
Step 7 writes `/etc/sudoers.d/99-bspm-domain-users`:

```text
%domain_users ALL=(ALL) NOPASSWD: /usr/bin/apt-get, /usr/bin/apt-mark, /usr/bin/dpkg, /usr/lib/R/site-library/bspm/service/bspm.py
```

Checked on the hosts on 2026-10-15:

- Unrestricted `sudo apt-get` / `sudo dpkg` is root for any domain user (apt hooks,
  `dpkg -i` of a crafted deb).
- Narrowing the rule to `bspm.py` alone is also root: in sudo mode `bspm.py` takes
  `-o FILE` and appends caller text to that file as root, and it exposes `remove`.
- Every host also carries a manual line, not in this repo,
  `%domain_users ALL=(ALL) ALL`. Every researcher is a full admin with their own
  password.
- With both sudo lines removed, a researcher's `install.packages("praise")` fails
  with an empty `Error:`. bspm does not fall back to the personal library, so sudo
  cannot simply be removed.
- The installed bspm ships a D-Bus system service (`bspm.py` with no arguments,
  bus name `org.r_project.linux1`, methods `install`, `available`, `discover`,
  `remove`). `python3-dbus`, `python3-gi` and `python3-apt` are installed.
- Correction (2026-10-16, biome-calc04): the service **is** registered, by hand,
  not by this repo or a package (`dpkg -S` finds nothing; files dated Apr 28).
  An earlier search for "bspm" missed it because the files only name the bus.
  Its `Exec` is `/root/R/x86_64-pc-linux-gnu-library/4.5/bspm/service/bspm.py`
  (root's personal R 4.5 library) and its policy allows **every local user** to
  call every method, `remove` included; a domain user's Introspect succeeds.
  bspm still used sudo only because the profile forces `bspm.sudo = TRUE`.
- First hotfix run (2026-10-16): dbus-daemon rejected the whole new policy file
  because one rule named a member without an interface, so even root got
  `AccessDenied`; the script rolled back. Fixed, and now guarded by a CI test
  that loads the policy into a real dbus-daemon
  (`tests/test_bspm_dbus_policy_live.sh`).

## Decision

1. Register bspm's D-Bus service on every T1 host, run as root by bus activation,
   from the system library copy (`/usr/lib/R/site-library/bspm`), replacing any
   hand-made registration.
2. The bus policy (`/etc/dbus-1/system.d/org.r_project.linux1.conf`) denies the
   bus name to everyone by default, lets root own it, and lets `domain_users` call
   only `install`, `available`, `discover` and `Introspect`. `remove` is denied
   explicitly as the last rule, which also covers calls that omit the interface.
3. The profile sets `bspm.sudo = FALSE` and enables bspm only when the service file
   exists. Without it, `install.packages()` is plain R into the personal library
   (`R_LIBS_USER` on `/var/lib/biome-Rlibs`), which is slower (source builds) but
   never needs root.
4. `50_setup_nodes.sh` Step 7 registers the service
   (`fix_bspm_dbus_inplace.sh --commit --skip-profile`) and no longer writes the
   sudoers rule. An existing rule is left in place with a warning.
5. Live hosts get the same change in place with `scripts/fix_bspm_dbus_inplace.sh`
   (dry-run by default, backup, automatic rollback if the service does not answer
   or the bus name stays owned by a bspm from another path, `--rollback DIR`).
6. Removing the two sudo lines is a separate, manual step taken by the operator
   after a researcher install works through the service on that host.

## Consequences

- Researchers keep binary installs from RStudio Web with no password prompt and no
  sudo. Admins keep their own sudo.
- Installs still land in the host-local `/usr/lib/R/site-library`; cross-host drift
  is unchanged and handled by ADR-0004.
- Researchers can no longer remove system packages from R (`remove` is denied).
  That is intended: a removal on one host breaks every user of that host.
- The service exits 10 s after its last call and is restarted by bus activation.

### Residual risk (upstream bspm, accepted)

Each service method takes a caller-supplied `pid` and writes apt's output to
`/proc/<pid>/fd/2` as root. A domain user can therefore make root write apt output
lines to another process's stderr. The text is apt's progress output, not caller
controlled, so it is far smaller than the current sudo exposure, but it is not
zero. It should be reported upstream.

## Alternatives rejected

- **Keep the NOPASSWD rule**: root for every domain user.
- **Sudo on `bspm.py` only**: root through `-o FILE` (see Context).
- **Disable bspm for researchers**: every install becomes a source build into the
  personal library (minutes to an hour for `sf`, `terra`); researchers would ask
  admins instead, which is what bspm was adopted to avoid.
- **polkit**: RStudio Web has no polkit agent; D-Bus policy needs none.

## Rollout and validation

1. Spare/test host: `sudo bash scripts/fix_bspm_dbus_inplace.sh` (dry-run), then
   `--commit`.
2. As a domain user **without sudo** (sudo lines commented on the test host only),
   from a terminal with no TTY and from RStudio Web:
   `setsid -w Rscript -e 'install.packages("praise"); cat(find.package("praise"), "\n")' < /dev/null`
   must print `/usr/lib/R/site-library/praise`. Then
   `Rscript -e 'bspm::remove_sys("praise")'` must fail with an access-denied error.
3. Production hosts one at a time, same checks. Sessions started before the
   hotfix keep `bspm.sudo = TRUE` (the profile is read at session start) and go
   through sudo; RStudio can resume a suspended session with the old option.
   So remove the two sudo lines only after those sessions have ended
   (`pgrep -a rsession`), and use `visudo -f /etc/sudoers.d/99-bspm-domain-users`
   for the drop-in (plain `visudo` edits only `/etc/sudoers`); `visudo -c` after
   each edit. Seen on the test host 2026-10-19: `Rscript` in a new shell
   installed over D-Bus, an already-open RStudio session failed in `sudo_call`.
4. Rollback at any point: `sudo bash scripts/fix_bspm_dbus_inplace.sh --rollback DIR`
   (restores `Rprofile.site`, removes both D-Bus files, reloads dbus). The sudo
   lines are untouched by the script, so rollback needs nothing else.

## Rollout log

| Host | Applied (UTC) | State before | Backup |
|---|---|---|---|
| biome-calc04 (test) | 2026-10-19 14:07 | hand-made service + open policy (bspm from `/root/R/.../4.5`) | `/root/bspm-dbus-hotfix-20261019T140704Z` |
| biome-calc03 | 2026-10-19 14:26 | nothing registered | `/root/bspm-dbus-hotfix-20261019T142633Z` |
| biome-calc02 | 2026-10-19 14:31 | nothing registered | `/root/bspm-dbus-hotfix-20261019T143113Z` |
| biome-calc01 | 2026-10-19 14:35 | open policy file, no service file | `/root/bspm-dbus-hotfix-20261019T143512Z` |

calc04 validated end to end (shell and RStudio web, sudo lines commented,
`remove_sys` denied). calc01-03 (2026-10-19 ~14:40): a domain user's
`Rscript` installed `praise` into `/usr/lib/R/site-library` over D-Bus and
`remove_sys` was denied. Both sudo lines commented on all four hosts, confirmed 2026-10-19 ~14:47
with `sudo -l -U <domain user>` ("is not allowed to run sudo"). calc01 had
two RStudio sessions open when sudo was removed; if they predate the hotfix
they need Quit Session before `install.packages()` works.

