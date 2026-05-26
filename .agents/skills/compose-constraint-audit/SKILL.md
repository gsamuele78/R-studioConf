---
name: compose-constraint-audit
description: Validates Docker Compose files against the 12 hard constraints of the R-studioConf project. Use when reviewing, editing, or creating any docker-compose.yml file. Checks resource limits, volume types, image pinning, port exposure, and all other pessimistic engineering invariants.
---

# Compose Constraint Audit Skill

Auditing a Docker Compose file for R-studioConf. Paradigm: **Pessimistic System Engineering** — assume failure, bound all resources, fail fast.

## Checklist (verify EVERY item for EVERY service)

1. **HC-01 Resource Limits:** Has `deploy.resources.limits` with BOTH `memory` and `cpus`.
   - RStudio containers: conservative CPU/RAM caps for stable multi-user sessions.
   - Stateless sidecars (oauth2-proxy, telemetry): 128M–512M typical.
   - `docker-socket-proxy`: 128M.

2. **HC-02 No Named Volumes:** All `volumes:` entries use bind mounts (`./path:/path`). There MUST be NO top-level `volumes:` section.

3. **HC-05 No DB Port Exposure:** PostgreSQL services must NOT have a `ports:` section.

4. **HC-07 Pinned Versions:** Every `image:` must have an explicit version tag.
   - **LOCAL IMAGE EXCEPTION:** `botanical-*` and `rstudio-botanical-*` images use `:latest` by design — they are locally built and never pulled from a registry. This is **intentional and compliant**.
   - External registry images MUST be pinned: `quay.io/oauth2-proxy/oauth2-proxy:v7.6.0`, `tecnativa/docker-socket-proxy:0.3.0`.
   - Check `.ai/extracted_versions.env` for current pinned external versions.

5. **HC-09 No docker.sock:** Only `docker-socket-proxy` may mount `/var/run/docker.sock`. All other services MUST NOT.
6. **RStudio Version Alignment:** RStudio containers MUST map to the project's stable R/RStudio versions as defined in `config/r_env_manager.conf` and `kubernetes-deploy/configmaps.yaml`. Prevent unpinned runtime installations of different versions.
   - **Rationale:** Ensures consistent R/RStudio versions across all deployment tiers and AI configurations by enforcing dynamic mapping to canonical configuration files. Prevents implicit overrides that could lead to version drift and silent failures.
7. **Healthcheck:** All stateful (non-ephemeral) services must have a `healthcheck:` block.

8. **Healthcheck:** All stateful (non-ephemeral) services must have a `healthcheck:` block.

9. **Logging:** Must use the `&default-logging` YAML anchor pattern with `json-file` driver.

10. **depends_on:** Must use `condition: service_healthy` or `condition: service_completed_successfully`.

11. **No version: key:** Compose v2 does not need `version:` at the top.

12. **Labels:** Long-running services should have `com.centurylinklabs.watchtower.enable=true`.

13. **Storage:** `/Rtmp` is a 400GB ext4 host disk — it SHOULD be bind-mounted into RStudio containers for large R temp workloads (NIMBLE, matrix ops). `/tmp` inside the container uses `tmpfs` with a size cap (e.g. `size=16G`). Do NOT use `/tmp` for large R temp storage — use `/Rtmp`.

## Output Format

```
[PASS/FAIL/WARN] HC-XX: Service 'name' — description
  → Fix: specific fix instruction
```

## Reference Files

- `.ai/project.yml` — structured constraint definitions with rationale
- `.ai/agents.md` — full architecture, script chain, R runtime hardening context
