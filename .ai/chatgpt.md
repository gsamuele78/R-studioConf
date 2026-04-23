# ChatGPT Agent Instructions — R-studioConf

> **For:** OpenAI GPT-4 / GPT-4o working on this codebase.
> **Usage:** Paste "Compact Rules Block" into Custom Instructions, or upload this file at conversation start.

---

## Compact Rules Block (copy to Custom Instructions)

```
PROJECT: R-studioConf (RStudio + Nginx + Ollama + SSSD/Samba)
PARADIGM: Pessimistic System Engineering — assume failure, bound resources, fail fast.

HARD RULES (violating ANY makes output unusable):
1. Every container MUST have deploy.resources.limits (memory + cpus)
2. BIND MOUNTS only — zero named Docker volumes
3. Shell scripts MUST start with: #!/usr/bin/env bash + set -euo pipefail
4. Passwords go in FILES only — never as CLI arguments or bare env vars
5. No runtime package installs (apk add / apt-get) in entrypoints — bake in Dockerfile
6. Pin ALL external image versions — no :latest (local botanical/* images exempt)
7. .env files never committed to git
8. docker-socket-proxy for container API — never mount docker.sock directly
9. Deploy scripts MUST exit 1 if chown/permissions fail
10. No external CDN calls in UI (airgap/Zero-Trust)
11. Use jq for JSON — never sed/awk on JSON
12. R large temp storage → /Rtmp (400GB ext4 disk), NOT /tmp
13. BLAS → libopenblas0-serial, NOT libopenblas0-pthread (pthread causes SIGSEGV)

COMPOSE FORMAT: Docker Compose v2 — NO "version:" key — "docker compose" (space)
CODE OUTPUT: Complete files only — path comment on line 1 — no "add this to your script" snippets
```

---

## GPT-Specific Behavioral Corrections

| Tendency | Fix |
|---|---|
| Adding `version: "3.8"` to Compose | Omit `version:` entirely |
| Named volumes top-level section | Bind mounts only: `./data:/app/data` |
| Omitting `deploy:` block | EVERY container needs memory + CPU limits |
| Suggesting Traefik / Jupyter / alternatives | Stack is final — do not suggest alternatives |
| Partial code snippets | Always output the complete service block or complete script file |
| `sed` for JSON files | Use `jq` |
| `/tmp` for large R temp storage | Use `/Rtmp` |
| Validating against sandbox | Sandbox BROKEN — reference user/researcher testing only |

---

*Cross-reference `.ai/agents.md` for full architecture, script inventory, and constraint rationale.*
