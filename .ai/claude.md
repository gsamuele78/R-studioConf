# Claude Agent Instructions — R-studioConf

> **For:** Anthropic Claude (any version) working on this codebase.
> **Load alongside:** `.ai/agents.md` — do not repeat what is in that file.

---

## Behavioral Directives

**Operator profile:** Single LPIC-3 sysadmin. Expert-level. Do NOT explain what `set -euo pipefail` does or what a bind mount is.

**Tendencies to suppress:**

1. **Over-explaining** — Output code first. Rationale: 1–2 bullet points max, only for non-obvious constraint choices.
2. **Apologizing** — Skip apology text. Provide the corrected artifact immediately.
3. **Optimistic assumptions** — Honest not optimistic prd system design best practices from system and architect engineer. Assume the failure case. If a path might not exist, check. If a service might be down, handle it. Never assume the happy path.
4. **Partial output** — NEVER produce "add this function to your script." Always output the complete file.
5. **Suggesting alternatives** — The tech stack is final. Do NOT suggest Traefik, Jupyter, pthread BLAS, or tmpfs for R temp. Kubernetes (T3) IS on the roadmap but `SKELETON_NOT_READY` — engage it only when the task explicitly targets `kubernetes-deploy/`, never volunteer it.

---

## Output Format Rules

- **Shell scripts:** Complete file. Line 1: `#!/usr/bin/env bash`. Line 2: `set -euo pipefail`. Color vars present. No snippets.
- **Docker Compose:** Complete service block. All mandatory fields: `deploy.resources.limits`, `healthcheck`, `logging`, `depends_on`. Never omit with `# ... rest of config`.
- **File header:** First line of every code block MUST be a comment with the file path (e.g., `# docker-deploy/docker-compose.yml`).
- **R config templates:** Reference `/Rtmp` for large temp storage, NOT `/tmp`.

---

## Skills — Check Before Implementing

This project has lazy-loaded skills in `.agents/skills/`. Check before implementing:

- `host-install-audit` → use when touching any T1 file (`scripts/`, `lib/`, `templates/`, `config/`, `init.sh`, `r_env_manager.sh`)
- `compose-constraint-audit` → use when touching any T2 `docker-compose.yml` or `docker-deploy/Dockerfile*`
- `k8s-manifest-audit` → use when touching any T3 `kubernetes-deploy/**/*.yaml`
- `script-safety-review` → use when creating or modifying any `.sh` file
- `sandbox-test` → **SKIP — sandbox is currently BROKEN**

---

## Pre-Response Constraints Checklist

Verify before every response touching infrastructure:

```
□ Every container has deploy.resources.limits (memory + cpus)
□ No named Docker volumes — bind mounts only
□ Scripts: #!/usr/bin/env bash + set -euo pipefail on line 2
□ Passwords written to files, never as CLI arguments
□ No runtime pkg install (apk add, apt-get) in entrypoints
□ External images pinned to exact semver (botanical/* exempt — locally built)
□ .env files not committed to git
□ docker.sock never mounted directly — use docker-socket-proxy
□ Deploy scripts exit 1 if chown/permission setup fails
□ No external CDN calls in UI themes
□ Use jq for JSON — never sed/awk on JSON
□ R temp storage → /Rtmp not /tmp
□ BLAS → libopenblas0-serial not pthread
□ Sandbox BROKEN → do not reference as validation path
□ src/biome_core_rust DORMANT → do not activate
□ Infra-Iam-PKI.backup → do not touch
```
