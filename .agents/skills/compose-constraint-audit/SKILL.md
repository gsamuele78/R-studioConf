---
name: compose-constraint-audit
description: Validates Docker Compose files against the 15 hard constraints of the R-studioConf project. Use when reviewing, editing, or creating any docker-compose.yml file. Checks resource limits, volume types, image pinning, port exposure, and all other pessimistic engineering invariants.
---

# Compose Constraint Audit Skill

Auditing a Docker Compose file for R-studioConf. Paradigm: **Pessimistic System Engineering** — assume failure, bound all resources, fail fast.

## Triage (check first — stop if irrelevant)

1. Is the file under `docker-deploy/` or `sandbox/`? If not, skip this skill.
2. Is the file a `docker-compose.yml` or `Dockerfile*`? If not, skip.
3. Sandbox compose files are exempt from HC-02 (named volumes allowed).

## Severity Rubric

| Severity | Criteria |
|----------|----------|
| CRITICAL | Missing resource limits on stateful service, direct docker.sock mount, exposed DB port |
| HIGH | Named volumes in production compose, unpinned upstream image, missing healthcheck |
| MEDIUM | Missing logging anchor, missing labels, deprecated `version:` key |
| LOW | Style/formatting deviations, non-blocking warnings |

## Checklist (verify EVERY item for EVERY service)

1. **HC-01 Resource Limits:** Has `deploy.resources.limits` with BOTH `memory` and `cpus`.
   - RStudio containers: conservative CPU/RAM caps for stable multi-user sessions.
   - Stateless sidecars (oauth2-proxy, telemetry): 128M–512M typical.
   - `docker-socket-proxy`: 128M.

2. **HC-02 No Named Volumes:** All `volumes:` entries use bind mounts (`./path:/path`). There MUST be NO top-level `volumes:` section in production compose. Sandbox exempt.

3. **HC-05 No DB Port Exposure:** PostgreSQL services must NOT have a `ports:` section.

4. **HC-07 Pinned Versions:** Every `image:` must have an explicit version tag.
   - **UPSTREAM images** (from registries like quay.io, docker.io): MUST be pinned to exact semver. Check `.ai/extracted_versions.env` for current pinned versions.
   - **LOCALLY-BUILT images** (`botanical-*`, `rstudio-botanical-*`): tagged via `${IMAGE_TAG}` variable (defaults to `:latest` in sandbox/CI; production deploys MUST set a pinned tag). This is codified in HC-07 rationale — locally-built images are never pulled from a registry.

5. **HC-09 No docker.sock:** Only `docker-socket-proxy` may mount `/var/run/docker.sock`. All other services MUST NOT.

6. **HC-15 RStudio Version Alignment:** RStudio containers MUST map to the project's stable R/RStudio versions as defined in `config/r_env_manager.conf` and `kubernetes-deploy/configmaps.yaml`. Prevent unpinned runtime installations of different versions.

7. **Healthcheck:** All stateful (non-ephemeral) services must have a `healthcheck:` block.

8. **Logging:** Must use the `&default-logging` YAML anchor pattern with `json-file` driver.

9. **depends_on:** Must use `condition: service_healthy` or `condition: service_completed_successfully`.

10. **No version: key:** Compose v2 does not need `version:` at the top.

11. **Labels:** Long-running services should have `com.centurylinklabs.watchtower.enable=true`.

12. **Storage:** `/Rtmp` is a 400GB ext4 host disk — it SHOULD be bind-mounted into RStudio containers for large R temp workloads (NIMBLE, matrix ops). `/tmp` inside the container uses `tmpfs` with a size cap (e.g. `size=16G`). Do NOT use `/tmp` for large R temp storage — use `/Rtmp`.

## Output Format

```
[PASS/FAIL/WARN] HC-XX: Service 'name' — description
  → Fix: specific fix instruction
```

## Reference Files

- `.ai/project.yml` — structured constraint definitions with rationale
- `.ai/agents.md` — full architecture, script chain, R runtime hardening context
- `.ai/extracted_versions.env` — current pinned upstream versions
