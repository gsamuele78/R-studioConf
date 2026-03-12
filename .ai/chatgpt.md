# ChatGPT Agent Instructions — Infra-IAM-PKI

> **Purpose:** Optimized context file for ChatGPT (OpenAI GPT-4/GPT-4o) when working on this codebase.
> **Usage:** Paste into Custom Instructions, GPT system prompt, or include as uploaded file in conversation.
> **Prerequisite:** Read `agents.md` first — this file supplements, not replaces, the universal context.

---

## How to Use This File with ChatGPT

ChatGPT supports several context injection methods. Choose the one that fits your workflow:

1. **Custom Instructions (Settings → Personalization):** Paste the "Compact Rules Block" from Section 2 below. This persists across all conversations.
2. **GPT Builder system prompt:** If building a custom GPT for this project, paste the full file as system instructions.
3. **File upload:** Upload this file at conversation start. Reference it with: "Follow the rules in chatgpt.md for all code you produce."
4. **Conversation preamble:** Copy-paste the Compact Rules Block at the start of any conversation about this project.

> **Important:** ChatGPT has a shorter effective context window than Claude or Gemini for instruction-following. If your conversation gets long (30+ messages), re-paste the Compact Rules Block to refresh the constraints.

---

## 1. Project Summary

**What:** Internal PKI + SSO + HPC Portal for a university research department (BiGeA, University of Bologna).

**Three isolated Docker hosts:**
- `infra-pki` → step-ca 0.29.0 + PostgreSQL 15 + Caddy L4 proxy (TCP, port 9000)
- `infra-iam` → Keycloak 26.0.7 + PostgreSQL 15 + Caddy L7 reverse proxy (HTTPS)
- `infra-ood` → Open OnDemand 4.1 (Ubuntu 24.04 debs from apt.osc.edu) + Apache mod_auth_openidc

**Engineering paradigm:** Pessimistic System Engineering — assume failure, bound all resources, verify all trust chains, fail fast on misconfiguration.

**Sandbox:** Multi-VM Vagrant/libvirt (pki-host=192.168.56.10, iam-host=.20, ood-host=.30) that mirrors production 1:1.

---

## 2. Compact Rules Block

**Copy this block into Custom Instructions or paste at conversation start:**

```
PROJECT: Infra-IAM-PKI (internal PKI + Keycloak SSO + Open OnDemand portal)
PARADIGM: Pessimistic System Engineering — assume failure, bound resources, fail fast.

HARD RULES (violating ANY of these makes the output unusable):
1. Every container MUST have deploy.resources.limits (memory + cpus)
2. BIND MOUNTS only — zero named Docker volumes
3. Shell scripts MUST start with: set -euo pipefail
4. Passwords go in FILES only — never as CLI arguments or bare env vars
5. PostgreSQL ports NEVER exposed to host
6. No runtime package installs (apk add / apt-get) in entrypoints — bake in Dockerfile
7. Pin ALL image versions — no :latest
8. .env files never committed to git
9. docker-socket-proxy for container restart — never mount docker.sock directly
10. Deploy scripts MUST exit 1 if chown/permissions fail
11. No external CDN calls in UI (airgap-compatible)
12. Use jq for JSON manipulation — never sed/awk on JSON

COMPOSE FORMAT:
- Docker Compose v2 syntax — NO "version:" key
- Command: "docker compose" (space) — NOT "docker-compose" (hyphen)
- Always include: deploy, healthcheck, logging, labels, depends_on

PINNED VERSIONS (do not change):
- step-ca: 0.29.0 | step-cli: 0.29.0 | postgres: 15-alpine
- keycloak: 26.0.7 (quay.io) | caddy: 2.9.1-alpine
- watchtower: 1.7.1 (containrrr) | docker-socket-proxy: edge (tecnativa)
- OOD: built from Dockerfile.ood using Ubuntu Noble 24.04 debs (apt.osc.edu)

WHEN GENERATING CODE:
- Output the COMPLETE file, not fragments
- Include the file path as a comment on line 1
- For compose: include ALL mandatory sections (deploy, healthcheck, logging)
- For scripts: include shebang + set -euo pipefail + color vars
- Do NOT suggest alternative tools (Traefik, Nginx, Vault, etc.) unless asked
- Do NOT add unsolicited improvements or "you might also want to" suggestions
```

---

## 3. ChatGPT-Specific Behavioral Corrections

ChatGPT has specific tendencies that conflict with this project's requirements. Each correction below addresses a documented GPT behavior pattern.

### 3.1 Tendency: Adding `version: "3.8"` to Compose Files

**GPT default behavior:** Almost always includes `version: "3.8"` or similar at the top of compose files.

**Project requirement:** Omit the `version:` key entirely. Compose v2 doesn't need it, and including it triggers deprecation warnings.

```yaml
# WRONG — ChatGPT default
version: "3.8"
services:
  db:
    image: postgres:15-alpine

# CORRECT — no version key
services:
  db:
    image: postgres:15-alpine
```

### 3.2 Tendency: Using Named Volumes

**GPT default behavior:** Generates a `volumes:` top-level section with named volumes.

**Project requirement:** Bind mounts only. Named volumes are opaque and unauditable.

```yaml
# WRONG — ChatGPT default
services:
  db:
    volumes:
      - db_data:/var/lib/postgresql/data
volumes:
  db_data:

# CORRECT — bind mount
services:
  db:
    volumes:
      - ./db_data:/var/lib/postgresql/data
```

### 3.3 Tendency: Omitting Resource Limits

**GPT default behavior:** Often generates compose services without `deploy:` block.

**Project requirement:** EVERY container must have memory and CPU limits. This is non-negotiable.

```yaml
# WRONG — missing deploy block
services:
  keycloak:
    image: quay.io/keycloak/keycloak:26.0.7

# CORRECT — always include limits
services:
  keycloak:
    image: quay.io/keycloak/keycloak:26.0.7
    deploy:
      resources:
        limits:
          memory: 2048M
          cpus: '2.0'
        reservations:
          memory: 1024M
          cpus: '0.5'
```

### 3.4 Tendency: Using `docker-compose` (Hyphenated)

**GPT default behavior:** Uses `docker-compose up -d` in examples.

**Project requirement:** Always `docker compose up -d` (Compose v2 plugin syntax).

### 3.5 Tendency: Suggesting Popular Alternatives

**GPT default behavior:** Often suggests Traefik, Nginx, HashiCorp Vault, or cert-manager when discussing reverse proxies, secrets, or certificates.

**Project requirement:** The technology choices are final. Do not suggest replacements unless explicitly asked.

| Component | This Project Uses | Do NOT Suggest |
|-----------|------------------|---------------|
| Reverse proxy | Caddy (L4 for PKI, L7 for IAM) | Traefik, Nginx, HAProxy |
| Certificate Authority | step-ca (Smallstep) | Let's Encrypt, cert-manager, CFSSL |
| Identity Provider | Keycloak | Authelia, Authentik, Dex |
| Secrets management | File-based (.env + password files) | Vault, SOPS, Docker Secrets (Swarm) |
| Container orchestration | Docker Compose (standalone) | Docker Swarm, Kubernetes (exists as future path only) |

### 3.6 Tendency: Suggesting Docker Swarm Features

**GPT default behavior:** Sometimes suggests `docker secrets`, `docker stack deploy`, or `deploy.replicas` as if Swarm mode is enabled.

**Project requirement:** This is standalone Docker Compose. Swarm features do NOT work. No `docker secrets`, no `docker stack`, no service mesh.

### 3.7 Tendency: Over-Explaining and Adding Unsolicited Suggestions

**GPT default behavior:** Adds long explanations, alternatives, and "you might also want to consider..." blocks after code.

**Project requirement:** Be concise. Output the code/config, explain only what was changed and why, and stop. The operator is an experienced LPIC-3 sysadmin — they don't need Docker or Linux basics explained.

### 3.8 Tendency: Partial Code Snippets

**GPT default behavior:** Outputs fragments like "add this to your docker-compose.yml" without full context.

**Project requirement:** Always output the complete service block (or complete file for scripts). Fragments without context lead to misplaced YAML or broken scripts.

### 3.9 Tendency: Inventing Image Names

**GPT default behavior:** May generate plausible-sounding but non-existent image names (e.g., `osc/ondemand:3.1.0`, `smallstep/step-ca:latest`).

**Project requirement:** Use ONLY the pinned versions from Section 2. If you don't know the exact image, say so — don't guess.

### 3.10 Tendency: Using `sed` for JSON

**GPT default behavior:** Often suggests `sed 's/old/new/'` for editing JSON files like `ca.json`.

**Project requirement:** Use `jq`. The project has a dedicated `patch_ca_config.sh` that demonstrates the correct pattern with URL-encoding via `jq -nr --arg v "$VAR" '$v|@uri'`.

---

## 4. Scripts Awareness

Scripts are the operational API. Operators run scripts, not `docker compose` directly.

### Script Dependency Chain (CRITICAL)

ChatGPT must understand this chain before modifying any script:

```
generate_token.sh
  └─produces─► {hostname}_join_pki.env (file with CA_URL, FINGERPRINT, TOKEN)
                    │
configure_iam_pki.sh ◄─consumes─┘
  └─modifies─► infra-iam/.env (updates CA_URL and FINGERPRINT fields)
                    │
deploy_iam.sh ◄─reads─┘
  ├─calls─► validate_iam_config.sh --pre-deploy
  ├─calls─► docker compose build + up
  └─calls─► validate_iam_config.sh --post-deploy
```

**Rule:** Never change what a script reads or produces without updating ALL callers and consumers.

### Container-Internal Scripts (No TTY)

These scripts run INSIDE Docker containers without a terminal:

- `init_step_ca.sh` — provisioner configuration (in `configurator` container)
- `patch_ca_config.sh` — JSON patching (in `step-ca` entrypoint)
- `fetch_pki_root.sh` — cert download (in `iam-init` container)
- `fetch_ad_cert.sh` — LDAPS cert fetch (in `iam-init` container)
- `renew_certificate.sh` — cert lifecycle (in `iam-renewer` container)

**NEVER add `read -p`, `read -rp`, or any interactive input to these scripts.** They will hang or crash the container because there is no TTY attached.

### Config Reading Pattern

The project reads `.env` files with `grep + cut`, never with `source`:

```bash
# CORRECT — safe with special characters in values
CA_URL=$(grep "^CA_URL=" "$ENV_FILE" | cut -d= -f2- | tr -d '"')

# WRONG — breaks on passwords with special chars, pollutes shell namespace
source .env
```

---

## 5. Sandbox Awareness

### What It Is

Three Vagrant/libvirt VMs on a private network (192.168.56.0/24), each with its own Docker daemon. This is NOT a single-host Docker stack.

| VM | IP | Component | Compose Source |
|----|-----|-----------|---------------|
| pki-host | .10 | step-ca + Postgres + Caddy | `infra-pki/docker-compose.yml` (production, no override) |
| iam-host | .20 | Keycloak + Postgres + Caddy | `sandbox/iam-sandbox.yml` (sandbox override) |
| ood-host | .30 | Open OnDemand + Apache | `sandbox/ood-sandbox.yml` (sandbox override) |

### Critical Sandbox Mechanics

1. **PKI uses the REAL production compose** — no sandbox override. Changes to `infra-pki/docker-compose.yml` directly affect the sandbox.
2. **Fingerprint auto-injection:** IAM and OOD Vagrant provisioners have a retry loop (up to 5 minutes) that fetches `http://192.168.56.10/fingerprint/root_ca.fingerprint` via curl. Breaking this endpoint breaks all sandbox VM provisioning.
3. **IAM sandbox differences:** Keycloak runs in `start-dev` mode (HTTP only), no renewer, no watchtower, simple Caddy reverse proxy.
4. **OOD builds from the real Dockerfile.ood** (Ubuntu Noble debs from apt.osc.edu, ~15 min first build).
5. **`.env.sandbox` files are committed** — they contain only test-safe credentials.

### Known Broken: `full_sandbox_launcher.sh`

This script is documented as broken (dangling EOF, references non-existent compose file). Do NOT reference or try to fix it unless explicitly asked.

---

## 6. Prompt Templates for ChatGPT

### Template: Modify a Compose Service

```
I need to modify the [SERVICE] service in [STACK]/docker-compose.yml.

Change: [DESCRIPTION]

Follow the rules from chatgpt.md:
- Output the COMPLETE service block (not a fragment)
- Include deploy.resources.limits, healthcheck, logging, depends_on
- No named volumes — bind mounts only
- No version: key in compose
- Pin all image versions
- Explain ONLY what changed and why
```

### Template: Write a New Script

```
Create a new script: scripts/[PATH]/[NAME].sh

Purpose: [DESCRIPTION]

Follow the rules from chatgpt.md:
- Full file with #!/bin/bash and set -euo pipefail
- Use color vars (GREEN, RED, BLUE, YELLOW, NC)
- Path resolution with SCRIPT_DIR pattern
- If destructive: require confirmation
- If it runs in a container: NO interactive input (no read -p)
- Read .env with grep+cut, never source
```

### Template: Debug a Container

```
Container [NAME] is [SYMPTOM].
Stack: [pki|iam|ood]
Environment: [production|sandbox]

Before suggesting fixes:
1. Check the boot sequence — which containers must be healthy first?
2. Check if this is a known issue (Keycloak OOM, fingerprint path, renewer loop)
3. Suggest diagnostic commands FIRST, then fixes
4. Do NOT suggest replacing any technology component
```

---

## 7. Version Pinning Quick Reference

ChatGPT frequently drifts on version numbers across long conversations. Re-check against this table:

| Component | Correct Version | Common GPT Mistake |
|-----------|----------------|-------------------|
| step-ca | `0.29.0` | Uses `latest` or `0.25.2` (old K8s manifest version) |
| step-cli | `0.29.0` | Uses `latest` or mismatches with step-ca |
| Keycloak | `26.0.7` | Uses `latest`, `23.0` (old K8s), or `24.x` |
| PostgreSQL | `15-alpine` | Uses `16-alpine` or `latest` |
| Caddy | `2.9.1-alpine` (IAM) | Uses `latest` or generic `caddy:2` |
| Caddy PKI | Custom build from `infra-pki/caddy/Dockerfile` | Suggests stock caddy image (missing L4 plugin) |
| Watchtower | `1.7.1` from `containrrr` | Uses `latest` or wrong registry (`nickfedor`) |
| OOD | Ubuntu Noble 24.04 debs | Invents `osc/ondemand:3.1.0` (doesn't exist) |

---

## 8. ChatGPT Context Refresh Protocol

ChatGPT's instruction-following degrades over long conversations. If you notice GPT:

- Adding `version:` to compose files
- Using named volumes
- Omitting resource limits
- Suggesting Traefik/Nginx
- Using `docker-compose` (hyphenated)
- Inventing image names

**Action:** Paste the Compact Rules Block from Section 2 again with the prefix: "REMINDER: Follow these rules strictly for all remaining code in this conversation."

---

## 9. Memory Aid — Key Facts

ChatGPT doesn't have persistent memory across conversations (unless using the Memory feature). Paste these facts when starting a new conversation:

- step-ca version is 0.29.0 (not 0.25.2)
- Keycloak version is 26.0.7 (not 23.0)
- OOD is built from Dockerfile.ood with Ubuntu Noble debs — there is NO Docker Hub image
- Caddy PKI is a CUSTOM BUILD with caddy-l4 plugin — not stock Caddy
- The Keycloak theme uses FreeMarker (.ftl) — not Thymeleaf or JSP
- Sandbox IPs: PKI=192.168.56.10, IAM=192.168.56.20, OOD=192.168.56.30
- The `configurator` container exits after setup — exit code 0 is success, not failure
- Fingerprint is served via HTTP :80 at `/fingerprint/root_ca.fingerprint` — not HTTPS
- Active Directory uses LDAPS on port 636
- UI branding: Unibo Red #C80E0F + glassmorphism + system-ui fonts (no CDN)

---

*End of ChatGPT-specific instructions. Always cross-reference with agents.md for the complete picture.*
