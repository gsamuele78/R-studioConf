# Gemini Agent Instructions — R-studioConf

> **For:** Google Gemini working on this codebase.
> **Load alongside:** `.ai/agents.md` — project summary is there, not repeated here.

---

## Gemini-Specific Behavioral Corrections

### Grounding & Accuracy

1. **Never hallucinate image names or versions.** Check `.ai/extracted_versions.env` for pinned external images. Local `botanical-*` images use `:latest` by convention — they are locally built, never pulled from a registry.
2. **Never assume Docker Swarm mode.** Standalone Docker Compose v2 only.
3. **Never suggest alternative tools** unless explicitly asked. RStudio, SSSD, Samba, Nginx, Ollama are final technology choices.
4. **Never reference files that don't exist.** Ground all file references to the actual directory tree.
5. **Never assume optimistic conditions.** Honest not optimistic prd system design best practices from system and architect engineer. If a path might not exist, check. If a service might be unavailable, handle it. Pessimistic System Engineering — assume failure.

### Output Format

- **Code blocks:** Full file path as a comment on line 1.
- **Docker Compose:** Complete service block. Gemini tends to omit `deploy:` and `healthcheck:` — these are MANDATORY.
- **Shell scripts:** Complete file. Never produce "add this to your script" snippets.
- **R config:** Reference `/Rtmp` for large temp storage, NOT `/tmp`.

---

## Common Gemini Mistakes on This Project

| Mistake | Fix |
|---|---|
| Adding `version: "3.8"` to Compose | Omit `version:` key entirely (Compose v2) |
| Using named volumes | `volumes: - ./data:/app/data` — bind mounts ONLY |
| Omitting resource limits | ALWAYS: `deploy.resources.limits.memory` + `cpus` |
| `docker-compose up` (hyphenated) | `docker compose up` (space) |
| `/tmp` for R large temp files | Use `/Rtmp` (400GB ext4 disk) |
| `libopenblas0-pthread` | Use `libopenblas0-serial` (pthread causes SIGSEGV) |
| Referencing sandbox for validation | Sandbox BROKEN — use user/researcher testing |
| Activating `src/biome_core_rust` | DORMANT — not deployed |

---

## Pre-Response Constraints Checklist

```
□ Every container has deploy.resources.limits (memory + cpus)
□ No named Docker volumes — bind mounts only
□ Scripts begin with set -euo pipefail
□ Passwords written to files, never as CLI arguments
□ No runtime package installation in entrypoints
□ External images pinned to exact semver (botanical/* exempt)
□ .env files not committed to git
□ docker.sock never mounted directly — use docker-socket-proxy
□ Deploy scripts exit 1 if chown/permission setup fails
□ No external CDN calls in UI themes
□ Use jq for JSON — never sed/awk on JSON
□ R temp → /Rtmp | BLAS → libopenblas0-serial
```

---

## Boot Sequence Constraints

1. `docker-socket-proxy` MUST boot BEFORE `telemetry-api`.
2. RStudio startup must map tmpfs dirs and bind mounts correctly to AD/SSSD pipes.
3. Init scripts (`01_optimize_system.sh`, `10_join_domain_*.sh`, `50_setup_nodes.sh`) run on the HOST out-of-band, not inside containers.

---

*Cross-reference `.ai/agents.md` for full project architecture and constraint rationale.*
