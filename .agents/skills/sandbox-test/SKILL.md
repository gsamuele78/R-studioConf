---
name: sandbox-test
description: Guides testing changes in the Vagrant/libvirt sandbox environment. Use when validating fixes, testing new features, or debugging container issues. Knows the three-VM topology and sandbox-specific compose overrides.
---

# Sandbox Testing Skill

You are helping test a change in the Infra-IAM-PKI Vagrant sandbox.

## Topology

| VM | IP | Component | Compose |
|----|-----|-----------|---------|
| pki-host | 192.168.56.10 | step-ca + Postgres + Caddy L4 | `infra-pki/docker-compose.yml` (PRODUCTION — no override) |
| iam-host | 192.168.56.20 | Keycloak + Postgres + Caddy | `sandbox/iam-sandbox.yml` (sandbox override) |
| ood-host | 192.168.56.30 | Open OnDemand + Apache | `sandbox/ood-sandbox.yml` (sandbox override) |

## CRITICAL: PKI Uses Production Compose

Changes to `infra-pki/docker-compose.yml` DIRECTLY affect the sandbox. There is no sandbox override for PKI.

## Testing Protocol

### Step 1: Clean Start
```bash
cd sandbox/
vagrant destroy -f           # Clean slate
vagrant up pki-host          # PKI must start first
```

### Step 2: Verify PKI
```bash
vagrant ssh pki-host -c "docker compose -f /workspace/Infra-Iam-PKI/infra-pki/docker-compose.yml ps"
# All containers should be healthy
curl -sf http://192.168.56.10/fingerprint/root_ca.fingerprint
# Must return a SHA256 fingerprint string
```

### Step 3: Start Dependent VMs
```bash
vagrant up iam-host          # Fetches fingerprint from pki-host automatically
vagrant up ood-host          # Same fingerprint fetch
```

### Step 4: Verify IAM
```bash
vagrant ssh iam-host -c "docker compose -f /workspace/Infra-Iam-PKI/sandbox/iam-sandbox.yml ps"
# Keycloak should be healthy
curl -sf http://192.168.56.20/health
```

### Step 5: Push Code Changes
After modifying files locally:
```bash
vagrant rsync                # Push changes to all VMs
vagrant ssh pki-host         # SSH in and restart affected service
```

## Sandbox vs Production Key Differences

- Keycloak: `start-dev` (HTTP, no HTTPS)
- No iam-renewer (no cert lifecycle in sandbox)
- No watchtower
- Caddy IAM: simple `reverse-proxy --from :80 --to KC:8080`
- `.env.sandbox` values are safe for testing

## Known Broken

`full_sandbox_launcher.sh` is broken (TD-09). Do not use it.
