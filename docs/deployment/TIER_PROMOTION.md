# TIER_PROMOTION.md — How fixes flow across deployment tiers

> **Source of truth:** `.ai/project.yml → deployment_tiers`, `tier_promotion_rule`, `engineering_ethos`.
> **Audience:** sysadmin operator + any AI agent assisting on this repo.
> **Stance:** honest, not optimistic.

## 1. The three tiers (current honest status)

| Tier | Status | Role | Entry point |
|------|--------|------|-------------|
| **T1 — host** | `AUTHORITATIVE_CONTINUOUSLY_FIXED` | Bare-metal install on Debian. Source of truth for **behavior**. Stability is achieved by **continuous bug-fixing here**, not by freezing files. | `init.sh → r_env_manager.sh → scripts/NN_*.sh` |
| **T2 — docker** | `MIGRATION_IN_PROGRESS` | Containerize T1 incrementally. Must mirror T1 behavior. | `docker-deploy/deploy.sh → docker compose` |
| **T3 — k8s**  | `SKELETON_NOT_READY` | Future. Adopt only after T2 fully mirrors T1. | `kubernetes-deploy/scripts/deploy_k8s.sh` |

T1 is **not frozen**. Every host file (scripts, lib, templates including `Rprofile_site.d/`, configs) is in scope for fixes.

## 2. Promotion contract

```
                  ┌──────────────────────────┐
        ┌────────►│  T1 host (authoritative) │  ◄──── bug observed (any tier)
        │         └────────────┬─────────────┘
        │                      │ fix here first
        │                      ▼
        │         ┌──────────────────────────┐
        │         │  T2 docker (mirror T1)   │
        │         └────────────┬─────────────┘
        │                      │ port forward
        │                      ▼
        │         ┌──────────────────────────┐
        └─────────│  T3 k8s (mirror T2/T1)   │
                  └──────────────────────────┘
```

**Rule:** *A bug discovered in any tier is fixed in T1 first (or recorded as a T2/T3 deviation in `tier_deltas`); then ported forward T1 → T2 → T3. Never patch T2/T3 in a way that masks a T1 defect.*

## 3. What counts as a "T1 fix" (admissibility)

A change to T1 is admissible only if it satisfies all three:

1. **Reproducible from a clean VM baseline** — see `docs/operations/CLEAN_VM_BASELINE.md` (L4).
2. **Regression test added** — under `tests/` (preferred) or as a `scripts/99_*` diagnostic that emits a verdict line.
3. **Documented** — at minimum a short note in the relevant operator runbook (`docs/operations/*.md`).

For HC-13 (user-script-related) fixes, the layer-clearing ordering (L0 → L1 → L2 → L3 → L4) is mandatory before suggesting any user-script edit. See `.ai/agents.md §6.6`.

## 4. Porting a T1 fix forward to T2

Checklist (per fix):

- [ ] Update the relevant container's `Dockerfile*` and/or entrypoint script under `docker-deploy/scripts/`.
- [ ] Update `docker-deploy/docker-compose.yml` only if behavior requires (mounts, env, healthcheck, limits).
- [ ] Run `docker-deploy/scripts/validate_deployment.sh` (T2 pre-flight).
- [ ] Verify no `:latest` introduced for external images (HC-07).
- [ ] If T1 ↔ T2 cannot be made identical, **add an entry to `.ai/project.yml → tier_deltas`** with rationale.

## 5. Porting a T2 fix forward to T3

Checklist (per fix):

- [ ] Update the relevant `kubernetes-deploy/*-deployment.yaml` (resources, probes, securityContext).
- [ ] Update `kubernetes-deploy/configmaps.yaml` / `secrets.yaml` shape if env keys changed.
- [ ] Update `kubernetes-deploy/env/.env.example` if a new env key is required.
- [ ] Run `kubernetes-deploy/scripts/validate_k8s.sh`.
- [ ] If T2 ↔ T3 cannot be made identical, **add an entry to `.ai/project.yml → tier_deltas`**.

T3 must not be promoted past `SKELETON_NOT_READY` while any of the following remain (per `deployment_tiers.T3_k8s.blockers`):

- no NetworkPolicy / PodDisruptionBudget / HPA / PSA labels
- no StorageClass for `/Rtmp` (NIMBLE workloads)
- no SSSD/Samba sidecar strategy
- no PKI / secret rotation flow

## 6. Recording deviations: `tier_deltas`

If T2 or T3 must legitimately diverge from T1 (e.g. host-only kernel sysctl is meaningless inside a pod), append to `.ai/project.yml`:

```yaml
tier_deltas:
  - id: "TD-001"
    tiers: ["T1", "T2"]
    description: "Short summary of the deviation."
    rationale: "Why T2 cannot mirror T1 byte-for-byte."
    mitigation: "What compensates for the divergence (e.g. host sysctl applied via DaemonSet on T3)."
    expires: "open|YYYY-MM-DD"  # when we expect to close the gap
```

Run `make audit` after every change to ensure validators and generated IDE rule files stay in sync.

## 7. Positron — evaluation_pending

Per `.ai/project.yml → roadmap.evaluation_pending.positron`: Positron is *not* adopted. It will be reconsidered for T2/T3 *only if* it demonstrably resolves a known T1 host-tier issue (rsession crashes, NIMBLE memory pressure, BLAS thread collision, Error code 4). Until then: do not add Positron-specific files, dependencies, or rules.

## 8. Cross-references

- `.ai/project.yml` — the source-of-truth file (tiers, ethos, ignore globs, submodules).
- `.ai/agents.md` — full project context (T1 script chain, R runtime hardening).
- `.agents/skills/host-install-audit/SKILL.md` — T1 audit checklist.
- `.agents/skills/compose-constraint-audit/SKILL.md` — T2 audit checklist.
- `.agents/skills/k8s-manifest-audit/SKILL.md` — T3 audit checklist.
- `Makefile` — `make audit` runs `validate.sh` + `generate.sh --check`.
