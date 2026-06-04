<!-- docs/architecture/rstudio_cluster_evolution_pki_iam_ood.md -->
# RStudio Cluster Evolution — PKI, IAM, Open OnDemand, Container, Positron

**Purpose:** Honest, pessimistic system-design analysis of architectural options for evolving the current R-studioConf RStudio Server OSS deployment toward a multi-node, trusted-TLS, identity-aware research platform.

**Date:** 2026-06-04
**Author:** System Engineer / IT Officer
**Project:** R-studioConf v3.0.0 + Infra-Iam-PKI v3.1.0
**Ethos:** "State unknowns as unknowns; never invent confidence. Pessimistic defaults. T1 (host) authoritative & continuously fixed; T2/T3 mirror T1."

---

## 1. Executive Verdict

| Question | Answer |
|---|---|
| Should we integrate Step-CA (infra-pki)? | **Yes, immediately.** It removes the self-signed certificate fragility that destabilizes RStudio cookies, WebSockets, and future SSO. |
| Should we integrate Keycloak/IAM? | **Yes, but as portal-level SSO first.** Transparent SSO into RStudio OSS is high-risk and must be a POC, not a promise. |
| Does Open OnDemand replace the need for a custom gateway? | **No, for simple user→node routing.** **Yes, for a true HPC multi-app portal.** |
| Should we migrate to containers (infra-rstudio)? | **Not now.** T1 is authoritative; T2 is migration-in-progress. First stabilize T1 + PKI, then port forward. |
| Should we use Positron? | **Not now.** Positron is officially `EVALUATION_PENDING` in this project. It does not fix the immediate certificate/routing problem. |
| Does a user need multiple simultaneous RStudio IDE sessions? | **Not achievable with RStudio OSS.** This requires Posit Workbench (commercial) or a dedicated per-session containerization project. |

---

## 2. Current State (Baseline)

### 2.1 R-studioConf T1 Host

```text
T1_host = AUTHORITATIVE_CONTINUOUSLY_FIXED
RStudio Server OSS = PAM/SSSD or Samba/Winbind
RStudio listens on 127.0.0.1:8787
www-root-path = /rstudio-inner
www-same-site = none
auth-cookies-force-secure = 1
auth-encrypt-password = 0 (behind Nginx TLS)
www-enable-origin-check = 1
```

### 2.2 Nginx Reverse Proxy

```text
nginx_site.conf → proxy_pass http://127.0.0.1:8787/
nginx_proxy_location.conf → single local backend, no upstream pool
certificate mode: SELF_SIGNED or LETS_ENCRYPT
```

### 2.3 RStudio OSS hard limit

```text
One rsession process per user identity.
No server-multiple-sessions option (Pro/Workbench only).
Second browser/tab/node → reuses or disconnects existing session.
```

Documented in:

- `docs/user_guides/rstudio_session_isolation.md`
- `docs/user_guides/risposta_ricercatore_sessioni_rstudio.md`

### 2.4 Infra-Iam-PKI sibling project

| Component | Status | Purpose |
|---|---|---|
| `infra-pki` | Built (Step-CA + Postgres + Caddy) | Internal TLS and SSH certificate authority |
| `infra-iam` | Built (Keycloak + Postgres + Caddy) | OIDC/SAML IdP, AD federation |
| `infra-ood` | Built (Open OnDemand + Apache + PUN) | HPC web portal, interactive app launcher |
| `infra-rstudio` | Built (Dockerized RStudio + Nginx + oauth2-proxy) | Container-native RStudio pet service |

---

## 3. Step-CA Analysis

### 3.1 What Step-CA fixes TODAY

| Problem | Self-signed | Step-CA trusted |
|---|---|---|
| Browser security warnings | Always present | Removed |
| Secure cookie reliability | Fragile, browser-dependent | Stable |
| SameSite=None acceptance | May be blocked | Reliable |
| iframe/WebSocket stability | Less predictable | More deterministic |
| `curl`/`httr` HTTPS validation | Coded workarounds | Clean |
| R package HTTPS calls | May fail silently | Works |
| Keycloak/OOD integration | Need manual trust per host | One Root CA |
| Certificate renewal | Manual, error-prone | Entrypoint-based, auto |

### 3.2 What Step-CA does NOT fix

- User→node routing and assignment.
- RStudio OSS one-session-per-user limit.
- RStudio OSS SSO/OIDC injection.
- Session roaming across nodes.
- Load balancing.
- Multi-session same user.

### 3.3 Recommended Step-CA configuration (phase 1)

```text
ONE trusted FQDN:
  https://rstudio.biome.internal

Step-CA issues certificate for this FQDN.

Browser users → trusted HTTPS → RStudio Gateway/Nginx → private backend nodes
```

Do NOT expose individual node URLs to users in phase 1.

**Preferred enrollment flow (from infra-pki docs):**

```bash
# On PKI host
scripts/infra-pki/generate_token.sh
  → inputs: RStudio host FQDN
  → output: infra-rstudio_join_pki.env

# On RStudio host
scripts/infra-rstudio/configure_rstudio_pki.sh join_pki.env
  → injects CA_URL, CA_FINGERPRINT into .env

scripts/infra-rstudio/deploy_rstudio.sh
  → rstudio-init fetches Root CA
  → nginx-portal uses Root CA
  → if STEP_TOKEN set, Nginx enrolls its own TLS cert via ACME
```

For the current T1 host deployment (non-containerized), integrate by:

1. Installing Step-CA Root CA on the gateway host.
2. Using `certbot` or `acme.sh` pointed at Step-CA's ACME endpoint.
3. Configuring Nginx with the issued certificate.

**Node certificates (phase 2):**

After gateway is trusted, issue internal certs for backend nodes so the gateway can verify upstream TLS:

```text
biome-calc01.internal → 10.x.x.x
biome-calc02.internal → 10.x.x.x
biome-calc03.internal → 10.x.x.x
```

### 3.4 Cookie/TLS stability impact

Current RStudio config uses:

```text
SameSite=None
Secure cookies
auth-cookies-force-secure=1
iframe wrapper (www-frame-origin=same)
WebSocket upgrade
Origin/Referer handling
```

These require trustworthy HTTPS. Step-CA provides the missing trust foundation.

---

## 4. Keycloak/IAM Analysis

### 4.1 Good use: portal-level SSO

```text
Browser → Keycloak OIDC → authenticated portal session
Portal shows RStudio tile.
RStudio still requires PAM/SSSD login.
```

Benefits:

- Centralized login, groups, roles, AD federation.
- Consistent identity between services (portal, Nextcloud, OOD, future apps).
- Audit trail.
- MFA option.
- Reduces re-authentication friction at the portal layer.

### 4.2 High-risk use: transparent SSO into RStudio OSS

The `infra-rstudio/OVERVIEW.md` proposes:

```text
oauth2-proxy (Keycloak OIDC)
→ Nginx auth_request /oauth2/auth
→ Backend Proxy Injection
→ POST /auth-do-sign-in
→ RStudio Set-Cookie
```

This is described as:

```text
RStudio Open Source does not natively accept X-Forwarded-User headers.
The solution uses Nginx backend proxy injection.
```

Risk factors:

| Risk | Severity | Detail |
|---|---|---|
| RStudio internal endpoint dependency | HIGH | Relies on `/auth-do-sign-in` POST, which is not a public API |
| Version coupling | HIGH | Breaks on RStudio upgrade if internal behavior changes |
| CSRF token | HIGH | Injection must handle token correctly or login fails |
| Cookie path/domain | MEDIUM | Subpath `/rstudio-inner` + cookie scope must match exactly |
| Browser variation | MEDIUM | Chrome, Firefox, Edge cookie/SameSite handling differs |
| Logout | MEDIUM | Clean logout requires coordinated cookie clearing |
| Support complexity | HIGH | Hard to triage without RStudio vendor support |

**Recommendation:** Do NOT promise this to users until a strict POC passes:

```text
✅ Firefox ESR
✅ Chrome stable
✅ Edge (if used)
✅ fresh login
✅ stale cookie
✅ logout
✅ idle session resume
✅ forced node reassignment
✅ RStudio upgrade test
✅ rollback plan
```

Until then, keep RStudio OSS native PAM login.

---

## 5. Open OnDemand Analysis

### 5.1 What OOD provides

From `infra-ood/OVERVIEW.md`:

```text
Apache frontend
→ mod_auth_openidc (Keycloak)
→ Per-User NGINX (PUN)
→ reverse proxy to interactive apps
```

OOD handles:

- Central authentication.
- App launch dashboard.
- Per-user proxy isolation.
- Session management.
- HPC scheduler integration (future).
- Custom BiGeA themed UI.

### 5.2 Is OOD required for user→node routing?

**No, not for simple distribution.**

A custom gateway with these features is sufficient:

```text
user assignment store (SQLite or JSON + jq + flock)
node health check (rstudio-server status, load, memory, /Rtmp)
sticky routing cookie (biome_rstudio_node = biome-calc02)
server-side authority (cookie is hint, not trust)
drain/reassign admin commands
```

OOD is overkill if the problem is only:

```text
certificates + sticky user→node RStudio routing
```

### 5.3 When OOD makes sense

Adopt OOD when you want:

```text
True HPC web portal
Multiple interactive apps (RStudio, Jupyter, terminal, desktop)
Per-user resource isolation
Managed app launch/lifecycle
Integration with SLURM/Torque/scheduler
Standard HPC center UX
```

OOD + Step-CA + Keycloak is a strong long-term path, but deploy in phases.

---

## 6. Containerization (infra-rstudio) Analysis

### 6.1 Current state

`infra-rstudio` provides:

```text
container-native RStudio Server
Nginx reverse proxy
oauth2-proxy sidecar (opt-in, oidc profile)
SSSD or Winbind profile (opt-in)
Step-CA trust bootstrap (rstudio-init)
resource limits (deploy.resources.limits)
tmpfs for /tmp
```

Explicit limitation from `OVERVIEW.md`:

```text
It is a pet service — designed to run on a single dedicated host.
network_mode: host is an architectural exception.
```

### 6.2 Pro

- Cleaner PKI/IAM integration.
- Resource limits enforced at container level.
- Immutable container build.
- oauth2-proxy/OIDC already wired.
- Step-CA bootstrap already designed.

### 6.3 Contra

| Risk | Detail |
|---|---|
| Not a cluster | Pet service = one host. No multi-node routing logic. |
| T1 parity gap | R-studioConf T1 contains years of R runtime hardening (BLAS, /Rtmp, Rprofile fragments, orphan cleanup, telemetry, NFS tuning). |
| `network_mode: host` | Exception that complicates multi-node design. |
| SSSD/Winbind sockets | Bind-mount complexity increases with node count. |
| T2 status | `MIGRATION_IN_PROGRESS` — open gaps documented in `.ai/project.yml`. |
| T3 status | `SKELETON_NOT_READY` — blockers include no NetworkPolicy, no StorageClass, no SSSD sidecar strategy. |

### 6.4 Recommendation

- Do NOT migrate production T1 to containers now.
- Use `infra-rstudio` as a T2 lab/evolution target.
- Establish T1 parity first, then port forward.

---

## 7. Positron Analysis

### 7.1 Project status

From `.ai/project.yml`:

```yaml
positron:
  status: "EVALUATION_PENDING"
  scope: "T2 (docker) and T3 (k8s) only"
  trigger_condition: >
    Adopt only if it demonstrably resolves a known T1 host-tier issue
    (RStudio Server rsession crashes, NIMBLE workload memory pressure,
    BLAS thread collision, or session-restore Error code 4).
    Until then: do not propose, do not configure.
```

### 7.2 Contra

- Not a replacement for RStudio Server OSS today.
- Does not fix certificate/trust/routing.
- Does not fix RStudio session limits.
- Training impact for botanist researchers.
- Diverts attention from actionable fixes.

### 7.3 Recommendation

Evaluation is valid as future exploration.

It is NOT a current migration target.

---

## 8. Roadmap — Recommended Phasing

### Phase 1: Trusted TLS (Step-CA)

**Objective:** Eliminate self-signed certificates.

```text
Deploy Step-CA (infra-pki).
Issue trusted certificate for single RStudio gateway FQDN.
Install Root CA on gateway host and managed clients.
Nginx uses trusted cert.
RStudio PAM login unchanged.
```

**Cost:** Low risk. No user-facing change except no browser warning.

**Acceptance criteria:**

- `curl --cacert root_ca.crt https://rstudio-gateway` returns OK.
- Browser no longer shows certificate warning.
- RStudio login works.
- Cookie `Secure` flag consistently present.
- WebSocket stable.

---

### Phase 2: Sticky User→Node Routing

**Objective:** Distribute different users across different nodes.

```text
Create node inventory (hostname, IP, port, drain flag).
Add user assignment store (SQLite or JSON + jq + flock).
Add node health checks (rstudio-server status, load, memory, /Rtmp).
Implement assignment policy:
  - existing assignment + healthy node → reuse.
  - no assignment → choose least-loaded healthy node.
  - drained node → no new users; existing users continue.
Extend Nginx to proxy /rstudio-inner/ to assigned node.
Add admin commands: drain, undrain, show assignment, force reassign.
```

**Cost:** Medium risk. Moderate development effort.

**Acceptance criteria:**

- User A always routed to the same node while session is alive.
- User B routed to a different node if node 1 is busier.
- Node down → no new users assigned; existing session fails gracefully.
- Node drain → existing users unaffected; new users routed elsewhere.
- Admin can query and change assignments.

---

### Phase 3: Keycloak Portal SSO

**Objective:** Centralized login for the web portal.

```text
Configure Keycloak client for RStudio portal.
Portal uses OIDC for user authentication.
Portal displays RStudio tile to authenticated users.
RStudio OSS still uses PAM login internally.
```

**Cost:** Medium risk. Keycloak is already built in `infra-iam`.

**Acceptance criteria:**

- Single login to portal (Keycloak).
- Access to portal tiles after login.
- RStudio PAM login still required (documented).
- Logout clears portal session.

---

### Phase 4: Open OnDemand (conditional)

**Trigger:** Requirement evolves to full HPC portal with multiple interactive apps.

```text
Deploy infra-ood.
Configure OOD to use Keycloak OIDC.
Define RStudio as an interactive OOD app.
OOD PUN proxies to assigned RStudio node.
Add Jupyter, terminal, or batch apps as needed.
```

**Cost:** Medium/high risk. New operational surface.

**Acceptance criteria:**

- OOD dashboard accessible after Keycloak login.
- Launch RStudio app → assigned to correct node.
- Multiple app types available.
- PUN lifecycle managed.

---

### Phase 5: OIDC Injection POC (conditional)

**Trigger:** User demand for single login into RStudio IDE.

```text
Deploy oauth2-proxy (oidc profile in infra-rstudio).
Configure backend proxy injection.
Run strict POC across browsers.
Validate CSRF, logout, stale cookies, forced reassignment.
If passes: document limitations and enable.
If fails: keep PAM login; document why OIDC injection is unsupported.
```

**Cost:** High risk (experimental). Must be reversible.

---

### Phase 6: T1→T2 Parity + T3 Later

```text
After T1 is stable with PKI + routing + optional Keycloak/OOD:
Port T1 behavior to T2 (docker/infra-rstudio).
Document any tier_deltas that cannot be identical.
Only then: address T3 Kubernetes blockers.
```

---

## 9. Non-Goals (Explicit Rejections)

| Non-goal | Reason |
|---|---|
| Multiple simultaneous RStudio IDE sessions for same user on OSS | Requires Posit Workbench or per-session containerization project |
| Transparent RStudio session roaming across nodes | Not supported by RStudio OSS |
| Random request-level load balancing for RStudio | Breaks WebSocket, cookies, session affinity |
| Kubernetes production deployment now | T3 = SKELETON_NOT_READY |
| Positron migration now | EVALUATION_PENDING |
| Auto-detection of all bottlenecks without observability | Must add monitoring before optimizing |
| Rewriting user R scripts to work around infrastructure limits | Violates HC-13 |

---

## 10. Decision Matrix

| Option | TLS/cookie | Routing | SSO portal | SSO RStudio | Multi-sess | Risk | When |
|---|---|---|---|---|---|---|---|
| Step-CA only | ✅ | ❌ | ❌ | ❌ | ❌ | Low | Now |
| Step-CA + sticky gateway | ✅ | ✅ | ❌ | ❌ | ❌ | Low/Med | Phase 2 |
| + Keycloak portal SSO | ✅ | ✅ | ✅ | ❌ | ❌ | Med | Phase 3 |
| + OIDC injection RStudio OSS | ✅ | ✅ | ✅ | ? POC | ❌ | High | Phase 5 POC |
| + Open OnDemand | ✅ | ✅ | ✅ | ❌ | ❌ | Med/High | Conditional |
| + Posit Workbench | ✅ | ✅ | ✅ | ✅ | ✅ | Cost/lic | If required |
| + Container infra-rstudio | ✅ | ❌ | Part | ❌ | ❌ | High now | After T1 parity |
| + Positron | ❓ | ❌ | ❌ | ❌ | ❓ | High | Not now |

---

## 11. References

- `.ai/project.yml` — Hard constraints, tier status, tier deltas, Positron status.
- `.ai/agents.md` — Full architecture, T1 script chain, R runtime.
- `docs/user_guides/rstudio_session_isolation.md` — Investigated XDG/env/profile workarounds.
- `docs/user_guides/risposta_ricercatore_sessioni_rstudio.md` — Researcher-facing explanation.
- `Infra-Iam-PKI/doc/infra-pki/RSTUDIO_INTEGRATION.md` — Step-CA enrollment + trust chain.
- `Infra-Iam-PKI/doc/infra-rstudio/OVERVIEW.md` — Container architecture, OIDC injection.
- `Infra-Iam-PKI/doc/infra-rstudio/CONFIGURATION.md` — `.env` reference.
- `Infra-Iam-PKI/doc/infra-rstudio/SECURITY.md` — Defense-in-depth, PKI trust model.
- `Infra-Iam-PKI/doc/infra-rstudio/DEPLOY.md` — Deployment prerequisites and steps.
- `Infra-Iam-PKI/doc/infra-ood/OVERVIEW.md` — OOD architecture and PUN design.
- `Infra-Iam-PKI/doc/infra-iam/OVERVIEW.md` — Keycloak architecture and AD federation.
