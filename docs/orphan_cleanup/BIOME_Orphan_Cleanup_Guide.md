<!-- docs/orphan_cleanup/BIOME_Orphan_Cleanup_Guide.md -->
# BIOME-CALC Orphan Process Cleanup Administrator Guide

This guide describes the T1 subsystem deployed by `scripts/50_setup_nodes.sh::setup_nodes_orphan_cleanup` from these templates:

- `cleanup_r_orphans.sh.template` — header v4.5, with later v4.6/v4.7 logic comments
- `notify_r_orphans.sh.template` — v4.3
- `r_orphan_report.sh.template` — v4.3
- `r_orphan_cleanup.conf.template`
- `orphan_cleanup_helpers.sh.template`
- `send_email.sh.template`

The subsystem looks for configured worker command patterns, excludes protected processes, checks ancestry and age, sends `SIGTERM`, waits, and sends `SIGKILL` only if the process remains. It writes per-user pending notification files; mail delivery is a separate scheduled step.

## Configuration sources

Current values in `config/setup_nodes.vars.conf`:

```bash
SMTP_PORT="25"
KILL_TIMEOUT="30"
ORPHAN_CRON_CLEANUP="15 * * * *"
ORPHAN_CRON_NOTIFY="00 18 * * *"
ORPHAN_CRON_REPORT="00 08 * * 1-5"
```

The following committed values are sanitized examples and must be supplied through gitignored `config/site/setup_nodes.site.vars.conf` on a real deployment:

- `SMTP_HOST`
- `SENDER_EMAIL`
- `MAIL_DOMAIN`
- `MAIL_DOMAINS_USER`
- `SMTP_DNS_SERVERS`
- `BIOME_CONTACT`

Administrative and user-specific addresses also come from site-local files:

- `config/site/admin_recipients.txt`, one address per non-comment line
- `config/site/user_email_map.txt`, whitespace-separated `username address`

See [`../../config/SITE_OVERRIDE.md`](../../config/SITE_OVERRIDE.md). `50_setup_nodes.sh` copies the maps to `/etc/biome-calc/conf/`, copies `setup_nodes.vars.conf`, and uses `patch_deployed_mail_overrides` to inject the six active mail/contact values into the deployed copy.

## Deployed files

```text
/etc/biome-calc/
├── conf/
│   ├── admin_recipients.txt
│   ├── user_email_map.txt
│   ├── setup_nodes.vars.conf
│   └── r_orphan_cleanup.conf
└── script/
    ├── cleanup_r_orphans.sh
    ├── notify_r_orphans.sh
    ├── r_orphan_report.sh
    ├── send_email.sh
    ├── orphan_cleanup_helpers.sh
    └── common_utils.sh

/etc/cron.d/r_orphan_cleanup
```

`r_orphan_cleanup.conf` sets:

- `LOG_DIR=/var/log/biome-log/r_orphan_cleanup`
- `LOG_FILE=${LOG_DIR}/cleanup.log`
- `NOTIFY_DIR=${LOG_DIR}/notifications`
- `MIN_AGE_SECONDS=120`
- `MAX_LOG_SIZE=10 MiB`
- configured process and exclusion patterns
- `ADMIN_EMAIL=file:///etc/biome-calc/conf/admin_recipients.txt`

Current path discrepancy: `50_setup_nodes.sh` also creates `/var/log/r_orphan_cleanup/notifications` with mode `0777`, while the generated configuration directs scripts to `/var/log/biome-log/r_orphan_cleanup`. The former is not the configured log path. The world-writable directory and path mismatch remain open audit defects.

## Cleanup behavior

The cleanup script:

1. sources `/etc/biome-calc/conf/r_orphan_cleanup.conf`;
2. builds one grep expression from `ORPHAN_PATTERNS`;
3. excludes configured service/compiler processes and explicit `parallel:::.workRSOCK`/`.slaveRSOCK` workers;
4. ignores zombie (`Z`/`<defunct>`) entries;
5. considers PID 1 reparenting or an ancestry search with no accepted owner to indicate an orphan;
6. requires the configured minimum age;
7. appends a `KILLED` record and a per-user notification;
8. sends `SIGTERM`, waits, then sends `SIGKILL` if needed.

Accepted ancestors include RStudio sessions, interactive R, rserver, tmux, screen, sshd, `R CMD`, NIMBLE, and `compileNimble` within the configured depth.

Important source discrepancy: the generated configuration receives `KILL_TIMEOUT` from `setup_nodes.vars.conf` (30 seconds by default), but `cleanup_r_orphans.sh` resets `KILL_TIMEOUT=15` after sourcing the config. The effective cleanup grace period is therefore 15 seconds until the code is corrected.

## Email resolution

`orphan_cleanup_helpers.sh` resolves recipients in this order:

1. explicit `user_email_map.txt` entry;
2. every domain in `MAIL_DOMAINS_USER`, emitted as CSV;
3. `username@MAIL_DOMAIN` fallback.

Administrative recipients can be supplied as a `file://` path, CSV, or one address. The deployed helper deduplicates addresses.

## Deployment

Run the T1 setup script and use its own menu/help to select the orphan-cleanup step:

```bash
sudo bash scripts/50_setup_nodes.sh
```

The repository source labels this Step 11b. Do not rely on an older numeric menu option documented elsewhere.

## Manual operation

Run a scan immediately:

```bash
sudo /etc/biome-calc/script/cleanup_r_orphans.sh
```

Preview notification processing without sending mail:

```bash
sudo /etc/biome-calc/script/notify_r_orphans.sh
```

Send pending user notifications:

```bash
sudo /etc/biome-calc/script/notify_r_orphans.sh --mail
```

Print the administrative report:

```bash
sudo /etc/biome-calc/script/r_orphan_report.sh
```

Send the administrative report:

```bash
sudo /etc/biome-calc/script/r_orphan_report.sh --mail
```

Logs and pending notifications are under `/var/log/biome-log/r_orphan_cleanup/` according to the generated configuration.

## Validation checklist

Before enabling cron:

1. Confirm the site-local SMTP/mail values were patched into `/etc/biome-calc/conf/setup_nodes.vars.conf`.
2. Confirm recipient files contain no example addresses.
3. Confirm `send_email.sh` is executable and can reach the configured relay.
4. Review `ORPHAN_PATTERNS` and `EXCLUDE_PATTERNS` against real process command lines.
5. Test the report without `--mail`.
6. Create a controlled disposable orphan and verify classification before allowing a kill.
7. Confirm notification files are written under the configured `/var/log/biome-log/...` path.
8. Review `/etc/cron.d/r_orphan_cleanup` after deployment.

## Current implementation cautions

- Rendered orphan scripts use `#!/bin/bash` without `set -euo pipefail`.
- `ORPHANS_FOUND` is incremented inside a pipeline-fed `while` subshell; the final summary in the parent shell may not reflect kills from that run.
- The administrative report also counts inside a pipeline-fed loop, so the later `ORPHAN_COUNT` check can remain zero even when rows were printed.
- Process parsing is based on whitespace-split `ps` output and can misparse unusual command lines.
- The cleanup and report use different safety algorithms; do not treat the report as exact proof of what cleanup will kill.
- Cron and email delivery are active operational behavior; test with controlled processes and recipients.

Unverified: no live processes were terminated, no SMTP message was sent, and no production cron run was observed during this repository-only audit.
