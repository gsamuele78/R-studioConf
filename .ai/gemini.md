# Gemini Agent Instructions — R-studioConf

> **Purpose:** Optimized context file for Google Gemini when working on this codebase.
> **Usage:** Include this file in Gemini's system instructions or as grounding context.

---

## Gemini-Specific Behavioral Directives

### Grounding & Accuracy

1. **Never hallucinate image names or versions.** The exact versions are extracted into `.github/copilot-instructions.md` by `generate.sh`. 
2. **Never assume Docker Swarm mode.** This project uses standalone Docker Compose v2. 
3. **Never suggest alternative tools** unless explicitly asked. The technology choices (RStudio, SSSD, Samba, Nginx, Ollama, Telemetry) are final.
4. **Ground all file references** to the directory structure. If you reference a file, it must exist in that tree.

### Response Format Preferences

- **Code blocks:** Always include the full file path as a comment on line 1.
- **Docker Compose changes:** Output the complete service block, not fragments. Gemini tends to omit `deploy:` and `healthcheck:` sections — these are MANDATORY here.
- **Shell scripts:** Output the complete file. Never produce "add this to your script" snippets.

---

## 1. Project Summary (Compact)

**What:** Secure RStudio Server data science workspace.

**Stack:**
- `rstudio-sssd` / `rstudio-samba` → RStudio Server integrated with Active Directory.
- `nginx-portal` → Frontend UI and reverse proxy.
- `oauth2-proxy` → OIDC Sidecar.
- `ollama-ai` → Local LLM inference engine.
- `telemetry-api` → Host metrics API.

**Engineering Philosophy:** Pessimistic System Engineering — assume failure; bound all resources; limit API exposures; fail fast on misconfigurations.

---

## 2. Critical Constraints Checklist

```
□ Every container has deploy.resources.limits (memory + cpus)
□ No named Docker volumes — bind mounts only
□ Scripts begin with set -euo pipefail
□ Passwords written to files, never passed as CLI arguments
□ No runtime package installation in entrypoints
□ All upstream images pinned to exact versions
□ .env files not committed to git
□ docker.sock never mounted directly — use docker-socket-proxy
□ Deploy scripts exit 1 if chown/permission setup fails
□ No external CDN calls in UI themes
□ Use jq for JSON manipulation — never sed/awk on JSON
```

---

## 3. Boot Sequence Constraints

1. **docker-socket-proxy** MUST boot BEFORE telemetry API.
2. **RStudio** startup must map tempfs directories and bind mounts correctly to Active Directory pipes.
3. Init scripts (`01_optimize_system.sh`, `10_join_domain_*.sh`, etc.) run on the HOST out-of-band, not inside containers.

---

## 4. Common Gemini Mistakes on This Project

### Mistake 1: Generating compose files with `version: "3.8"`
**Fix:** Omit the `version:` key entirely in Docker Compose V2.

### Mistake 2: Using named volumes
**Fix:** BIND MOUNTS ONLY. `volumes: - ./data:/app/data`

### Mistake 3: Omitting resource limits
**Fix:** ALWAYS define `deploy.resources.limits.memory` and `cpus`.

### Mistake 4: Suggesting `docker-compose up` (hyphenated)
**Fix:** ALWAYS use space-separated `docker compose up`.

---

*End of Gemini-specific instructions. Cross-reference with agents.md.*
