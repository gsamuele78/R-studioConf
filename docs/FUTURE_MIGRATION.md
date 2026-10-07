<!-- docs/FUTURE_MIGRATION.md -->
# Deployment-Tier Status and Future Migration

> Status date: 2026-10-06. Code is authoritative where it conflicts with older roadmap prose. `.ai/project.yml` supplies tier policy and recorded deltas.

## Current status

| Tier | Status | Repository surface | Honest description |
|---|---|---|---|
| T1 host | `AUTHORITATIVE_CONTINUOUSLY_FIXED` | `init.sh`, `r_env_manager.sh`, `scripts/`, `lib/`, `config/`, `templates/` | Active source of truth. Fix defects here first and port them forward. Rprofile version 12.10; serial OpenBLAS; local 400 GB ext4 `/Rtmp`. |
| T2 Docker | `MIGRATION_IN_PROGRESS` | `docker-deploy/` | Self-contained Compose v2 migration surface. It is not a complete behavioral mirror of T1. |
| T3 Kubernetes | `SKELETON_NOT_READY` | `kubernetes-deploy/` | Kustomize/manifests exist, but the tier is gated and not a production target. |

The promotion rule is T1 -> T2 -> T3. See [`deployment/TIER_PROMOTION.md`](deployment/TIER_PROMOTION.md).

## T1: active authority

The active host chain is:

```text
init.sh -> r_env_manager.sh -> scripts/NN_*.sh
```

Current runtime invariants include:

- `RPROFILE_VERSION="12.10"`
- `libopenblas0-serial`, never the pthread OpenBLAS implementation
- local `/Rtmp`, 400 GB ext4, not `/tmp` and not tmpfs
- SSSD XOR Samba/Winbind
- modular `/etc/biome-calc/profile.d/`
- site-local sensitive configuration under gitignored `config/site/`

T1 still has open defects recorded in [`audits/T1_HOST_DEPLOYMENT_AUDIT.md`](audits/T1_HOST_DEPLOYMENT_AUDIT.md). “Authoritative” does not mean defect-free; it means defects are corrected here first.

## T2: Docker migration in progress

`docker-deploy/docker-compose.yml` currently defines eight services:

1. `rstudio-init`
2. `docker-socket-proxy`
3. `rstudio-sssd`
4. `rstudio-samba`
5. `nginx-portal`
6. `oauth2-proxy`
7. `telemetry-api`
8. `ollama-ai`

Profiles are `sssd`, `samba`, `portal`, `oidc`, and `ai`. All services except `docker-socket-proxy` use host networking. The socket proxy uses a dedicated bridge and publishes only `127.0.0.1:2375`.

Current upstream image pins visible in code are:

- `curlimages/curl:8.22.0`
- `tecnativa/docker-socket-proxy:v0.5.0`
- `quay.io/oauth2-proxy/oauth2-proxy:v7.6.0-alpine`
- `rocker/geospatial:4.4.2` in the RStudio Dockerfiles
- `ollama/ollama:0.5.4` in the Ollama Dockerfile

Locally built images use `${IMAGE_TAG}` and production deployments must set a pinned tag.

### T2 facts corrected since the older roadmap

- Both `docker-socket-proxy` and `oauth2-proxy` now have healthchecks in Compose. The corresponding item in `.ai/project.yml -> deployment_tiers.T2_docker.open_gaps` is stale.
- The generic claim that every service uses host networking is false; the socket proxy deliberately does not.
- Compose defines eight services, not six.
- The RStudio image base is 4.4.2, not 4.4.1.

### T2 gaps still open

- Recorded delta `TD-T2-01`: the container R environment still uses an older single-file T1 snapshot and audit v27 rather than the T1 fragment layout and audit v28.
- The RStudio services mount `/tmp` as tmpfs with a default 16 GB size. That does not mirror the T1 `/Rtmp` 400 GB ext4 invariant and must be resolved or recorded explicitly as a tier delta.
- T2 uses the permanent, documented deviations `TD-T2-02` through `TD-T2-05` for socket-proxy networking, the oauth2-proxy Alpine image, lack of bspm/r2u in Rocker images, and bind-mounted admin recipients.
- Full runtime parity still requires testing against T1-observable behavior. The known-broken sandbox cannot supply that validation.

## T3: skeleton, not ready

The repository contains namespace, config maps, deployments, services, ingress, storage, secrets, network-policy, and kustomization manifests plus deployment/validation scripts. Their existence does not change the `SKELETON_NOT_READY` status.

Current blockers and contradictions include:

- no PodDisruptionBudget or HorizontalPodAutoscaler manifests;
- no demonstrated production StorageClass meeting the T1 local 400 GB ext4 `/Rtmp` requirement;
- no validated SSSD/Samba identity strategy matching T1 behavior;
- no validated PKI/secret-rotation flow;
- no completed T2 parity baseline from which T3 can be promoted;
- `kubernetes-deploy/configmaps.yaml` still sets telemetry temp to `/tmp`, not `/Rtmp`;
- `.ai/project.yml` still says “no NetworkPolicy,” although `kubernetes-deploy/network-policies.yaml` now exists. Presence alone is not proof that policy coverage is complete; update the blocker only after the manifest is audited and validated.

Do not deploy or describe T3 as production-ready until blockers are closed and tier parity is demonstrated.

## Downstream consumer

`Infra-Iam-PKI` is not a submodule. It is a downstream consumer that vendors `docker-deploy/` and `kubernetes-deploy/` from this repository. Those directories must remain self-contained. See [`developer/git_submodule_workflow.md`](developer/git_submodule_workflow.md).

`Infra-Iam-PKI.backup` is excluded and must not be touched.

## Dormant and conditional work

### Rust core

`src/biome_core_rust` is `DORMANT`. It did not demonstrate a useful R code-loading speedup. Do not activate it or present it as part of the active architecture.

### Positron

Status is `EVALUATION_PENDING`, limited to T2/T3. Adoption is conditional on demonstrating that it resolves a known T1 issue such as rsession crashes, NIMBLE memory pressure, BLAS thread collision, or session-restore Error code 4. No timeline exists and no Positron-specific configuration should be added before the trigger is met.

### Infrastructure as Code

Ansible/Terraform adoption is speculative. It is not an active commitment and must not be presented as scheduled work.

## Promotion gates

Before claiming T2 parity:

1. close or explicitly record every observable deviation from T1;
2. deploy Rprofile 12.10 fragments and audit v28 behavior;
3. resolve large-scratch storage parity;
4. pass Compose constraints, build tests, healthchecks, and production-host behavior checks.

Before claiming T3 readiness:

1. establish T2 parity first;
2. validate identity, storage, networking, disruption, scaling, Pod Security, PKI, and secret rotation;
3. prove the same user-visible R behavior and HC-13 contract as T1;
4. record all unavoidable deltas.

Unverified: this audit parsed repository configuration but did not build images, start Compose, apply Kubernetes manifests, or test the downstream consumer repository. Runtime readiness therefore remains unverified.
