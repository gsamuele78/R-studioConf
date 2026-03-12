# ChatGPT Agent Instructions — R-studioConf

> **Purpose:** Optimized context file for ChatGPT (OpenAI GPT-4/GPT-4o) when working on this codebase.
> **Usage:** Paste into Custom Instructions, GPT system prompt, or include as uploaded file in conversation.

---

## How to Use This File with ChatGPT

1. **Custom Instructions (Settings → Personalization):** Paste the "Compact Rules Block" from Section 2 below. 
2. **GPT Builder system prompt:** Paste the full file as system instructions.
3. **File upload:** Upload this file at conversation start. Reference it with: "Follow the rules in chatgpt.md for all code you produce."

---

## 1. Project Summary

**What:** Secure RStudio Server data science workspace, serving R over HTTP integrated with Active Directory.

**Stack:**
- `rstudio-sssd` / `rstudio-samba` → RStudio Server data science nodes.
- `nginx-portal` → Frontend UI and reverse proxy.
- `oauth2-proxy` → OIDC Sidecar.
- `ollama-ai` → Local LLM inference engine.
- `telemetry-api` → Host metrics API.

**Engineering paradigm:** Pessimistic System Engineering — assume failure, bound all resources, verify all trust chains, fail fast on misconfiguration.

---

## 2. Compact Rules Block

**Copy this block into Custom Instructions:**

```
PROJECT: R-studioConf (RStudio + Nginx + Ollama)
PARADIGM: Pessimistic System Engineering — assume failure, bound resources, fail fast.

HARD RULES (violating ANY of these makes the output unusable):
1. Every container MUST have deploy.resources.limits (memory + cpus)
2. BIND MOUNTS only — zero named Docker volumes
3. Shell scripts MUST start with: set -euo pipefail
4. Passwords go in FILES only — never as CLI arguments or bare env vars
5. No runtime package installs (apk add / apt-get) in entrypoints — bake in Dockerfile
6. Pin ALL image versions — no :latest
7. .env files never committed to git
8. docker-socket-proxy for container API — never mount docker.sock directly
9. Deploy scripts MUST exit 1 if chown/permissions fail
10. No external CDN calls in UI (airgap-compatible)
11. Use jq for JSON manipulation — never sed/awk on JSON

COMPOSE FORMAT:
- Docker Compose v2 syntax — NO "version:" key
- Command: "docker compose" (space) — NOT "docker-compose" (hyphen)

WHEN GENERATING CODE:
- Output the COMPLETE file, not fragments
- Include the file path as a comment on line 1
- For compose: include ALL mandatory sections (deploy, healthcheck, logging)
- Do NOT add unsolicited improvements or "you might also want to" suggestions
```

---

## 3. ChatGPT-Specific Behavioral Corrections

### 3.1 Tendency: Adding `version: "3.8"` to Compose Files
**GPT default behavior:** Almost always includes `version: "3.8"`.
**Project requirement:** Omit the `version:` key entirely. Compose v2 doesn't need it.

### 3.2 Tendency: Using Named Volumes
**GPT default behavior:** Generates a `volumes:` top-level section with named volumes.
**Project requirement:** Bind mounts only. Named volumes are opaque and unauditable.

### 3.3 Tendency: Omitting Resource Limits
**GPT default behavior:** Often generates compose services without `deploy:` block.
**Project requirement:** EVERY container must have memory and CPU limits.

### 3.4 Tendency: Suggesting Popular Alternatives
**Project requirement:** The technology choices are final. Do not suggest replacing Nginx with Traefik, or RStudio with Jupyter unless explicitly asked.

### 3.5 Tendency: Partial Code Snippets
**GPT default behavior:** Outputs fragments like "add this to your docker-compose.yml" without full context.
**Project requirement:** Always output the complete service block (or complete file for scripts). 

### 3.6 Tendency: Suggesting `sed` for JSON files
**Project requirement:** Use `jq` instead.

---
*End of ChatGPT-specific instructions.*
