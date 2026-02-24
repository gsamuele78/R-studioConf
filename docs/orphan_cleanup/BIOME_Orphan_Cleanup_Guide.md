# BIOME-CALC — Orphan Process Cleanup Administrator Guide

## Overview

When an RStudio Server (OSS) session crashes, is administratively killed, or the user navigates away from the browser during an active parallel processing execution, the child R workers (`parallel`, `future`, `callr`) often remain active as detached orphan processes.
The R Orphan Process Cleanup infrastructure continuously monitors the server for these detached workers, terminates them gracefully (SIGTERM -> SIGKILL), and notifies both the specific user and the platform administrators of the reclaimed resources.

## Architecture and Configuration

As of the latest integration, this subsystem is completely decoupled from hardcoded paths and is strictly driven by the global **`50_setup_nodes.sh`** toolset.

### Global Configuration (`config/setup_nodes.vars.conf`)

The settings for the cleanup subsystem must be edited in the main `setup_nodes.vars.conf` file before deployment:

```bash
# Email threshold and tracking settings
SMTP_HOST="smtp.unibo.it"
SMTP_PORT="25"
SENDER_EMAIL="noreply-biome@unibo.it"
MAIL_DOMAIN="studio.unibo.it"
SMTP_DNS_SERVERS="137.204.25.10 137.204.25.11"
KILL_TIMEOUT="30"

# Cron scheduling parameters
ORPHAN_CRON_CLEANUP="15 * * * *"
ORPHAN_CRON_NOTIFY="00 18 * * *"
ORPHAN_CRON_REPORT="00 08 * * 1"
```

### Recipient and Mapping Dictionaries

Administrative recipients and specific user domain overrides are controlled by text files injected during node setup:

1. **`config/admin_recipients.txt`**: A line-by-line list of administrative email addresses (e.g., `gianfranco.samuele2@unibo.it`) that receive the weekly system `r_orphan_report.sh` summary.
2. **`config/user_email_map.txt`**: Overrides `MAIL_DOMAIN` for specific users that maintain non-standard domain addresses (e.g. `duccio.rocchini duccio.rocchini@unibo.it`).

## Automated Deployment Process

The system is automatically provisioned by running:

```bash
sudo ./scripts/50_setup_nodes.sh
# Select Option 8: Setup Orphan Process Cleanup
```

During deployment:

1. The script ensures standard email utilities (`sendemail`, `dnsutils`) exist on the OS.
2. The `config/*.txt` mappings are copied strictly into `/etc/biome-calc/conf/`.
3. The configuration options defined in `setup_nodes.vars.conf` are securely substituted into `r_orphan_cleanup.conf.template` and the execution scripts via `envsubst`, deploying the final resolved assets onto `/etc/biome-calc/script/`.
4. The system directly provisions `/etc/cron.d/r_orphan_cleanup` utilizing the `ORPHAN_CRON_*` directives configured earlier.
5. It enforces a world-writable `/var/log/r_orphan_cleanup/notifications` directory to permit isolated process workers to write local execution logs securely before termination.

## Operations and Logs

### Viewing Logs

The cleanup activities are logged cleanly per process format:

```bash
# Real-time termination logs
tail -f /var/log/r_orphan_cleanup/cleanup.log

# 2026-02-17 10:30:05 | KILLED | type=parallel::PSOCK | user=martina.livornese2 | pid=1581093
# 2026-02-17 10:35:02 | SUMMARY | Orphans killed this run: 2
```

### Manual Execution

While governed by the `/etc/cron.d/` schedules, administrators can invoke these scripts manually at any time without parameters:

```bash
# Force a sweep of all detached orphan parallel executions immediately:
sudo /etc/biome-calc/script/cleanup_r_orphans.sh

# Force dispatching user-level breakdown emails of terminated jobs immediately:
sudo /etc/biome-calc/script/notify_r_orphans.sh

# Generate a unified sysadmin health report and send it to all admins in admin_recipients.txt:
sudo /etc/biome-calc/script/r_orphan_report.sh
```

## Legacy Support Notes

If integrating with strict external mailing platforms like Microsoft Teams groups (e.g., `Lifewatch_Biome_internal@live.unibo.it`), external senders inherently trigger rejection traps. The `admin_recipients.txt` design mitigates this by allowing discrete target broadcasting, but administrators can alternatively whitelist the BIOME-CALC sender natively within the M365 console.
