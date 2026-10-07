<!-- docs/architecture/SECURITY_MODEL.md -->
---
title: "BIOME-CALC Security Model"
audience: architect
status: current
tier: T1
source_path: docs/architecture/SECURITY_MODEL.md
last_verified: 2026-10-06
sharepoint_section: Sysadmin / Operator Hub
---

# BIOME-CALC Security Model

## 1. Scope

This model describes the active T1 host implementation on 2026-10-06. T2
Docker has additional controls and an optional OIDC profile; T3 Kubernetes is
`SKELETON_NOT_READY` and is not part of the active security boundary.

## 2. Trust boundaries

| Boundary | Trusted side | Required control |
|---|---|---|
| Internet or client network → Nginx | Nginx TLS endpoint | Only Nginx exposes the web application on ports 80/443 |
| Nginx → RStudio | Host loopback `127.0.0.1:8787` | RStudio binds to loopback; Nginx supplies proxy and origin headers |
| Nginx → ttyd | Host loopback `127.0.0.1:2222` | Nginx authenticates with PAM before setting `X-Forwarded-User` |
| Nginx → telemetry | Host loopback `127.0.0.1:8000` and `:9100` | Public and restricted routes are separated in the Nginx template |
| Host → Active Directory | PAM, NSS, Kerberos through SSSD **or** Samba/Winbind | Only one AD backend may be active on a host |
| Compute node → persistent storage | NFSv4.2 `sec=sys` and CIFS mounts | Identity mapping, mount permissions, and server-side ZFS quotas |
| R user → host resources | systemd `user-.slice` and R runtime guards | Per-user memory, task, CPU-weight, and I/O-weight controls |

The Nginx-to-ttyd header is a security assertion, not informational metadata.
Direct access to ttyd would let a client provide its own identity header.
Loopback binding and firewall policy must therefore prevent bypass of Nginx.

## 3. Active T1 authentication flows

### 3.1 Portal and terminal

The active T1 portal uses an AD credential modal and HTTP Basic validation:

```text
Browser credential modal
  → GET /auth-check with Authorization: Basic ...
  → Nginx ngx_http_auth_pam_module
  → PAM service nginx
  → common-auth/common-account
  → SSSD or Samba/Winbind
```

`/terminal/` and `/terminal-inner/` are also protected by `auth_pam`.
After PAM succeeds, Nginx sets `X-Forwarded-User`; ttyd passes that value to
`ttyd_login_wrapper.sh`, which executes `/bin/login -f` for the resolved
identity.

The terminal uses a browser-cached Basic credential. The portal currently
rewrites the terminal link as `https://user:password@host/terminal/` after
validation. That URL is created in browser memory but can be exposed to
browser history, extensions, diagnostics, or downstream tooling. It is an
active risk, not a legacy note.

### 3.2 RStudio

The portal POSTs the username and password to
`/rstudio-inner/auth-do-sign-in`. Nginx proxies that private RStudio endpoint
to `127.0.0.1:8787`; RStudio then authenticates through PAM service `rstudio`.
The RStudio PAM service includes `common-auth`, `common-account`,
`common-password`, and `common-session`.

The browser generates a CSRF value, stores it in `localStorage`, writes the
`csrf-token` and `rs-csrf-token` cookies under `/rstudio-inner/`, and submits
the token in the login body. Nginx forces `Origin` and `Referer` values on the
RStudio proxy and keeps `www-enable-origin-check=1` enabled in RStudio.

The password is transmitted only inside TLS when clients use the documented
HTTPS entry point, but it exists in portal JavaScript and in the POST body.
The T1 source contains no oauth2-proxy layer that removes this handling.

### 3.3 Nextcloud

The same portal function attempts a direct login to the configured Nextcloud
backend under `/files-inner/`. It first requests a CSRF token, then POSTs the
username and password to the backend login endpoint. Nginx proxies the
external backend and sets forwarding headers.

**Unverified:** repository code cannot establish whether the configured
site-specific Nextcloud endpoint is deployed, which Nextcloud version it
runs, or whether its login endpoint remains compatible with this flow.

### 3.4 OIDC status

oauth2-proxy v7.6.0-alpine is present only in T2 as the optional Compose
profile `oidc` on port 4180. The T1 Nginx templates do not contain
`auth_request`, `/oauth2/`, or an oauth2-proxy upstream. Describing T1 as
OIDC-protected would be incorrect.

## 4. Network exposure

| Listener or route | Intended exposure | Code state |
|---|---|---|
| Nginx `:80` | Network-facing | Redirect to HTTPS, except ACME challenge |
| Nginx `:443` | Network-facing | TLS portal and reverse proxy |
| RStudio `127.0.0.1:8787` | Loopback only | Set by `configure_rstudio.vars.conf` and `20_configure_rstudio.sh` |
| ttyd `127.0.0.1:2222` | Loopback only | Set by `install_nginx.vars.conf` and ttyd override template |
| Telemetry `127.0.0.1:8000` | Loopback backend | `/api/` and `/metrics` are exposed through the public TLS vhost; `/monitoring/` is LAN/VPN restricted |
| Node exporter `127.0.0.1:9100` | Loopback backend | Exposed only through the restricted `/monitoring/node/` route |
| Ollama `127.0.0.1:11434` | Loopback only | Used by local R helpers |
| OAuth2 Proxy `127.0.0.1:4180` | T2 only | Optional `oidc` profile |
| Docker API proxy `127.0.0.1:2375` | T2 only | Bridge service published on loopback; only it mounts `docker.sock` |

The `/metrics` route is public in the active T1 template despite comments that
describe it as an API-docs and Prometheus endpoint. It is GET-only and
rate-limited, but it is not restricted by an allow-list.

## 5. TLS and cookies

`scripts/30_install_nginx.sh` supports `SELF_SIGNED` and `LETS_ENCRYPT` modes.
`scripts/32_setup_letsencrypt.sh` manages the Let's Encrypt path. T1 has no
active Step-CA enrollment flow.

RStudio is configured with:

- `auth-cookies-force-secure=1`;
- `www-same-site=none`;
- `www-frame-origin=same`;
- `www-enable-origin-check=1`;
- `auth-encrypt-password=0`, relying on Nginx TLS for transport protection.

Nginx removes RStudio's `X-Frame-Options` response header for the wrapper and
sets `Secure; SameSite=None` on proxied cookies. The wrapper model therefore
depends on the same-origin TLS gateway remaining the only path to RStudio.

**Unverified:** the repository cannot prove which certificate mode is active
on deployed hosts or whether managed clients trust the current certificate
chain.

## 6. Identity and storage controls

- SSSD and Samba/Winbind are mutually exclusive T1 choices.
- NFS homes are served from TrueNAS SCALE dataset `zpool/home` over NFSv4.2
  with `sec=sys`; authorization therefore depends on consistent numeric
  UID/GID mapping between AD, the clients, and TrueNAS.
- Per-user ZFS quotas are enforced on TrueNAS. A client can have free
  filesystem space and still receive `EDQUOT`.
- CIFS project storage is mounted at `/mnt/ProjectStorage`.
- R temporary files use local `/Rtmp`; persistent user data remains on NFS.
- Per-user compiled R libraries default to local
  `/var/lib/biome-Rlibs/<user>/<R-ver>/`, with the NFS library retained as a
  fallback.

## 7. Resource isolation

T1 installs a systemd `user-.slice` policy with these configured values:

| Control | Value |
|---|---:|
| `MemoryHigh` | 300 GiB |
| `MemoryMax` | 400 GiB |
| `MemorySwapMax` | 4 GiB |
| `TasksMax` | 4096 |
| `CPUWeight` | 100 |
| `IOWeight` | 100 |

The system slice has a 16 GiB hard memory floor, a 24 GiB soft floor, and CPU
weight 200. Ollama uses CPU weight 80. Rprofile 12.10 adds cgroup-aware core
and memory guards, but these do not replace kernel enforcement.

## 8. Secrets and site configuration

Tracked files contain placeholders only. Site-local AD topology, mail values,
contacts, and related PII are loaded from gitignored `config/site/` overlays.
`lib/common_utils.sh` provides `resolve_site_config` and
`assert_site_configured` and rejects the `__FILL_ME__` sentinel.

Passwords must be written to files rather than passed in command-line
arguments. `.env` files are not committed, except the documented sandbox
example containing test-only values. The sandbox itself is known broken.

## 9. Current control gaps

The following are visible in active source and must not be described as fixed:

1. The T1 browser handles AD passwords for RStudio, terminal, and Nextcloud.
2. The terminal tile places credentials in a URL.
3. T1 has no oauth2-proxy integration despite OIDC being present in T2.
4. `portal_index.html.template` loads Google Fonts, violating HC-11.
5. `ttyd_login_wrapper.sh` has strict mode commented out and logs all
   environment variables, which can disclose session context in its log.
6. `20_configure_rstudio.sh` has strict mode commented out.
7. Nginx's public `/metrics` route is not LAN/VPN restricted.
8. The active Nginx template forces Origin and Referer values for the RStudio
   proxy; its security depends on RStudio remaining loopback-only.

## 10. T2 and T3 security posture

T2 adds pinned images, per-container CPU/memory limits, bind mounts, optional
OIDC, Step-CA trust bootstrap, health checks, and a loopback-only Docker API
proxy. It remains `MIGRATION_IN_PROGRESS` and has the recorded R-runtime parity
gap `TD-T2-01`.

T3 has NetworkPolicies after the 2026-10-01 back-port, but remains
`SKELETON_NOT_READY`; `.ai/project.yml` still lists missing production
controls and identity/storage blockers. Kubernetes manifests are not evidence
that those controls are active in T1.

## 11. Verification sources

- `templates/portal_index.html.template`
- `templates/nginx_site.conf.template`
- `templates/nginx_proxy_location.conf.template`
- `templates/ttyd.service.override.template`
- `scripts/03_install_secure_access.sh`
- `scripts/20_configure_rstudio.sh`
- `scripts/30_install_nginx.sh`
- `scripts/40_install_telemetry.sh`
- `scripts/ttyd_login_wrapper.sh`
- `config/install_nginx.vars.conf`
- `config/configure_rstudio.vars.conf`
- `config/setup_nodes.vars.conf`
- `docker-deploy/docker-compose.yml`
- `.ai/project.yml`

---

*Authoritative source: [`docs/architecture/SECURITY_MODEL.md`](https://github.com/gsamuele78/R-studioConf/blob/main/docs/architecture/SECURITY_MODEL.md) — last verified 2026-10-06. The Markdown file in git is the source of truth.*
