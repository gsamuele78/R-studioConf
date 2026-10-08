<!-- docs/architecture/rstudio_cluster_evolution_pki_iam_ood.md -->
---
title: "RStudio Cluster Evolution: PKI, IAM, Open OnDemand, Containers, and Positron"
audience: architect
status: current
tier: T1
source_path: docs/architecture/rstudio_cluster_evolution_pki_iam_ood.md
last_verified: 2026-10-06
---

# RStudio Cluster Evolution: PKI, IAM, Open OnDemand, Containers, and Positron

## 1. Document status

This is a roadmap and decision-boundary document. It does not describe PKI,
Keycloak, Open OnDemand, multi-node routing, or Positron as active T1 services.

The June 2026 version treated an `Infra-Iam-PKI` sibling tree as if it were
part of this repository. That relationship changed. `.ai/project.yml` now
states that Infra-Iam-PKI is a **consumer** of this repository: it vendors
`docker-deploy/` and `kubernetes-deploy/` from the commit recorded in its own
upstream lock. Fixes originate here; this repository does not import or manage
the consumer project.

## 2. Verified current baseline

### 2.1 T1 host

T1 is `AUTHORITATIVE_CONTINUOUSLY_FIXED` and currently provides:

- RStudio Server OSS on `127.0.0.1:8787`;
- Nginx TLS and the static portal on ports 80/443;
- PAM/NSS identity through SSSD **or** Samba/Winbind;
- ttyd on `127.0.0.1:2222`, protected by Nginx PAM;
- a Nextcloud reverse-proxy path to an operator-configured external target;
- telemetry on `127.0.0.1:8000` and node exporter on `127.0.0.1:9100`;
- optional Ollama on `127.0.0.1:11434`;
- Rprofile 12.11, local `/Rtmp`, local R libraries, and cgroup user slices.

T1 supports self-signed or Let's Encrypt certificates. It contains no
oauth2-proxy, Step-CA enrollment, Keycloak client, Open OnDemand service,
sticky multi-node router, or Positron service.

### 2.2 T2 Docker

T2 is `MIGRATION_IN_PROGRESS`. The 2026-10-01 back-port added self-contained
Docker assets, Step-CA root-trust bootstrap, pinned images, an optional
oauth2-proxy v7.6.0-alpine `oidc` profile, and a loopback-only Docker API
proxy.

T2 is not a full T1 replacement. `TD-T2-01` remains open: T2 uses a
monolithic Rprofile snapshot and audit v27 instead of T1's v12.11 fragments
and audit v28. T2 also intentionally omits bspm/r2u (`TD-T2-05`).

### 2.3 T3 Kubernetes

T3 is `SKELETON_NOT_READY`. NetworkPolicies and pinned images exist, but the
tier still has unresolved identity, storage, PKI rotation, and parity work.
It is not an active cluster platform.

### 2.4 External consumer

Infra-Iam-PKI consumes vendored copies of `docker-deploy/` and
`kubernetes-deploy/`. Its current deployment state, service versions, and
operational readiness are outside this repository.

**Unverified:** whether Step-CA, Keycloak, Open OnDemand, or an Infra-Iam-PKI
RStudio deployment is currently running in any environment.

## 3. Decision table

| Capability | Active T1 | Present elsewhere in this repo | Status |
|---|---|---|---|
| Self-signed TLS | Yes | T2 certificate bind mounts | Current option |
| Let's Encrypt TLS | Yes | T2 certificate bind mounts | Current option |
| Step-CA root trust | No | T2 init and image tooling; T3 init containers | Migration component, not T1 |
| oauth2-proxy | No | T2 optional `oidc` profile; T3 manifests/config | Migration component, not T1 |
| Keycloak | No | T3 issuer URL only | External dependency / roadmap |
| Open OnDemand | No | No active implementation in this repo | Roadmap only |
| Sticky user-to-node routing | No | No implementation | Roadmap only |
| Positron | No | No implementation | `EVALUATION_PENDING`, T2/T3 scope only |
| Posit Workbench | No | No implementation | Out of current scope |
| Kubernetes production deployment | No | T3 skeleton | Not ready |

## 4. PKI evolution

### 4.1 What exists

T1 can issue or install self-signed and Let's Encrypt certificates through
`scripts/30_install_nginx.sh` and `scripts/32_setup_letsencrypt.sh`.

T2 has a `rstudio-init` one-shot container that verifies the configured
Step-CA root certificate path. RStudio and Nginx images mount that root. The
Docker images include the pinned Step CLI used by the consumer integration.

### 4.2 What does not exist in T1

T1 has no script that:

- enrolls the host against Step-CA;
- renews a Step-CA leaf certificate;
- configures an internal ACME endpoint;
- rotates Step-CA trust; or
- verifies TLS to RStudio upstream nodes.

Step-CA must therefore remain labeled as a T2/T3 or external-consumer
capability until those T1 controls are implemented and tested.

### 4.3 Acceptance boundary for any T1 PKI change

A future T1 PKI change must preserve:

- one public TLS gateway;
- RStudio and ttyd loopback binding;
- secure RStudio cookies and WebSocket operation;
- deterministic renewal and rollback;
- no secret or token in process arguments;
- T1-first implementation before port-forwarding.

## 5. IAM and OIDC evolution

### 5.1 Current T1 identity

T1 authenticates the portal and terminal through Nginx PAM and authenticates
RStudio through its own PAM service. The portal browser handles credentials
and submits them to the relevant backends.

### 5.2 T2 OIDC surface

T2 can start oauth2-proxy under profile `oidc`. The service listens on host
port 4180 and reads a bind-mounted configuration file. That service alone
does not prove that the T2 Nginx portal or RStudio OSS login is fully protected
or that transparent RStudio login is supported.

**Unverified:** end-to-end OIDC login, logout, stale-cookie, CSRF, and browser
compatibility for the current T2 assets. No repository test exercises an
actual identity provider.

### 5.3 Transparent RStudio login

The active T1 portal already depends on RStudio's internal
`/auth-do-sign-in` endpoint. Replacing the credential modal with an OIDC
identity assertion would still require a supported method to establish the
RStudio PAM session. The repository contains no completed, tested solution for
that transition.

Do not document `X-Forwarded-User` as a supported RStudio OSS authentication
mechanism. It is used for ttyd, not RStudio.

## 6. Open OnDemand

No Open OnDemand code is active in this repository. OOD remains a conditional
architecture option for a future requirement that includes multiple managed
interactive applications, per-user proxy processes, and a scheduler-backed
session lifecycle.

OOD is not required to keep the current single-node portal working, and it is
not an implemented sticky router for current RStudio nodes.

**Unverified:** the current feature set and deployment readiness of the
external consumer's OOD material.

## 7. Multi-node routing

The repository has no assignment store, node inventory, drain command, or
server-side sticky user-to-node routing service. Multiple RStudio node names
appear in runtime comments and historical operational material, but the active
Nginx template always proxies RStudio to local `127.0.0.1:8787`.

A future router would need, at minimum:

- authenticated server-side user identity;
- a durable user-to-node assignment record;
- node health and drain state;
- WebSocket and cookie affinity;
- explicit failure behavior when an assigned node is unavailable;
- operator query, reassignment, and rollback commands.

These are acceptance requirements, not implemented features.

## 8. RStudio session model

This repository configures one RStudio Server OSS service per node and does
not configure Posit Workbench, Job Launcher, a session database, or a
per-session container launcher.

**Unverified:** the exact current upstream limit on simultaneous RStudio OSS
sessions per user was not verified from repository code. The repo has no code
that promises multiple independent IDE sessions for one user, so this
capability must not be advertised.

## 9. Positron

`.ai/project.yml` defines Positron as:

- `EVALUATION_PENDING`;
- limited to T2 and T3 evaluation;
- prohibited from adding files, dependencies, or rules until it demonstrably
  resolves a known T1 problem.

No Positron files or services exist in the active deployment. Positron is not
a current migration target and does not solve T1 PKI, routing, or identity by
itself.

## 10. Sequencing constraints

Any evolution must preserve the repository's order:

1. Fix or implement the behavior in T1, unless it is inherently tier-specific
   and recorded as a tier delta.
2. Validate T1 on the active user/researcher path. The sandbox is broken.
3. Port the behavior to T2 and close or update the relevant tier delta.
4. Address T3 only after T2 parity is stable.

For the current roadmap, the unresolved T2 runtime parity gap has priority over
claiming a completed platform migration.

## 11. Rejected current-state claims

The following are not supported by repository evidence:

- “T1 uses OIDC or Keycloak.”
- “Step-CA manages T1 certificates.”
- “Open OnDemand is deployed.”
- “Users are automatically routed across RStudio nodes.”
- “RStudio sessions roam between nodes.”
- “Positron is available in the browser.”
- “T2 has T1 Rprofile 12.11 parity.”
- “T3 is production-ready.”
- “Infra-Iam-PKI is a submodule of this repository.”

## 12. Sources

- `.ai/project.yml`
- `CHANGELOG.md`
- `scripts/20_configure_rstudio.sh`
- `scripts/30_install_nginx.sh`
- `scripts/32_setup_letsencrypt.sh`
- `templates/nginx_proxy_location.conf.template`
- `docker-deploy/docker-compose.yml`
- `docker-deploy/Dockerfile.nginx`
- `docker-deploy/scripts/manage_pki_trust.sh`
- `kubernetes-deploy/configmaps.yaml`
- `kubernetes-deploy/`

---

*Last verified against active repository code: 2026-10-06.*
