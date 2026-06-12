<!-- docs/operations/NGINX_AUTH_PAM_REGRESSION_2026-06.md -->
# Nginx auth_pam Regression — June 2026

> **Audience:** sysadmins / on-call.  
> **Tier:** T1 host.  
> **Last updated:** 2026-06-09.  
> **Status:** RESOLVED — nginx packages pinned to known-good version.

## Symptom

Nginx worker processes crash with SIGSEGV (signal 11) when the portal
login flow calls `/auth-check` (which uses `auth_pam`). The crash
manifests as:

```text
2026/06/09 14:27:09 [alert] 460017#460017: worker process 489900 exited on signal 11 (core dumped)
```

Kernel logs show segfaults in three locations:

```text
ngx_http_auth_pam_module.so
nginx
libc.so.6
```

The portal itself loads correctly; only the PAM-authenticated
`/auth-check` endpoint triggers the crash.

## Root cause

Ubuntu `unattended-upgrades` moved nginx from:

```text
nginx 1.24.0-2ubuntu7.9
```

to:

```text
nginx 1.24.0-2ubuntu7.10
```

while `libnginx-mod-http-auth-pam` remained at:

```text
1:1.5.5-2build2
```

The `2ubuntu7.10` nginx runtime is incompatible with the unchanged
auth_pam module, causing a null-pointer dereference inside
`ngx_http_auth_pam_module.so` whenever PAM authentication is invoked.

## Secondary noise — `pam_lastlog.so` missing

The `ttyd` service and `login` both log:

```text
PAM unable to dlopen(pam_lastlog.so): /usr/lib/security/pam_lastlog.so:
cannot open shared object file: No such file or directory
```

This is **not** the cause of the nginx segfault. Working nodes
(`biome-calc04`) also lack `pam_lastlog.so` and do not crash. The
message is a cosmetic PAM session warning on Ubuntu 24.04 and can be
safely ignored.

## Node comparison (failed vs working)

| Check | Failed (`biome-calc03`) | Working (`biome-calc04`) |
|---|---|---|
| nginx version | `1.24.0-2ubuntu7.10` | `1.24.0-2ubuntu7.9` |
| nginx-common | `1.24.0-2ubuntu7.10` | `1.24.0-2ubuntu7.9` |
| nginx-full | `1.24.0-2ubuntu7.10` | `1.24.0-2ubuntu7.9` |
| libnginx-mod-stream | `1.24.0-2ubuntu7.10` | `1.24.0-2ubuntu7.9` |
| libnginx-mod-http-auth-pam | `1:1.5.5-2build2` | `1:1.5.5-2build2` |
| PAM stack (`common-auth`, `common-account`) | identical | identical |
| `www-data` in `winbindd_priv` | yes | yes |
| Winbind privileged pipe | present, accessible | present, accessible |
| `wbinfo -t` | succeeded | succeeded |
| `wbinfo -P` | succeeded | succeeded |
| `pam_lastlog.so` on disk | absent | absent |

**Conclusion:** The only meaningful difference is the nginx package
version. Samba/Winbind and PAM configuration are healthy on both nodes.

## Diagnosis commands

Run on any suspect node:

```bash
# Package drift check
dpkg -l | grep -E 'nginx|auth-pam'

# Apt history — find when the upgrade happened
sudo zgrep -hE 'nginx|libnginx-mod-http-auth-pam' /var/log/apt/history.log /var/log/apt/history.log.*.gz

# PAM stack verification
sudo bash scripts/fix_pam_segfault_inplace.sh --check

# Winbind health
wbinfo -t
wbinfo -P
id www-data
getent group winbindd_priv
ls -ld /var/lib/samba/winbindd_privileged
ls -l /var/lib/samba/winbindd_privileged/pipe

# Recent nginx segfaults
sudo journalctl -k --since "1 hour ago" --no-pager | grep -i 'nginx\|segfault'
sudo journalctl -u nginx --since "1 hour ago" --no-pager -l | grep -i 'signal 11\|core dump'
```

## Fix

### 1. Protect working nodes from the bad upgrade

```bash
# Hold nginx packages
sudo apt-mark hold nginx nginx-common nginx-full libnginx-mod-stream libnginx-mod-http-auth-pam

# Pin the bad version away — use .pref extension (NOT .10 or other invalid extension)
sudo tee /etc/apt/preferences.d/99-block-nginx-bad.pref >/dev/null <<'EOF'
Package: nginx nginx-common nginx-full libnginx-mod-stream
Pin: version 1.24.0-2ubuntu7.10
Pin-Priority: -1
EOF

# Verify
sudo apt update
sudo apt-get -s upgrade | grep -E '^Inst (nginx|nginx-common|nginx-full|libnginx-mod-stream|libnginx-mod-http-auth-pam)' \
  || echo "OK: nginx packages are not scheduled for upgrade"
```

> **Important:** APT ignores files in `/etc/apt/preferences.d/` with
> invalid extensions. Use `.pref` or no extension. The filename
> `99-block-nginx-2ubuntu7.10` is silently ignored because `.10` is
> not a recognised preferences extension.

### 2. Create known-good `.deb` packages from a working node

On the working node (`biome-calc04`):

```bash
# Install dpkg-repack if not present
sudo apt-get update
sudo apt-get install -y --no-install-recommends dpkg-repack

# Repack the installed good packages
sudo mkdir -p /root/nginx-1.24.0-2ubuntu7.9-repack
cd /root/nginx-1.24.0-2ubuntu7.9-repack
sudo dpkg-repack nginx nginx-common nginx-full libnginx-mod-stream

# Checksums
sha256sum *.deb | sudo tee SHA256SUMS

# Tarball for transfer
cd /root
sudo tar -czf nginx-1.24.0-2ubuntu7.9-repack-amd64.tar.gz nginx-1.24.0-2ubuntu7.9-repack
ls -lh /root/nginx-1.24.0-2ubuntu7.9-repack-amd64.tar.gz
```

Transfer to failed nodes:

```bash
scp /root/nginx-1.24.0-2ubuntu7.9-repack-amd64.tar.gz ladmin@biome-calc03:/home/ladmin/
```

### 3. Downgrade failed nodes

On the failed node:

```bash
# Backup nginx config
sudo cp -a /etc/nginx /root/nginx-config-backup-$(date +%Y%m%d-%H%M%S)

# Extract packages
cd /root
sudo tar -xzf nginx-1.24.0-2ubuntu7.9-repack-amd64.tar.gz
cd /root/nginx-1.24.0-2ubuntu7.9-repack

# Stop nginx
sudo systemctl stop nginx

# Install good packages (preserve local config)
sudo apt install --allow-downgrades \
  -o Dpkg::Options::=--force-confold \
  ./nginx_1.24.0-2ubuntu7.9_amd64.deb \
  ./nginx-common_1.24.0-2ubuntu7.9_all.deb \
  ./nginx-full_1.24.0-2ubuntu7.9_all.deb \
  ./libnginx-mod-stream_1.24.0-2ubuntu7.9_amd64.deb

# Hold and pin
sudo apt-mark hold nginx nginx-common nginx-full libnginx-mod-stream libnginx-mod-http-auth-pam

sudo tee /etc/apt/preferences.d/99-block-nginx-bad.pref >/dev/null <<'EOF'
Package: nginx nginx-common nginx-full libnginx-mod-stream
Pin: version 1.24.0-2ubuntu7.10
Pin-Priority: -1
EOF

# Verify
sudo nginx -t
sudo systemctl start nginx
sudo systemctl status nginx --no-pager -l
dpkg -l | grep -E 'nginx|auth-pam'
```

Expected output:

```text
nginx                       1.24.0-2ubuntu7.9
nginx-common                1.24.0-2ubuntu7.9
nginx-full                  1.24.0-2ubuntu7.9
libnginx-mod-stream         1.24.0-2ubuntu7.9
libnginx-mod-http-auth-pam  1:1.5.5-2build2
```

### 4. Verify no more segfaults

```bash
# Test portal login, then:
sudo journalctl -k --since "15 minutes ago" --no-pager | grep -i 'nginx\|segfault' \
  || echo "OK: no recent nginx kernel segfaults"
sudo journalctl -u nginx --since "15 minutes ago" --no-pager -l | grep -i 'signal 11\|core dump' \
  || echo "OK: no recent nginx worker crashes"
```

## Safe Samba/Winbind restart (secondary)

Samba/Winbind is **not** the primary cause of this incident, but if a
restart is needed for other reasons, use this order:

```bash
sudo systemctl stop nginx
sudo systemctl stop winbind smbd nmbd
sudo net cache flush
sudo systemctl start smbd nmbd winbind
sudo wbinfo -t
sudo wbinfo -P
sudo nginx -t
sudo systemctl start nginx
```

## Changelog / Incident history

| Date | Event |
|---|---|
| 2026-06-04 | Portal template commit `57f9bcecc` deployed (Wiki + LIFE4Pollinators tiles). |
| 2026-06-09 14:24 | First nginx worker segfaults observed on `biome-calc03`. |
| 2026-06-09 14:27 | `[alert] worker process exited on signal 11` in nginx error log. |
| 2026-06-09 | Diagnosis: nginx `1.24.0-2ubuntu7.10` regression with `libnginx-mod-http-auth-pam`. |
| 2026-06-09 | Fix: downgrade to `1.24.0-2ubuntu7.9` via `dpkg-repack` from `biome-calc04`. |
| 2026-06-09 | All nodes pinned: `apt-mark hold` + `/etc/apt/preferences.d/99-block-nginx-bad.pref`. |

## Cross-references

* Symptom-indexed runbook → [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) §5.5
* Maintenance runbook → [`MAINTENANCE.md`](MAINTENANCE.md) §2 (weekly nginx package drift check)
* Diagnostics index → [`DIAGNOSTICS_INDEX.md`](DIAGNOSTICS_INDEX.md) §9
* PAM hardening → [`../deployment/PAM_HARDENING.md`](../deployment/PAM_HARDENING.md)
* Nginx auth backends → [`../reference/NGINX_AUTH_BACKENDS.md`](../reference/NGINX_AUTH_BACKENDS.md)

## Tier impact

* **T1 (host):** Fix applied — nginx packages downgraded and pinned.
* **T2 (docker):** No code parity change needed. The Docker nginx image
  (`docker-deploy/Dockerfile.nginx`) uses `nginx:1.27-alpine` which is
  a different major version and does not use the Ubuntu `libnginx-mod-http-auth-pam`
  package. No action required.
* **T3 (k8s):** SKELETON_NOT_READY — deferred until T2 stable.
