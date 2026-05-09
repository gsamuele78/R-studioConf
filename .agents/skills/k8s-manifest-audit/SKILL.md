---
name: k8s-manifest-audit
description: Validates Kubernetes manifests in kubernetes-deploy/ against R-studioConf T3 invariants. Use when reviewing, editing, or creating any *.yaml under kubernetes-deploy/ (deployments, services, ingress, kustomization, configmaps, secrets, storage). T3 is SKELETON_NOT_READY — agent must surface gaps honestly, not pretend production-readiness.
---

# Kubernetes Manifest Audit Skill (Tier T3)

> **HONEST STATUS:** T3 is `SKELETON_NOT_READY` per `.ai/project.yml → deployment_tiers.T3_k8s`. Promote to production only after **T2 (docker)** fully mirrors **T1 (host)**. Never present the k8s tier as ready when it is not.

## Promotion contract (read before editing anything in `kubernetes-deploy/`)

```
T1 host  ──fixed first──►  T2 docker  ──mirrored──►  T3 k8s
                                                       ▲
                          Any deviation from T1/T2 ────┘  must be recorded in
                          .ai/project.yml → tier_deltas with rationale.
```

## Layout

```
kubernetes-deploy/
├── kustomization.yaml          ── Kustomize entry; image tag pins; configMapGenerator; replacements
├── namespace.yaml              ── Namespace: botanical
├── configmaps.yaml             ── nginx_proxy_location.conf, OIDC settings (NON-secret)
├── secrets.yaml                ── PLACEHOLDER ONLY; real secrets injected by deploy_k8s.sh from env/.env.prd
├── storage.yaml                ── PVC claims (currently no StorageClass for /Rtmp)
├── ingress.yaml                ── HOST_DOMAIN replaced by Kustomize
├── rstudio-deployment.yaml + rstudio-service.yaml
├── portal-deployment.yaml  + portal-service.yaml
├── ollama-deployment.yaml
├── telemetry-api-deployment.yaml
├── oauth2-proxy-deployment.yaml
├── conf/nginx_proxy_location.conf      ── consumed by configMapGenerator
├── env/.env.example                    ── REQUIRED template (deploy_k8s.sh fails without it)
└── scripts/
    ├── deploy_k8s.sh                   ── kubectl create secret + apply -k
    └── validate_k8s.sh                 ── pre-flight linter
```

## Checklist (verify EVERY manifest you touch)

### Hard constraints inherited from T1/T2

1. **HC-01 resource bounds:** Every container has `resources.limits` AND `resources.requests` for both `cpu` and `memory`. (k8s requests are stricter than compose limits; both are required.)
2. **HC-04 secrets:** Never embed plaintext secrets in YAML. `secrets.yaml` is a placeholder; runtime values come from `env/.env.prd` via `deploy_k8s.sh`. No `--from-literal=PASSWORD=…` survives outside the deploy script.
3. **HC-05 no DB exposure:** No `Service` of type `NodePort`/`LoadBalancer` for postgres-like workloads.
4. **HC-07 image pinning:** Image tags pinned via `kustomization.yaml → images:` block; no `:latest` for externally-sourced images. Local botanical images allowed `:latest` per documented exception (mirror T2 rule).
5. **HC-09 no docker.sock:** Never mount `/var/run/docker.sock` into a pod.
6. **HC-10 chown failure:** `deploy_k8s.sh` and `validate_k8s.sh` start with `set -euo pipefail`; any `kubectl create … || error` path exits non-zero on permission failure.
7. **HC-11 no CDN:** Portal ConfigMap nginx config has no external font/CSS URLs.

### Skeleton-tier gaps (surface honestly; do not silently fix without scope)

1. **No NetworkPolicy** — recommend `default-deny` + allow-list, but only add if scope explicitly requests it.
2. **No PodDisruptionBudget** — recommend `minAvailable: 1` for rstudio/portal.
3. **No HorizontalPodAutoscaler** — defer until SLO defined.
4. **No PodSecurity admission labels** — recommend `pod-security.kubernetes.io/enforce: restricted` on namespace once tested.
5. **No StorageClass for /Rtmp:** NIMBLE workloads need 400GB ext4 fast local — current `storage.yaml` does not declare one. **Blocker for T3 production.**
6. **No SSSD/Samba sidecar strategy:** host-AD integration in T1 uses `network_mode: host` in T2; in k8s this needs a different design (host-network pod + tolerations, or external IDP via Keycloak from `Infra-Iam-PKI/`). **Blocker.**
7. **No PKI / secret rotation flow** — `deploy_k8s.sh` injects secrets at apply-time only; no rotation. **Blocker.**

### Kustomize hygiene

1. **`replacements:`** for HOST_DOMAIN, IMAGE_TAG, and Nextcloud URL — values come from env, not hardcoded.
2. **`configMapGenerator`** for nginx config with `behavior: replace` to avoid stale ConfigMaps.
3. **`commonLabels:`** include `app.kubernetes.io/name`, `app.kubernetes.io/part-of: r-studioconf`, `app.kubernetes.io/managed-by: kustomize`.

### Positron (evaluation_pending)

Per `.ai/project.yml → roadmap.evaluation_pending.positron`: **do not** add Positron-specific manifests. Adopt only after it demonstrably resolves a known T1 host-tier issue.

### Submodule boundary

Per `.ai/project.yml → submodules.infra_iam_pki`: never reference `Infra-Iam-PKI/` from `kubernetes-deploy/` files; that integration is a future task owned by the sibling project.

## Output Format

```
[PASS/FAIL/WARN/SKELETON_GAP] T3 <file>:<key path> — <id> — description
  → Fix: specific instruction OR
  → Honest gap: this is a known blocker; record/keep in project.yml → deployment_tiers.T3_k8s.blockers
```

## Reference Files

- `.ai/project.yml` — `deployment_tiers.T3_k8s`, `tier_promotion_rule`, `roadmap.evaluation_pending.positron`
- `.ai/agents.md` — full architecture (T1 origin of behavior)
- `kubernetes-deploy/scripts/deploy_k8s.sh` — what gets injected at apply-time
- `docker-deploy/docker-compose.yml` — T2 mirror to compare against
