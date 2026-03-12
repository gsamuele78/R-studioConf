# Claude Agent Instructions — R-studioConf

> **Purpose:** Optimized context file for Anthropic Claude (Claude 3.5 Sonnet / Opus) when working on this codebase.
> **Usage:** Include this file in Claude's system prompt or upload as Project Knowledge.

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

## Claude-Specific Behavioral Directives

### Strengths & Weaknesses

Claude excels at large-scale refactoring and understanding complex dependency chains, but has two distinct tendencies to watch out for:

1. **Over-explaining:** Claude naturally wants to be pedagogical. In this project, the operator is an expert LPIC-3 sysadmin. Output code first. Keep explanations to 1-2 bullet points explaining *why* a constraint was applied.
2. **Apologizing:** If Claude makes a mistake, it tends to output heavily apologetic text. Skip the apology; just provide the fixed code block.

### Output Formatting

When generating code for this project, Claude MUST follow these formats:

*   **Shell Scripts:** Never provide snippets like "replace this function." Always output the entire script file. This ensures `set -euo pipefail`, color variables, and imports remain intact.
*   **Docker Compose:** Output the complete service block. Include all mandatory fields (`deploy.resources.limits`, `healthcheck`, `logging`, `depends_on`). Never omit things with `# ... rest of config`.
*   **File Headers:** The first line of any code block MUST be a comment with the file path (e.g., `# docker-deploy/docker-compose.yml`).

---

## Critical Constraints Checklist

Claude MUST verify these constraints before responding:

```
□ Every container has deploy.resources.limits (memory + cpus)
□ No named Docker volumes — bind mounts only
□ Scripts begin with set -euo pipefail
□ Passwords written to files, never passed as CLI arguments
□ No runtime package installation (apk add, apt-get) in entrypoints
□ All upstream images pinned to exact versions
□ .env files not committed to git
□ docker.sock never mounted directly — use docker-socket-proxy
□ Deploy scripts exit 1 if chown/permission setup fails
□ No external CDN calls in UI themes
□ Use jq for JSON manipulation — never sed/awk on JSON
```

---

*End of Claude-specific instructions.*
