---
name: script-safety-review
description: Reviews shell scripts for safety and compliance with R-studioConf project standards. Use when creating, modifying, or reviewing any .sh file in the scripts/ directory. Checks error handling, secret safety, interactive input rules, and script coupling.
---

# Script Safety Review Skill

You are reviewing a shell script for the R-studioConf project.

## Mandatory Checks

### 1. Error Handling (HC-03)
- Second line MUST be `set -euo pipefail`
- Shebang MUST be `#!/bin/bash`

### 2. Secret Safety (HC-04)
- Passwords MUST be written to files via `printf "%s" "$VAR" > file`
- NEVER pass passwords as CLI arguments (`--password "$VAR"`)
- NEVER `echo "$PASSWORD"` (leaks in process table)
- Use `--password-file` flags where available

### 3. Interactive Input Rules
Check which category this script belongs to:

**Container-internal (NEVER use read -p):**
Any script executed as an entrypoint or internal daemon via Dockerfile `CMD`, `ENTRYPOINT`, or triggered by a container lifecycle hook.

If the script is in this category and contains `read -p`, `read -rp`, or `read -s`, it WILL hang when run inside a Docker container. This is a **critical failure**.

**Operator scripts (interactive allowed):**
All other scripts in `scripts/` that are run by the sysadmin.

### 4. Config Reading
- CORRECT: `grep "^VAR=" .env | cut -d= -f2- | tr -d '"'`
- WRONG: `source .env` (unsafe with special characters in passwords)

### 5. Path Resolution
- MUST use: `SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"`
- NEVER use `pwd` or hardcoded absolute paths

### 6. Script Coupling
Before modifying what a script READS or PRODUCES, check the dependency chain:

```
configure_rstudio.sh → .env → docker-deploy/docker-compose.yml → RStudio Container
```

Read `.ai/agents.md` Section 7.1 for the complete dependency graph.

### 7. Destructive Operations (HC-10)
- Reset/destroy scripts MUST require explicit confirmation (`type 'yes'`)
- Deploy scripts MUST `exit 1` if `chown` fails
- Use colored output: GREEN (success), RED (error), YELLOW (warning), BLUE (info)

### 8. JSON Manipulation (HC-12)
- Use `jq` for ALL JSON operations
- NEVER use `sed`, `awk`, or `grep` to modify JSON files
- URL-encode credentials: `jq -nr --arg v "$VAR" '$v|@uri'`

## Output Format

```
[PASS/FAIL/WARN] Check: description
  Line N: problematic code
  → Fix: specific fix
```
