---
name: compose-constraint-audit
description: Validates Docker Compose files against the 12 hard constraints of the R-studioConf project. Use when reviewing, editing, or creating any docker-compose.yml file. Checks resource limits, volume types, image pinning, port exposure, and all other pessimistic engineering invariants.
---

# Compose Constraint Audit Skill

You are auditing a Docker Compose file for the R-studioConf project. This project follows **Pessimistic System Engineering** — assume failure, bound all resources, fail fast.

## Checklist (check EVERY item)

For EACH service in the compose file, verify:

1. **HC-01 Resource Limits:** Has `deploy.resources.limits` with BOTH `memory` and `cpus`
   - Keycloak (Java): max 2048M memory, Xmx must be BELOW container limit
   - PostgreSQL: 512M-1024M typical
   - Init/ephemeral containers: 128M-512M
   - Caddy: 256M

2. **HC-02 No Named Volumes:** All `volumes:` entries use bind mounts (`./path:/path`), NOT named volumes. There must be NO top-level `volumes:` section.

3. **HC-05 No DB Port Exposure:** PostgreSQL services must NOT have a `ports:` section.

4. **HC-07 Pinned Versions:** Every `image:` must have an explicit version tag. No `:latest`. Correct versions:
   - Read `.ai/extracted_versions.env` for current pinned versions
   - If that file doesn't exist, check actual compose files in `docker-deploy/docker-compose.yml`

5. **HC-09 No docker.sock:** Only `docker-socket-proxy` and `watchtower` may mount `/var/run/docker.sock`. All other services must NOT.

6. **Healthcheck:** All stateful (non-ephemeral) services must have `healthcheck:` block.

7. **Logging:** Must use the `&default-logging` YAML anchor pattern with `json-file` driver.

8. **depends_on:** Must use `condition: service_healthy` or `condition: service_completed_successfully`.

9. **No version: key:** Compose v2 does not need `version:` at the top.

10. **Labels:** Long-running services should have `com.centurylinklabs.watchtower.enable=true`.

## Output Format

For each finding:
```
[PASS/FAIL/WARN] HC-XX: Service 'name' — description
  → Fix: specific fix instruction
```

## Resources

Read the full constraint documentation:
- `.ai/project.yml` — structured constraint definitions
- `.ai/agents.md` — narrative documentation with rationale
