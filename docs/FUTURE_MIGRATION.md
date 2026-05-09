# Future Roadmap & Migration

> **Stance:** honest, not optimistic. Three concurrent deployment tiers are tracked in `.ai/project.yml → deployment_tiers`. T1 (host) is the **authoritative & continuously-fixed** tier; T2 (docker) and T3 (kubernetes) mirror T1.

## 1. Current state (no aspirational claims)

| Tier | Status | What works today |
|------|--------|------------------|
| **T1 — host** | `AUTHORITATIVE_CONTINUOUSLY_FIXED` | Production. RStudio Server + nginx portal + OIDC (oauth2-proxy) + SSSD/Samba + Kerberos + Let's Encrypt + telemetry. Numbered scripts `01..50`, diagnostics `99_*`, modular `Rprofile_site.d/`, BLAS pin (`libopenblas0-serial`), `/Rtmp` 400GB. |
| **T2 — docker** | `MIGRATION_IN_PROGRESS` | Compose v2, 6 services on `network_mode: host`, bind-mounts only, profiles (`sssd\|samba\|portal\|oidc\|ai`), docker-socket-proxy. **Open gaps:** see `.ai/project.yml → deployment_tiers.T2_docker.open_gaps`. |
| **T3 — kubernetes** | `SKELETON_NOT_READY` | Kustomize manifests + `deploy_k8s.sh` + `validate_k8s.sh`. **Blockers:** no NetworkPolicy / PDB / HPA / PSA labels; no StorageClass for `/Rtmp`; no SSSD/Samba sidecar design; no PKI / secret rotation flow. See `.ai/project.yml → deployment_tiers.T3_k8s.blockers`. |

The promotion contract is documented in `docs/deployment/TIER_PROMOTION.md`.

## 2. Phase 1 — T2 (docker) hardening (in progress)

Goal: T2 fully mirrors T1, with no silent divergence.

Tasks (tracked in `.ai/project.yml → deployment_tiers.T2_docker.open_gaps`):

- [x] `deploy.sh` strict mode (HC-03) and HC-10 trap.
- [x] `validate_deployment.sh` stub created (full surface still TODO).
- [x] Dockerfile bases pinned to semver (`rocker/geospatial:4.4.1`, `nginx:1.27-alpine`, `ollama/ollama:0.5.4`).
- [ ] `oauth2-proxy` and `docker-socket-proxy` healthchecks.
- [ ] Full HC-01/02/04/05/06/10/11 checks inside `validate_deployment.sh`.
- [ ] Each T2 entrypoint mirrors the equivalent T1 numbered script behavior with no observable difference.

## 3. Phase 2 — T3 (kubernetes) — gated

Goal: containerize per-user RStudio with hard isolation. **Do not start until T2 phase 1 is green.**

Required design (none of these exist yet):

- StorageClass providing fast local 400GB ext4 for `/Rtmp` (NIMBLE workloads).
- Strategy for AD integration (host-network pod + tolerations, OR external Keycloak via the `Infra-Iam-PKI/` sibling project).
- NetworkPolicy default-deny + allow-list.
- PodDisruptionBudget for `rstudio` and `portal`.
- HorizontalPodAutoscaler once SLOs are defined (not before).
- Pod Security admission `restricted` on `botanical` namespace.
- Secret rotation flow (currently apply-time injection only).

Until those exist, T3 manifests in `kubernetes-deploy/` are a starting skeleton, not a deployment target.

### Why not RStudio Connect / JupyterHub

Both were considered. They impose user/workflow changes that conflict with HC-13 (we adapt the system to portable user R code; we do not ask researchers to rewrite their scripts). We will revisit if a community-reputable, lower-friction alternative emerges.

## 4. Positron — evaluation_pending (NOT adopted)

`.ai/project.yml → roadmap.evaluation_pending.positron` records the honest status:

- **Status:** `EVALUATION_PENDING`.
- **Scope:** T2 and T3 only.
- **Trigger condition:** adopt **only if** it demonstrably resolves a known T1 host-tier issue (rsession crash, NIMBLE memory pressure, BLAS thread collision, session-restore Error code 4).
- **Until then:** do not propose, do not configure, do not add Positron-specific files.

There is no timeline. Adoption is conditional.

## 5. Phase 3 — Infrastructure as Code (Ansible / Terraform) — speculative

Hypothetical, not committed. Would only happen after T3 is stable and the operator profile changes from "single LPIC-3 sysadmin" to a team. Recorded here so the agent does not invent it as a current goal.

## 6. What this document is NOT

- Not a sales pitch.
- Not a timeline.
- Not a list of "best-practice" alternatives the agent should suggest unprompted.

If you came here looking for a sentence that says "we plan to adopt X by Q3", it is not here on purpose. See `.ai/project.yml → engineering_ethos`.
