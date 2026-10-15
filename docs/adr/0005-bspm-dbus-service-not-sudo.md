<!-- docs/adr/0005-bspm-dbus-service-not-sudo.md -->
# ADR-0005: Researchers install R packages through bspm's D-Bus service, not sudo

Status: Proposed
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
  `remove`), but it is not registered: no file under
  `/usr/share/dbus-1/system-services/` or `/etc/dbus-1/system.d/`.
  `python3-dbus`, `python3-gi` and `python3-apt` are installed.

## Decision

1. Register bspm's D-Bus service on every T1 host, run as root by bus activation.
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
   (dry-run by default, backup, automatic rollback if the service does not answer,
   `--rollback DIR`).
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
3. Production hosts one at a time, same checks; then the operator removes the two
   sudo lines (`visudo -c` after each edit).
4. Rollback at any point: `sudo bash scripts/fix_bspm_dbus_inplace.sh --rollback DIR`
   (restores `Rprofile.site`, removes both D-Bus files, reloads dbus). The sudo
   lines are untouched by the script, so rollback needs nothing else.
