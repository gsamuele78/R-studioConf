<!-- docs/operations/TROUBLESHOOTING.md -->
# Troubleshooting Runbook (Symptom → Action)

> **Audience:** sysadmins / operators on call.  
> **Tier:** T1 host. T2/T3 mirror unless noted.  
> **Last updated:** 2026-05-09.

This is the canonical first stop when something is wrong. It is indexed
by **symptom** (what the user/operator sees), not by component. For
every entry: → first command, → diagnostic script, → remediation, →
escalation doc.

For the full taxonomy of diagnostic scripts (the `99_*.sh` family),
see [`DIAGNOSTICS_INDEX.md`](DIAGNOSTICS_INDEX.md).

---

## 0. Always-first commands

```bash
# Snapshot of every BIOME service:
systemctl is-active rstudio-server nginx ttyd botanical-telemetry sssd smbd winbind 2>/dev/null

# One-shot health check:
sudo bash scripts/99_health_check.sh

# Aggregate diagnostic dump (env + logs + AD reachability):
sudo bash scripts/99_troubleshoot_env.sh --rprofile
```

If those three return clean output, the problem is almost always
user-side or network-side. Otherwise jump to the matching section
below.

---

## 1. RStudio session / R runtime

### 1.1 RStudio login loop / "session failed to start"

**First commands**

```bash
journalctl -u rstudio-server -n 200 --no-pager
ls -la /var/log/rstudio-server/
sudo cat /var/log/rstudio-server/rserver.log | tail -100
```

**Diagnostic**

```bash
sudo bash scripts/test_rstudio_login.sh        # interactive PAM smoke test
sudo bash scripts/99_verify_domain_join.sh     # if user is AD-resolved
```

**Likely causes / fixes**

| Symptom | Fix |
|---|---|
| `pam_unix(rstudio:auth): authentication failure` for AD user | SSSD/Samba down — see §3. |
| `chmod 700 ~/.local/share/rstudio` errors | NFS home not mounted — see §4.2. |
| `rsession exited with code 139` (SIGSEGV) | OpenBLAS-pthread regression — see §1.3. |
| Login works but session never reaches IDE | Browser CSP / nginx mis-proxy — see §5.2. |

### 1.2 R session SIGSEGV mid-script

**First commands**

```bash
ldd /usr/lib/R/lib/libRblas.so | grep openblas
# expected: libopenblas.so.0 -> libopenblas-serial.so.* (NOT pthread)
```

**Diagnostic**

```bash
sudo bash scripts/99_postmortem_forensics.sh --user <username> --hours 2
```

**Fix.** Re-run `scripts/50_setup_nodes.sh` — its BLAS step pins
`libopenblas0-serial` and runs `update-alternatives` to the serial
variant. Do NOT install `libopenblas0-pthread`. (HR-15 / R-runtime hard rule.)

→ Escalation: [`USER_SCRIPT_TROUBLESHOOTING.md`](USER_SCRIPT_TROUBLESHOOTING.md), [`sysadmin_troubleshooting_guide.md`](sysadmin_troubleshooting_guide.md).

### 1.3 R script hangs (Lussu-style)

Symptom: long-running `mclapply` over `terra::rast` stalls indefinitely;
`top` shows N forked rsession workers all at 100% CPU.

```bash
# Reproduce + isolate (does NOT touch the user's .R):
sudo bash scripts/99_diagnose_lussu_hang.sh --user <username> --script /path/to/user.R
```

The harness reports which probe (E PSOCK swap / F terra todisk) makes
the hang go away. **Since Rprofile v12.4 both probes are fixed by default**:

* `templates/Rprofile_site.d/52_mclapply_guard.R.template` reroutes
  `parallel::mclapply` to PSOCK whenever a heavy-thread package
  (`terra`/`sf`/`raster`/`stars`/`torch`/`arrow`) is loaded.
* `templates/Rprofile_site.d/50_pkg_hooks.R.template` enables
  `terraOptions(memfrac=0.5, todisk=TRUE)` on first `library(terra)`.

If a node still hangs, verify the v12.4 deploy on it
(`sudo bash scripts/50_setup_nodes.sh --verify` → expect
`Rprofile.site version: 12.4`) and re-run `50_setup_nodes.sh` (option `1`
or surgical option `3` = config files only).

Per-user emergency bypass: `BIOME_DISABLE_FORK_GUARD=1` /
`BIOME_TERRA_NORAM=1`.

→ Deep-dive: [`LUSSU_HANG_BISECTION.md`](LUSSU_HANG_BISECTION.md),
  upgrade procedure: [`UPGRADE_TO_v12.4.md`](UPGRADE_TO_v12.4.md).

### 1.4 `cannot allocate vector of size …` / OOM kill

**First**

```bash
dmesg | grep -iE 'oom|killed process'
df -h /Rtmp
```

**Fix paths**

* If `/Rtmp` is full → see §4.1.
* If RAM cap reached → check user cgroup quota in
  `templates/Rprofile_site.d/45_memory_guards.R.template`. Adjust
  via `setup_nodes.vars.conf` and re-run `50_setup_nodes.sh`.
* If user code is genuinely demanding too much → escalate per
  [`USER_QUOTAS_AND_RESOURCES.md`](USER_QUOTAS_AND_RESOURCES.md).

### 1.5 Suspect package drift between nodes

```bash
sudo bash scripts/99_check_pkg_drift.sh
```

Non-zero exit = drift detected. Re-run `r_env_manager.sh` to bring
baseline R packages into sync; or rebuild the affected node from a
clean baseline ([`CLEAN_VM_BASELINE.md`](CLEAN_VM_BASELINE.md)).

### 1.6 Reproducing under a forensic profile

If you need to prove "it's not the dispatcher / fragments":

```bash
# Pure R, no /etc/R/Rprofile.site dispatcher, NO Rprofile_site.d/:
r_minimal -e 'sessionInfo()'

# Run a user script under the minimal profile:
r_minimal_rscript /path/to/user.R
```

This is the L0/L1 surface in the HC-13 escalation ladder.

---

## 2. PAM / `passwd` / login

### 2.1 `passwd` segfaults for local user (uid<10000)

This is the canonical PAM bug on AD-joined Ubuntu 24.04 nodes.

```bash
sudo bash scripts/fix_pam_segfault_inplace.sh --check    # diagnose only
sudo bash scripts/fix_pam_segfault_inplace.sh            # apply fix
```

→ Full story: [`../deployment/PAM_HARDENING.md`](../deployment/PAM_HARDENING.md).

### 2.2 AD user can't log in (RStudio or SSH)

```bash
sudo bash scripts/99_verify_domain_join.sh
realm list
id <ad-user>                  # should resolve
kinit <ad-user>@<REALM>       # should succeed
sudo journalctl -u sssd -n 100 --no-pager   # or smbd/winbind
```

**Likely causes**

* Clock skew >5 min → re-run `02_configure_time_sync.sh`.
* SSSD/Winbind cache corruption → `sudo systemctl restart sssd` (or
  `winbind` + `smbd`); if still broken, `sudo sss_cache -E`.
* AD machine account expired → re-run the join script (idempotent).

### 2.3 Local user can't `sudo` after AD join

Usually `/etc/pam.d/sudo` was rewritten and lost the local-user branch.
Fix by re-running `13_harden_pam_password.sh`, which restores the
default Debian stack.

---

## 3. Identity backend (SSSD / Samba / Kerberos)

### 3.1 SSSD will not start

```bash
sudo journalctl -u sssd -n 200 --no-pager
sudo sss_cache -E
sudo systemctl restart sssd
```

If config is corrupt, re-render it: `sudo bash scripts/10_join_domain_sssd.sh`
(idempotent — re-renders `/etc/sssd/sssd.conf` from
`templates/sssd.conf.template`).

### 3.2 Winbind/Samba — domain rejoin needed

After AD machine-password rotation:

```bash
sudo bash scripts/11_join_domain_samba.sh    # idempotent rejoin
sudo systemctl restart winbind smbd
```

Sanity: `wbinfo -t` (trust check) and `wbinfo -u | head` (users visible).

### 3.3 Kerberos `kinit` fails everywhere

```bash
chronyc tracking            # clock skew must be <5 min
cat /etc/krb5.conf          # verify multi-realm block intact
sudo bash scripts/12_lib_kerberos_setup.sh   # re-render krb5.conf
```

---

## 4. Storage (`/Rtmp`, NFS home, archive)

### 4.1 `/Rtmp` is full

```bash
df -h /Rtmp
sudo du -sh /Rtmp/*/ | sort -h | tail -20
```

If a single user owns most of it, run the orphan cleanup early:

```bash
sudo /etc/biome-calc/script/cleanup_r_orphans.sh --dry-run
sudo /etc/biome-calc/script/cleanup_r_orphans.sh
```

If `/Rtmp` itself is undersized, expand the underlying virtio disk
**without rebooting** per [`add_storage_no_reboot.md`](add_storage_no_reboot.md).

### 4.2 NFS home not mounted

```bash
mount | grep <NFS_HOME>
sudo systemctl status remote-fs.target
sudo systemctl restart autofs   # if autofs is the mounter
```

If the NFS server is unreachable, the user gets `~` = `/`. Fail-fast:
RStudio refuses to launch in that condition (by design).

### 4.3 CIFS archive offline

`templates/unibo_archive_manager.sh.template` (deployed as
`/etc/biome-calc/script/unibo_archive_manager.sh`) handles re-mount.
Logs in `${ARCHIVE_LOG_DIR}` from `setup_nodes.vars.conf`.

---

## 5. Nginx / portal / SSL

### 5.1 502 Bad Gateway

```bash
sudo tail -100 /var/log/nginx/error.log
sudo nginx -t
ss -ltnp | grep -E '8787|7681|8080'   # rstudio / ttyd / nextcloud
```

**Cause matrix**

| Upstream down | First action |
|---|---|
| RStudio (8787) | `systemctl restart rstudio-server` |
| ttyd (7681) | `systemctl restart ttyd` |
| Nextcloud (whatever `NEXTCLOUD_TARGET_URL` is) | check the upstream host (out of scope per HR-4 — Nextcloud is a separate project) |
| Telemetry (8000) | `systemctl restart botanical-telemetry` |

### 5.2 Portal loads but RStudio iframe is blank / CSP error

Browser console will show `Refused to frame ... CSP frame-ancestors`.
Fix: re-render proxy-location template:

```bash
sudo bash scripts/update_nginx_templates.sh
sudo systemctl reload nginx
```

The RStudio `frame-ancestors` directive lives in
`templates/nginx_proxy_location.conf.template`.

### 5.3 Let's Encrypt renewal failed

```bash
sudo certbot renew --dry-run
sudo journalctl -u certbot.timer -n 50 --no-pager
sudo bash scripts/32_setup_letsencrypt.sh   # menu: status/renew
```

Common cause: Nginx `/.well-known/acme-challenge/` location got removed
during a config edit. Re-render templates with
`update_nginx_templates.sh`.

### 5.4 Nginx temp directory bloat

The daily cron from `15_setup_nginx_cleanup.sh` should keep this in
check. If it's been disabled:

```bash
sudo bash scripts/15_setup_nginx_cleanup.sh   # re-installs cron
```

---

## 6. Telemetry & status panel

### 6.1 Status panel shows "telemetry offline"

```bash
systemctl status botanical-telemetry
journalctl -u botanical-telemetry -n 100 --no-pager
curl -s http://127.0.0.1:8000/health
```

If the venv is broken, re-run `40_install_telemetry.sh` (idempotent —
recreates `/opt/botanical-telemetry/`).

### 6.2 Strip is missing on the portal

Check `INCLUDE_TELEMETRY_STRIP` flag at the top of
`scripts/31_setup_web_portal.sh`. Set to `true`, re-run, reload Nginx.

---

## 7. ttyd terminal

### 7.1 ttyd 403 / login refuses

```bash
journalctl -u ttyd -n 100 --no-pager
sudo tail -50 /var/log/secure_access/ttyd.log
```

The wrapper at `/usr/local/bin/ttyd_login_wrapper.sh` resolves the
username and authenticates via PAM. If the PAM stack itself is broken,
it shows up here too — resolve §2 first.

---

## 8. R-environment manager (`r_env_manager.sh`)

### 8.1 "Another instance is running"

```bash
cat /var/run/r_env_manager.sh.pid 2>/dev/null
ls /var/run/r_env_manager.sh.lock
```

If no live process matches the PID:

```bash
sudo rm /var/run/r_env_manager.sh.lock /var/run/r_env_manager.sh.pid
```

### 8.2 Restoring a previous config snapshot

`r_env_manager.sh` rotates rserver.conf / sssd.conf / nginx vhosts to
`/var/backups/r_env_manager/files/`. To roll back:

```bash
ls -lt /var/backups/r_env_manager/files/ | head
sudo cp /var/backups/r_env_manager/files/etc/rstudio/rserver.conf.<timestamp> \
        /etc/rstudio/rserver.conf
sudo systemctl restart rstudio-server
```

---

## 9. When to escalate (and to whom)

| Situation | Doc |
|---|---|
| User says "it crashed", you have no logs | [`sysadmin_troubleshooting_guide.md`](sysadmin_troubleshooting_guide.md) |
| User script reproduces only on one machine | [`USER_SCRIPT_TROUBLESHOOTING.md`](USER_SCRIPT_TROUBLESHOOTING.md) |
| Lussu-class hang in `mclapply` over `terra` | [`LUSSU_HANG_BISECTION.md`](LUSSU_HANG_BISECTION.md) |
| You suspect a fragment regression after Rprofile edit | [`../reference/Rprofile_site.CHANGELOG.md`](../reference/Rprofile_site.CHANGELOG.md) + [`USER_SCRIPT_TROUBLESHOOTING.md`](USER_SCRIPT_TROUBLESHOOTING.md) |
| User is hitting cgroup limits | [`USER_QUOTAS_AND_RESOURCES.md`](USER_QUOTAS_AND_RESOURCES.md) |
| You need a clean repro environment | [`CLEAN_VM_BASELINE.md`](CLEAN_VM_BASELINE.md) |
| Routine maintenance / R bump | [`MAINTENANCE.md`](MAINTENANCE.md) |
| Where to find logs | [`diagnostic_logs.md`](diagnostic_logs.md) |
| Diagnostic script reference | [`DIAGNOSTICS_INDEX.md`](DIAGNOSTICS_INDEX.md) |

---

## 10. Don't do this (HR enforcement)

* Do **not** install `libopenblas0-pthread` "to speed up R" — it
  reintroduces the SIGSEGV.
* Do **not** add a custom PAM profile to "guard local users". The
  default Debian stack is correct on 24.04 — see
  [`PAM_HARDENING.md`](../deployment/PAM_HARDENING.md).
* Do **not** patch a user's `.R` file to make a hang go away. That
  violates HC-13 / HR-17. Adapt the system instead.
* Do **not** point R `TMPDIR` back at `/tmp`. Use `/Rtmp`.
* Do **not** edit `templates/Rprofile_site.R.template_v11.*` — those
  are forensic snapshots. Edit `Rprofile_site.R.template` and the
  `Rprofile_site.d/*.R.template` fragments only.
