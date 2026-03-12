---
name: sandbox-test
description: Guides testing changes in the Vagrant/libvirt sandbox environment. Use when validating fixes, testing new features, or debugging container issues. Knows the three-VM topology and sandbox-specific compose overrides.
---

# Sandbox Testing Skill

You are helping test a change in the R-studioConf Vagrant sandbox.

## Topology

| VM           | IP            | Component                        | Compose                              |
|--------------|---------------|----------------------------------|--------------------------------------|
| rstudio-host | 192.168.56.40 | Nginx Portal + RStudio + Backend | `docker-deploy/docker-compose.yml` |

## Testing Protocol

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

- Uses `docker-deploy/.env.sandbox` configurations.
- Uses mock SSO bindings to prevent unintended external OIDC invocations during testing.
- Local testing credentials and test tokens applied.
- Resource constraints heavily scaled for Vagrant limits.
