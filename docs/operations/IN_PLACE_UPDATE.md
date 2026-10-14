# In-place update of a live T1 host (`scripts/update_host.sh`)

> Implements [ADR-0003](../adr/0003-in-place-host-update-and-hotfix-contract.md)
> (proposed in PR #31). Production runs on the T1 host; this is how a host moves
> to newer code **without reinstalling** and without ending RStudio sessions.

## What it manages today

| Component | Files | Validator (before the service sees them) | Service action |
|---|---|---|---|
| `nginx` | `/etc/nginx/templates/nginx_{ssl_params,ssl_certificate,performance,proxy_location}.conf`, `/etc/nginx/sites-available/<DOMAIN_OR_IP>.conf` | `nginx -t` | `systemctl reload nginx` |

`rstudio-server` is **never** restarted by the tool. SSSD, Samba, PAM and
Kerberos are out of scope until each has its own validator and a VM test.

`scripts/update_nginx_templates.sh` is **deprecated** by this tool and stays only
until `update_host.sh` has run on a canary host (ADR-0003 §5). The old script has
no backup, leaves a broken config on disk when `nginx -t` fails, and restarts
`rstudio-server`, ending every session.

## Modes

| Command | Effect | Exit |
|---|---|---|
| `sudo scripts/update_host.sh` (= `--plan`) | Render from this checkout, diff with the deployed files. **Writes nothing.** | 0 nothing to do · 10 changes pending · 1 error |
| `sudo scripts/update_host.sh --apply` | Backup + journal, atomic swap, `nginx -t`, reload. If `nginx -t` fails, the previous files are restored and nginx is **not** reloaded. | 0 applied or nothing to do · 1 failed (old files back) · 3 precondition |
| `sudo scripts/update_host.sh --rollback <journal>` | Restore every file of that run, verify the original `sha256`, reload nginx. | 0 · 1 mismatch |
| `sudo scripts/update_host.sh --status` | Print `/etc/biome-calc/release.json`. | 0 |

Rules the tool enforces:

- `--apply` refuses a checkout that is not exactly at a release tag (or has local
  changes) unless `--allow-untagged` is given. Use that flag **only on the test host**.
- One update or hotfix at a time (`flock` on `/run/lock/biome-calc-update.lock`).
- A rendered file with an unreplaced `%%PLACEHOLDER%%`, or `DOMAIN_OR_IP` still at
  `your_domain_or_ip`, stops the run before anything is touched.
- Local edits under `config/` (the site values in the vars files) do not count
  as "dirty"; edits to scripts, `lib/` or `templates/` do. If `git checkout <tag>`
  refuses because the tag also changed a vars file you edited, merge that file by
  hand first: never discard the site values.
- Requires `jq` (`apt-get install jq`).

Where things are written:

| Path | Content |
|---|---|
| `/var/backups/biome-calc/update-<UTC>-<pid>/manifest.tsv` | file, existed, mode, owner, sha256 before, sha256 after |
| `/var/backups/biome-calc/update-…/files/<path>` | byte copy of every file before it was replaced |
| `/etc/biome-calc/release.json` | tag, commit, time and journal of the last apply, per component; hotfix history |
| journald, tag `biome-calc` | every plan/apply/rollback line: `journalctl -t biome-calc` |

## Test-host procedure (L2/L3 evidence, ADR-0002)

Run on the **test host only**. Every step says what to record; the numbers go in
the PR as baseline → result.

**0. Preconditions**

```bash
sudo apt-get install -y jq
cd /path/to/R-studioConf            # the checkout the installer was run from
git status --short config/          # site values live here or in config/site/
git fetch origin && git checkout <commit of the PR>
```

**1. Plan (read-only) — baseline of drift**

```bash
sudo scripts/update_host.sh --plan | tee /root/uh-plan-1.txt; echo "exit=$?"
```

Record: exit code, number of `CHANGED`/`NEW` files. A `CHANGED` file is drift
between the host and the code (a hand fix, or a template change never deployed).
Read the diff before going on: it is exactly what `--apply` will write.

**2. Apply — with users connected if possible**

```bash
rstudio-server active-sessions | tail -n +2 | wc -l          # sessions before
curl -sk -o /dev/null -w '%{http_code}\n' https://localhost/  # portal before
time sudo scripts/update_host.sh --apply --allow-untagged; echo "exit=$?"
rstudio-server active-sessions | tail -n +2 | wc -l          # sessions after
curl -sk -o /dev/null -w '%{http_code}\n' https://localhost/  # portal after
```

Record: duration, sessions before/after (target: equal, M5), HTTP code before/after.

**3. Idempotence (M3)**

```bash
sudo scripts/update_host.sh --apply --allow-untagged   # expect "nothing to apply"
sudo scripts/update_host.sh --plan; echo "exit=$?"     # expect exit=0
```

**4. Rollback (M4)**

```bash
J=$(sudo jq -r .journal /etc/biome-calc/release.json)
sudo scripts/update_host.sh --rollback "$J"; echo "exit=$?"   # verifies sha256 itself
sudo scripts/update_host.sh --plan > /root/uh-plan-2.txt; diff /root/uh-plan-1.txt /root/uh-plan-2.txt && echo "back to the step-1 state"
```

Then apply again (step 2) to leave the host on the new code.

**5. Guard: a broken template must not reach nginx**

```bash
cp -a . /tmp/rc-broken
echo 'this_is_not_a_directive;' >> /tmp/rc-broken/templates/nginx_performance.conf.template
sudo /tmp/rc-broken/scripts/update_host.sh --apply --allow-untagged; echo "exit=$?"   # expect exit=1
sudo nginx -t && sudo scripts/update_host.sh --plan; echo "exit=$?"                   # expect nginx OK and exit=0
rm -rf /tmp/rc-broken
```

**6. Audit trail**

```bash
journalctl -t biome-calc --since today --no-pager
sudo scripts/update_host.sh --status
```

### Metrics to report

| ID | Metric | Target | Result on test host |
|---|---|---|---|
| — | Files in drift at step 1 | (baseline) | |
| M3 | Files changed by the second `--apply` | 0 | |
| M4 | Rollback restores every original sha256 | yes | |
| M5 | RStudio sessions ended by the update | 0 | |
| Guard | Broken template: exit 1, `nginx -t` OK, plan 0 diff afterwards | yes | |
| — | Duration of `--apply` | (baseline) | |

## Known issue found while building this (not changed here)

`config/configure_rstudio.vars.conf` sets `RSESSION_TIMEOUT_MINUTES="2880" # e.g., 2 days`.
The installer reads that line with `cut | tr`, which keeps the comment, so the
value is not a number and the nginx proxy timeout silently falls back to
7 days (604800 s). The renderer keeps that behaviour on purpose, so an existing
host plans 0 diff. Fixing it would shorten the proxy timeout from 7 days to 2,
which changes what researchers see; it needs a decision and its own PR.
