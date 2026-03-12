# Gemini Agent Instructions — Infra-IAM-PKI

> **Purpose:** Optimized context file for Google Gemini when working on this codebase.
> **Usage:** Include this file in Gemini's system instructions or as grounding context.
> **Prerequisite:** Read `agents.md` first — this file supplements, not replaces, the universal context.

---

## Gemini-Specific Behavioral Directives

### Grounding & Accuracy

Gemini has strong grounding capabilities. For this project, apply these grounding rules:

1. **Never hallucinate image names or versions.** The exact versions are listed in Section 3 below. If you're unsure, state that explicitly rather than guessing.
2. **Never assume Docker Swarm mode.** This project uses standalone Docker Compose v2. Features like `docker secrets`, `deploy.replicas` (in non-Compose-spec context), and `docker stack deploy` do NOT apply.
3. **Never suggest alternative tools** unless explicitly asked. The technology choices (step-ca, Keycloak, Caddy, PostgreSQL) are final.
4. **Ground all file references** to the directory structure in `agents.md` Section 3. If you reference a file, it must exist in that tree.

### Response Format Preferences

Gemini performs best with structured, clear outputs. For this project:

- **Code blocks:** Always include the full file path as a comment on line 1.
- **Docker Compose changes:** Output the complete service block, not fragments. Gemini tends to omit `deploy:` and `healthcheck:` sections — these are MANDATORY here.
- **Shell scripts:** Output the complete file. Never produce "add this to your script" snippets.
- **Explanations:** Use numbered steps. This project has strict ordering requirements (boot sequences, dependency chains).
- **When multiple approaches exist:** Present the one that aligns with this project's Pessimistic System Engineering paradigm, then briefly note alternatives.

### Gemini-Specific Strengths to Leverage

- **Long context window:** This project has 100+ files. Gemini can process them all. Use this to cross-reference compose files against scripts against docs.
- **Code generation:** Gemini produces clean shell scripts. Channel this into the project's coding standards (Section 8.1 of `agents.md`).
- **Structured data:** When generating `.env` files, `docker-compose.yml` blocks, or Kubernetes manifests, Gemini's structured output capability is valuable. Always validate against the invariants.

---

## 1. Project Summary (Compact)

**What:** Internal PKI + SSO + HPC Portal infrastructure for a university research department.

**Stack:**
- `infra-pki` → step-ca 0.29.0 + PostgreSQL 15 + Caddy L4 (TCP proxy)
- `infra-iam` → Keycloak 26.0.7 + PostgreSQL 15 + Caddy L7 (HTTPS reverse proxy)  
- `infra-ood` → Open OnDemand 4.1 (Ubuntu 24.04 debs) + Apache mod_auth_openidc

**Topology:** Three isolated Docker hosts communicating over private network. NOT a single-host Docker Compose stack.

**Engineering Philosophy:** Pessimistic — assume every component will fail; bound all resources; verify all trust chains; fail fast on misconfigurations.

---

## 2. Critical Constraints Checklist

Before generating ANY code for this project, Gemini MUST verify against this checklist:

```
□ Every container has deploy.resources.limits (memory + cpus)
□ No named Docker volumes — bind mounts only
□ Scripts begin with set -euo pipefail
□ Passwords written to files, never passed as CLI arguments
□ PostgreSQL ports not exposed to host network
□ No runtime package installation (apk add, apt-get) in entrypoints
□ All upstream images pinned to exact versions
□ .env files not committed to git
□ docker.sock never mounted directly — use docker-socket-proxy
□ Deploy scripts exit 1 if chown/permission setup fails
□ No external CDN calls in UI themes
□ PG credentials URL-encoded via jq (not sed/awk)
□ Docker Compose v2 syntax (no version: key, use docker compose not docker-compose)
```

---

## 3. Pinned Image Versions

**CRITICAL — Do not use any other versions:**

| Image | Version | Registry | Notes |
|-------|---------|----------|-------|
| `smallstep/step-ca` | `0.29.0` | Docker Hub | CA server |
| `smallstep/step-cli` | `0.29.0` | Docker Hub | CLI for configurator/init/fingerprint |
| `postgres` | `15-alpine` | Docker Hub | Both PKI and IAM databases |
| `keycloak` | `26.0.7` | `quay.io/keycloak/keycloak` | Identity Provider |
| `caddy` | `2.9.1-alpine` | Docker Hub | IAM L7 proxy (stock image) |
| `caddy` | custom build | Local `infra-pki/caddy/Dockerfile` | PKI L4 proxy (with caddy-l4 plugin) |
| `watchtower` | `1.7.1` | `containrrr/watchtower` | NOT `nickfedor/watchtower` (that was a bug) |
| `docker-socket-proxy` | `edge` | `tecnativa/docker-socket-proxy` | Minimal API surface |
| Open OnDemand | `4.1.0` | `apt.osc.edu` (deb packages) | Built from `Dockerfile.ood` — NO Docker Hub image exists |

---

## 4. Boot Sequence Dependency Graph

Gemini should use this to validate `depends_on` chains and understand startup ordering:

### PKI Stack

```
init-files ──(completed)──► postgres ──(healthy)──► step-ca ──(healthy)──► configurator
                                                       │                       │
                                                       ├──(healthy)──► caddy   │
                                                       │                       │
                                                       └──(healthy)──► fingerprint-writer
                                                                              │
                                                       init-files ──(completed)──┘
```

### IAM Stack

```
iam-init ──(completed)──► iam-db ──(healthy)──► iam-keycloak
    │                                                │
    ├──(completed)──► iam-renewer                     │
    │                    │                            │
    │          docker-socket-proxy ──(started)──┘      │
    │                                                │
    └──(completed)──► caddy                          │
```

### Sandbox Cross-Host

```
pki-host ──(fingerprint available via HTTP :80)──► iam-host
                                                  │
pki-host ──(fingerprint available via HTTP :80)──► ood-host
```

---

## 5. Common Gemini Mistakes on This Project

### Mistake 1: Generating compose files with `version: "3.8"`
**Fix:** Omit the `version:` key entirely. Compose v2 doesn't need it.

### Mistake 2: Using named volumes
```yaml
# WRONG
volumes:
  step_data:
services:
  step-ca:
    volumes:
      - step_data:/home/step

# CORRECT
services:
  step-ca:
    volumes:
      - ./step_data:/home/step
```

### Mistake 3: Omitting resource limits
```yaml
# WRONG — missing deploy block
services:
  db:
    image: postgres:15-alpine

# CORRECT
services:
  db:
    image: postgres:15-alpine
    deploy:
      resources:
        limits:
          memory: 512M
          cpus: '1.0'
        reservations:
          memory: 256M
```

### Mistake 4: Passing secrets as environment variables
```yaml
# WRONG — password visible in docker inspect
environment:
  - CA_PASSWORD=mysecretpassword

# CORRECT — file-based secret
environment:
  - DOCKER_STEPCA_INIT_PASSWORD_FILE=/home/step/secrets/password
volumes:
  - ./step_data/secrets:/home/step/secrets
```

### Mistake 5: Suggesting `docker-compose up` (hyphenated binary)
**Fix:** Always use `docker compose up` (plugin syntax).

### Mistake 6: Recommending `osc/ondemand:3.1.0` Docker image
**Fix:** That image doesn't exist. OOD is built from source using `Dockerfile.ood` which installs official deb packages from `apt.osc.edu`.

### Mistake 7: Using `sed` to modify JSON (ca.json)
**Fix:** Use `jq`. The project has a dedicated `patch_ca_config.sh` that uses `jq` for safe JSON manipulation with URL-encoded credentials.

### Mistake 8: Forgetting Docker bridge CIDR in ALLOWED_IPS
When scripts run health checks from the host, traffic routes through the Docker bridge gateway (typically `172.18.0.0/16`). If this CIDR isn't in `ALLOWED_IPS`, Caddy L4 silently drops the connection.

---

## 6. Scripts Operational Awareness

**CRITICAL:** Scripts are the primary operational interface. Operators never run `docker compose` directly.

### Script Coupling Warning

Scripts have hidden dependencies. Modifying one without checking its callers/consumers will break workflows:

```
generate_token.sh → produces → {host}_join_pki.env → consumed by → configure_iam_pki.sh
configure_iam_pki.sh → modifies → infra-iam/.env → read by → deploy_iam.sh
deploy_iam.sh → calls → validate_iam_config.sh (pre + post)
```

### Script Categories

| Category | Scripts | Runs Where | Interactive? |
|----------|---------|-----------|-------------|
| **Deployment** | deploy_pki.sh, deploy_iam.sh, deploy_ood.sh | Operator terminal | Yes (confirmations) |
| **Destruction** | reset_pki.sh, reset_iam.sh, reset_ood.sh | Operator terminal | Yes (type `yes`) |
| **Configuration** | configure_pki.sh, configure_iam.sh, configure_iam_pki.sh | Operator terminal | Yes (TUI menus) |
| **Validation** | validate_config.sh, validate_iam_config.sh, verify_pki.sh | Operator terminal or CI | No |
| **Container-internal** | init_step_ca.sh, patch_ca_config.sh, fetch_pki_root.sh, renew_certificate.sh | Inside Docker containers | **NEVER** (no TTY) |
| **Client portable** | join_pki.sh, setup_client_trust.sh | Remote hosts | Yes (menu or CLI args) |
| **Utility** | backup_pki.sh, generate_token.sh, manage_host_trust.sh, maintenance_docker.sh | Operator terminal | Yes |

### Key Script Rule for Gemini

**Container-internal scripts MUST NEVER use `read -p`, `read -rp`, or any interactive input.** They run inside containers without a TTY. If you add input prompts to these scripts, they will hang or crash the container.

---

## 7. Sandbox Environment Awareness

### What the Sandbox IS

A **multi-VM Vagrant/libvirt** environment with 3 VMs on a private network (`192.168.56.0/24`). Each VM has its own Docker daemon — they communicate over the network, NOT shared Docker networks. This mirrors production topology exactly.

### What the Sandbox is NOT

- NOT a single-host Docker Compose stack
- NOT a simplified/mocked version of the services
- NOT optional — it's the validation gate for all production changes

### Sandbox vs Production Compose Files

| Component | Production Compose | Sandbox Compose | Key Differences |
|-----------|-------------------|-----------------|----------------|
| PKI | `infra-pki/docker-compose.yml` | **Same file** (no override) | None — PKI runs identically |
| IAM | `infra-iam/docker-compose.yml` | `sandbox/iam-sandbox.yml` | KC in `start-dev`, no renewer, no watchtower, simple Caddy |
| OOD | `infra-ood/docker-compose.yml` | `sandbox/ood-sandbox.yml` | Same Dockerfile.ood, only env vars differ |

### Critical Sandbox Mechanics

1. **FINGERPRINT auto-injection:** The Vagrantfile IAM/OOD provisioners have a retry loop (60 × 5s = 5 min) that fetches `http://192.168.56.10/fingerprint/root_ca.fingerprint` via curl. If you change how PKI serves the fingerprint, you break cross-VM provisioning.

2. **rsync excludes:** The Vagrantfile excludes `.git/`, `sandbox/.vagrant/`, `step_data/`, `db_data/`, `logs/` from sync. New data directories need to be added to this list.

3. **`full_sandbox_launcher.sh` is broken** (known issue TD-09). Don't reference or use it.

### Gemini Rule for Sandbox Changes

When generating sandbox-related code:
- Changes to `infra-pki/docker-compose.yml` directly affect sandbox (no override layer)
- Changes to `.env.sandbox` files are safe to commit (test values only)
- Changes to `sandbox/*.yml` files only affect sandbox, never production
- Always verify the rsync exclude list if adding new directories

---

## 8. File Modification Decision Tree

When asked to modify a file, follow this tree:

```
Is it a docker-compose.yml?
├── YES → Include FULL service block with deploy, healthcheck, logging, labels, depends_on
│         → Verify all constraints from Section 2 checklist
│         → Check boot sequence from Section 4
│
Is it a shell script?
├── YES → Include full file with shebang + set -euo pipefail
│         → Use project color scheme (GREEN/RED/BLUE/YELLOW/NC)
│         → Add [Step N/M] prefixes for multi-step operations
│         → Resolve paths with SCRIPT_DIR pattern
│
Is it a Dockerfile?
├── YES → No runtime package installs in entrypoint
│         → Pin base image version
│         → Prefer alpine variants
│         → If init container: FROM step-cli:0.29.0
│
Is it a .env file?
├── YES → NEVER include real passwords
│         → Use placeholder values like "change_me_XXX"
│         → Include comments explaining each variable
│
Is it a Kubernetes manifest?
├── YES → Note: K8s manifests have version drift with Docker compose
│         → Verify resource limits, liveness/readiness probes
│         → NetworkPolicies are default-deny
│
Is it documentation?
├── YES → Markdown format
│         → Code blocks with language specifier
│         → GitHub-style admonitions
```

---

## 9. Environment-Specific Configuration

### Production

- Real FQDNs: `ca.biome.unibo.it`, `sso.biome.unibo.it`, `ood.biome.unibo.it`
- Active Directory: `ad.biome.unibo.it:636`
- Strong passwords (generated, never default)
- `ALLOWED_IPS` restricted to specific university subnets

### Sandbox (Vagrant/libvirt)

- IPs: PKI=192.168.56.10, IAM=192.168.56.20, OOD=192.168.56.30
- Keycloak runs in `start-dev` mode (HTTP, no HTTPS)
- Passwords: `sandbox_*` prefix (safe for testing)
- `ALLOWED_IPS` includes all RFC-1918 + sandbox network
- FINGERPRINT is auto-fetched from PKI host via curl during Vagrant provisioning
- `.env.sandbox` files ARE committed (test values only)

### Key Sandbox Differences from Production

| Aspect | Production | Sandbox |
|--------|-----------|---------|
| Keycloak mode | `start --optimized` | `start-dev` |
| Caddy IAM | ACME cert from internal PKI | Simple `reverse-proxy --from :80 --to KC:8080` |
| iam-renewer | Full cert lifecycle | Omitted in sandbox |
| DNS/FQDN | Real domains | IP addresses as hostnames |
| Compose file | `infra-*/docker-compose.yml` | `sandbox/*-sandbox.yml` |

---

## 10. Gemini Function Calling Context

If using Gemini with function calling / tool use in an IDE context:

### File Operations
- **Before editing:** Always read the current file content first.
- **For compose files:** After editing, validate with `docker compose -f <file> config`.
- **For shell scripts:** After editing, validate with `bash -n <file>`.

### Search Operations
- **For finding implementations:** Search for function/variable names across `scripts/` directory.
- **For finding configs:** Check both the compose file AND the corresponding `.env` file.
- **For understanding flows:** Check both the script AND the compose service that calls it.

### Code Generation
- **Prefer editing over rewriting.** Surgical changes maintain consistency.
- **When creating new files:** Follow the patterns of existing files in the same directory.
- **Include comments** that reference the invariant being satisfied (e.g., `# HC-01: Resource limits`).

---

## 11. Testing & Validation Commands

Gemini should suggest these verification steps after any change:

```bash
# Validate compose syntax
docker compose -f infra-pki/docker-compose.yml config > /dev/null
docker compose -f infra-iam/docker-compose.yml config > /dev/null
docker compose -f infra-ood/docker-compose.yml config > /dev/null

# Validate shell script syntax
bash -n scripts/infra-pki/deploy_pki.sh
bash -n scripts/infra-iam/deploy_iam.sh

# Check for common violations
grep -r "docker-compose " scripts/     # Should find 0 results (use docker compose)
grep -r ":latest" infra-*/docker-compose.yml  # Should find 0 upstream :latest
grep -rn "apk add\|apt-get install" infra-*/docker-compose.yml  # Should be 0 (only in Dockerfiles)

# Validate resource limits are present
for f in infra-*/docker-compose.yml; do
  echo "=== $f ==="
  # Count services vs services with limits
  yq '.services | keys | length' "$f"
  yq '.services | to_entries | map(select(.value.deploy.resources.limits)) | length' "$f"
done

# Run PKI validation suite
scripts/infra-pki/validate_config.sh --pre-deploy
scripts/infra-iam/validate_iam_config.sh --pre-deploy
```

---

## 12. Quick Reference Card

| Question | Answer |
|----------|--------|
| What's the CA? | step-ca 0.29.0 |
| What's the IdP? | Keycloak 26.0.7 |
| What's the HPC portal? | Open OnDemand 4.1 (Ubuntu Noble debs) |
| What DB? | PostgreSQL 15-alpine (separate instance per stack) |
| What proxy? | Caddy (L4 for PKI, L7 for IAM) |
| Named volumes? | **NO.** Bind mounts only. |
| docker-compose (hyphen)? | **NO.** `docker compose` (v2 plugin). |
| version: in compose? | **NO.** Omit it. |
| Runtime apk add? | **NO.** Bake in Dockerfile. |
| Mount docker.sock? | **NO.** Use docker-socket-proxy. |
| Passwords in CLI? | **NO.** File-based only. |
| External CDN? | **NO.** Airgap-compatible. |
| Sandbox IPs? | PKI=.10, IAM=.20, OOD=.30 (192.168.56.0/24) |
| KC theme engine? | FreeMarker (.ftl) |
| UI colors? | Unibo Red #C80E0F + glassmorphism |
| Branding ref? | bigea.unibo.it |

---

*End of Gemini-specific instructions. Always cross-reference with agents.md for the complete picture.*
