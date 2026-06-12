---
name: script-safety-review
description: Reviews shell scripts for safety and compliance with R-studioConf project standards. Use when creating, modifying, or reviewing any .sh file in the repository (scripts/, lib/, docker-deploy/scripts/, .ai/, sandbox/). Checks error handling, secret safety, interactive input rules, and script coupling.
---

# Script Safety Review Skill

Reviewing a shell script for R-studioConf. Paradigm: **Pessimistic System Engineering** — assume failure, fail fast.

## Triage (check first — stop if irrelevant)

1. Is the file a `.sh` script? If not, skip this skill.
2. Is the file under `archive/`, `Infra-Iam-PKI/`, or `src/biome_core_rust/`? If yes, skip (out of scope per ignore_globs).
3. Container-internal scripts (entrypoints, CMD wrappers): interactive input (`read -p`) is CRITICAL FAILURE.

## Severity Rubric

| Severity | Criteria |
|----------|----------|
| CRITICAL | Missing `set -euo pipefail`, password on CLI, `read -p` in container script, silent chown failure |
| HIGH | Unsafe `source .env`, bare `pwd`, hardcoded absolute paths, `sed`/`awk` on JSON |
| MEDIUM | Missing color vars, missing `SCRIPT_DIR` resolution, non-idempotent |
| LOW | Style/formatting deviations, non-blocking warnings |

## Mandatory Checks

### 1. Error Handling (HC-03)

- Line 1 MUST be `#!/usr/bin/env bash`
- Line 2 MUST be `set -euo pipefail`

### 2. Secret Safety (HC-04)

- Passwords MUST be written to temp files: `printf "%s" "$VAR" > file`
- NEVER pass passwords as CLI arguments (`--password "$VAR"`)
- NEVER `echo "$PASSWORD"` — leaks in process table
- Use `--password-file` flags where available

### 3. Interactive Input Rules

**Container-internal scripts (NEVER use `read -p`):**
Any script run as a container entrypoint/CMD/ENTRYPOINT or triggered by a container lifecycle hook. If `read -p`, `read -rp`, or `read -s` appears — **CRITICAL FAILURE**: will hang without TTY.

**Operator scripts (interactive allowed):**
All scripts in `scripts/` run by the sysadmin on the host. Examples: `10_join_domain_sssd.sh`, `50_setup_nodes.sh`, `test_rstudio_login.sh`.

### 4. Config Reading

- CORRECT: `grep "^VAR=" .env | cut -d= -f2- | tr -d '"'`
- WRONG: `source .env` — unsafe with special characters in passwords

### 5. Path Resolution

- MUST use: `SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"`
- NEVER use bare `pwd` or hardcoded absolute paths

### 6. Script Coupling — Dependency Chain

Before modifying what a script READS or PRODUCES, trace the full chain:

```
50_setup_nodes.sh
  ├── lib/common_utils.sh
  ├── config/setup_nodes.vars.conf
  ├── templates/Rprofile_site.R.template → /etc/R/Rprofile.site
  └── r_env_manager.sh configure_java_for_r()
        └── /etc/biome-calc/profile.d/   (modular R config loader)
              └── RStudio container session startup

configure_rstudio.sh → .env → docker-deploy/docker-compose.yml → RStudio Container
update_nginx_templates.sh → config/nginx/ → nginx-portal container
```

Cross-check `.ai/agents.md §5` before changing script inputs/outputs.

### 7. Destructive Operations (HC-10)

- Reset/destroy scripts MUST require explicit confirmation (`type 'yes'`)
- Deploy scripts MUST `exit 1` if `chown` fails
- Color output: GREEN (success), RED (error), YELLOW (warning), BLUE (info)

### 8. JSON Manipulation (HC-12)

- Use `jq` for ALL JSON operations
- NEVER use `sed`, `awk`, or `grep` to modify JSON files
- URL-encode credentials: `jq -nr --arg v "$VAR" '$v|@uri'`

### 9. Storage References

- For large R temp files: use `/Rtmp` (400GB ext4 disk), NOT `/tmp`
- Do NOT reference `/tmp` for NIMBLE compilation or matrix scratch space

### 10. BLAS References

- Package to install: `libopenblas0-serial`
- Package to remove: `libopenblas0-pthread` (causes SIGSEGV)
- Detection script: `/etc/profile.d/biome-coretype.sh`

### 11. Pinned Versions (HC-07)

- ALL upstream image versions MUST be pinned — no `:latest` tag for registry images
- Locally-built images (`botanical-*`, `rstudio-botanical-*`) are tagged via `${IMAGE_TAG}` variable (defaults to `:latest` in sandbox/CI; production deploys MUST set a pinned tag) — per codified HC-07 exception

## Output Format

```
[PASS/FAIL/WARN] Check: description
  Line N: problematic code
  → Fix: specific fix
