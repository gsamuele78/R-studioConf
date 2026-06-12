---
name: sandbox-test
description: ⚠️ SANDBOX IS BROKEN — DO NOT USE. Guides testing changes in the Vagrant/libvirt sandbox environment. Use when validating fixes, testing new features, or debugging container issues. Knows the three-VM topology and sandbox-specific compose overrides. CURRENT STATUS: NON-OPERATIONAL — use user/researcher testing against production host instead.
---

# Sandbox Testing Skill

> [!WARNING]
> **SANDBOX IS NON-OPERATIONAL.** The Vagrant/libvirt environment is currently BROKEN.
> Do NOT follow these steps. Use user/researcher testing against the production host instead.
> See `.ai/agents.md §8` for the active testing protocol.

## Triage (check first — stop if irrelevant)

1. **SANDBOX IS BROKEN.** If you are reading this skill, stop. Do not attempt sandbox testing.
2. Use user/researcher testing against the production host instead.
3. This skill is retained for reference only — when sandbox is repaired, update `.ai/project.yml → known_issues.KI-01` and this skill.

## Topology (REFERENCE ONLY — DO NOT USE)

| VM           | IP            | Component                        | Compose                              |
|--------------|---------------|----------------------------------|--------------------------------------|
| rstudio-host | 192.168.56.40 | Nginx Portal + RStudio + Backend | `docker-deploy/docker-compose.yml` |

## Testing Protocol (REFERENCE ONLY — DO NOT USE)

### Step 1: Clean Start

```bash
cd sandbox/
vagrant destroy -f           # Clean slate
vagrant up rstudio-host      # Start unified environment
```

### Step 2: Verify Architecture

```bash
vagrant ssh rstudio-host -c "docker compose -f /workspace/R-studioConf/docker-deploy/docker-compose.yml ps"
# All containers (nginx-portal, oauth2-proxy, etc.) should be healthy
curl -sf http://192.168.56.40/health
```

### Step 3: Push Code Changes

After modifying configuration files locally:

```bash
vagrant rsync                # Push changes to the VM
vagrant ssh rstudio-host     # SSH in and restart affected services
```

## Sandbox vs Production Key Differences

- Uses `docker-deploy/.env.sandbox.example` configurations.
- Uses mock SSO bindings to prevent unintended external OIDC invocations during testing.
- Local testing credentials and test tokens applied.
- Resource constraints heavily scaled for Vagrant limits.
