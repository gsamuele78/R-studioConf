#!/bin/bash
set -euo pipefail

# .ai/generate.sh
# ══════════════════════════════════════════════════════════════
# Generates ALL agent context files and tool configurations from:
#   1. .ai/project.yml  (manually maintained constraints)
#   2. Actual codebase   (image versions, script inventory, etc.)
#
# Usage:
#   .ai/generate.sh            # Generate all files
#   .ai/generate.sh --check    # Check if files are up-to-date (CI mode)
#   .ai/generate.sh --dry-run  # Show what would be generated
#
# Output files:
#   .ai/agents.md                       (universal context)
#   .ai/extracted_versions.env          (versions found in code)
#   CLAUDE.md                           (Claude Code CLI)
#   .cursorrules                        (Cursor IDE)
#   .github/copilot-instructions.md     (GitHub Copilot)
#   .clinerules                         (Cline VS Code)
#   .windsurfrules                      (Windsurf)
#   .aider.conf.yml                     (Aider)
# ══════════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AI_DIR="$SCRIPT_DIR"

CHECK_MODE=false
DRY_RUN=false
for arg in "$@"; do
    case "$arg" in
        --check) CHECK_MODE=true ;;
        --dry-run) DRY_RUN=true ;;
    esac
done

GREEN='\033[0;32m' BLUE='\033[0;34m' YELLOW='\033[1;33m'
RED='\033[0;31m' NC='\033[0m' BOLD='\033[1m'

echo -e "${BOLD}═══════════════════════════════════════${NC}"
echo -e "${BOLD}  Agent Context Generator${NC}"
echo -e "${BOLD}═══════════════════════════════════════${NC}"

# ──────────────────────────────────────────────────────────────
# PHASE 1: Extract data from actual codebase
# ──────────────────────────────────────────────────────────────
echo -e "${BLUE}[Phase 1] Extracting data from codebase...${NC}"

# Empty-safe associative-array helpers.
# bash 5.2 raises "unbound variable" for ${!a[@]} / ${#a[@]} on an empty (or
# declared-but-unassigned) associative array under `set -u`; the ${a[@]+...}
# guard (assigned into a fresh indexed array) sidesteps it cleanly.
sorted_keys() { local -n _r="$1"; local -a _k=( ${_r[@]+"${!_r[@]}"} ); ((${#_k[@]})) || return 0; printf '%s\n' "${_k[@]}" | sort; }
acount()      { local -n _r="$1"; local -a _k=( ${_r[@]+"${!_r[@]}"} ); echo "${#_k[@]}"; }

# 1a. Extract & classify compose images.
#   - base/tag are resolved from compose ${VAR:-default} and ${VAR} expansions
#     (a bare ${IMAGE_TAG} resolves to its conventional :latest default).
#   - an image is LOCALLY-BUILT iff its compose service declares a `build:` key
#     (authoritative; read via yq when present). Without yq/jq we fall back to
#     "resolved base has no registry path" — both yield the same result here.
resolve_image_ref() {
    local raw="$1"
    raw="$(sed -E 's/\$\{[A-Za-z_][A-Za-z0-9_]*:-([^}]*)\}/\1/g' <<<"$raw")"   # ${VAR:-default} -> default
    raw="$(sed -E 's/\$\{[A-Za-z_][A-Za-z0-9_]*\}/latest/g'      <<<"$raw")"   # ${VAR} (no default) -> latest
    if [[ "$raw" == *:* ]]; then
        printf '%s|%s' "${raw%:*}" "${raw##*:}"
    else
        printf '%s|latest' "$raw"
    fi
}

declare -A IMAGES UPSTREAM_IMAGES LOCAL_IMAGES
classify_ref() {   # $1 = raw image ref, $2 = is_local (true|false)
    local parsed base ver
    parsed="$(resolve_image_ref "$1")"; base="${parsed%%|*}"; ver="${parsed##*|}"
    [ -z "$base" ] && return 0
    IMAGES["$base"]="$ver"
    if [ "$2" = "true" ]; then LOCAL_IMAGES["$base"]="$ver"; else UPSTREAM_IMAGES["$base"]="$ver"; fi
}

COMPOSE_FILE="$PROJECT_ROOT/docker-deploy/docker-compose.yml"
if [ -f "$COMPOSE_FILE" ]; then
    if command -v yq >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
        while IFS=$'\t' read -r img has_build; do
            [ -z "$img" ] && continue
            [ "$img" = "null" ] && continue
            classify_ref "$img" "$has_build"
        done < <(yq -r '.services | to_entries[] | select(.value.image) | "\(.value.image)\t\(.value.build != null)"' "$COMPOSE_FILE")
    else
        while IFS= read -r line; do
            img="$(sed 's/.*image:[[:space:]]*//' <<<"$line" | tr -d "\"'" | xargs)"
            [ -z "$img" ] && continue
            base="$(resolve_image_ref "$img")"; base="${base%%|*}"
            if [[ "$base" == *"/"* ]]; then classify_ref "$img" "false"; else classify_ref "$img" "true"; fi
        done < <(grep -E '^\s+image:' "$COMPOSE_FILE" 2>/dev/null || true)
    fi
fi

# 1a-bis. Extract upstream base images from Dockerfile FROM lines
declare -A DOCKERFILE_FROM
for df in "$PROJECT_ROOT"/docker-deploy/Dockerfile "$PROJECT_ROOT"/docker-deploy/Dockerfile.*; do
    [ ! -f "$df" ] && continue
    while IFS= read -r line; do
        [[ "$line" =~ ^FROM[[:space:]]+([^[:space:]]+)([[:space:]]+as[[:space:]]+.*)?$ ]] || continue
        from_img="${BASH_REMATCH[1]}"
        # Skip local build stages (no registry prefix, no tag)
        [[ "$from_img" != *"/"* ]] && continue
        base="${from_img%:*}"
        ver="${from_img##*:}"
        DOCKERFILE_FROM["$base"]="$ver"
    done < "$df"
done

echo "  Extracted $(acount UPSTREAM_IMAGES) upstream images (compose), $(acount LOCAL_IMAGES) locally-built, $(acount DOCKERFILE_FROM) Dockerfile FROMs"
VERSIONS_FILE="$AI_DIR/extracted_versions.env"
: > "$VERSIONS_FILE"
# Write upstream images
for base in $(sorted_keys UPSTREAM_IMAGES); do
    echo "    UPSTREAM  $base:${UPSTREAM_IMAGES[$base]}"
    key=$(echo "$base" | sed 's/[^A-Za-z0-9]/_/g' | tr '[:lower:]' '[:upper:]')
    echo "${key}=${UPSTREAM_IMAGES[$base]}" >> "$VERSIONS_FILE"
done
# Write Dockerfile FROM images
for base in $(sorted_keys DOCKERFILE_FROM); do
    echo "    FROM      $base:${DOCKERFILE_FROM[$base]}"
    key=$(echo "$base" | sed 's/[^A-Za-z0-9]/_/g' | tr '[:lower:]' '[:upper:]')
    echo "DOCKERFILE_${key}=${DOCKERFILE_FROM[$base]}" >> "$VERSIONS_FILE"
done
# Write locally-built images
for base in $(sorted_keys LOCAL_IMAGES); do
    echo "    LOCAL     $base:${LOCAL_IMAGES[$base]} (tag via \${IMAGE_TAG})"
    key=$(echo "$base" | sed 's/[^A-Za-z0-9]/_/g' | tr '[:lower:]' '[:upper:]')
    echo "${key}=${LOCAL_IMAGES[$base]}" >> "$VERSIONS_FILE"
done

# 1b. Extract script inventory
echo ""
echo "  Scanning scripts..."
SCRIPT_COUNT=$(find "$PROJECT_ROOT/scripts" -name '*.sh' | wc -l)
echo "    Found $SCRIPT_COUNT scripts"

# 1c. Extract .env variable names from sandbox files
echo "  Scanning .env.sandbox.example files..."
declare -A ENV_VARS
for f in "$PROJECT_ROOT"/docker-deploy/.env.sandbox.example; do
    [ ! -f "$f" ] && continue
    stack=$(basename "$(dirname "$f")")
    while IFS= read -r line; do
        [[ "$line" =~ ^# ]] && continue
        [[ -z "$line" ]] && continue
        varname=$(echo "$line" | cut -d= -f1)
        ENV_VARS["$stack:$varname"]=1
    done < "$f"
done
echo "    Found ${#ENV_VARS[@]} env variables across stacks"

# 1d. Count compose services
echo "  Counting compose services..."
TOTAL_SERVICES=0
for f in "$PROJECT_ROOT"/docker-deploy/docker-compose.yml "$PROJECT_ROOT"/sandbox/*.yml; do
    [ ! -f "$f" ] && continue
    count=$(grep -cE '^\s{2}\S+:' "$f" | head -1 || echo 0)
    TOTAL_SERVICES=$((TOTAL_SERVICES + count))
done
echo "    Found ~$TOTAL_SERVICES services across production compose files"

# ──────────────────────────────────────────────────────────────
# PHASE 2: Read constraints from project.yml
# ──────────────────────────────────────────────────────────────
echo ""
echo -e "${BLUE}[Phase 2] Reading constraints from project.yml...${NC}"

PROJ_YML="$AI_DIR/project.yml"
if [ ! -f "$PROJ_YML" ]; then
    echo -e "${RED}Error: project.yml not found at $PROJ_YML${NC}"
    exit 1
fi

# Extract constraints using grep (avoiding yq dependency for portability)
CONSTRAINT_COUNT=$(grep -c '  - id: "HC-' "$PROJ_YML" || true)
BUG_COUNT=$(grep -c '  - id: "TD-' "$PROJ_YML" || true)
echo "  $CONSTRAINT_COUNT hard constraints"
echo "  $BUG_COUNT known issues"

# Extract R runtime facts (non-extractable from code — maintained manually in project.yml)
R_BLAS_OK=$(grep 'package: "libopenblas' "$PROJ_YML" | sed 's/.*"\(.*\)".*/\1/')
R_BLAS_BANNED=$(grep 'banned: "libopenblas' "$PROJ_YML" | sed 's/.*"\([^"]*\)".*/\1/')
R_TMP_PATH=$(grep 'path: "/Rtmp"' "$PROJ_YML" | sed 's/.*"\(.*\)".*/\1/')
R_TMP_SIZE=$(grep 'size_gb:' "$PROJ_YML" | grep -o '[0-9]*' | head -1)
R_CONFIG_DIR=$(grep 'modular_dir:' "$PROJ_YML" | sed 's/.*"\(.*\)".*/\1/')
echo "  R runtime: BLAS=${R_BLAS_OK:-libopenblas0-serial}, Tmp=${R_TMP_PATH:-/Rtmp} (${R_TMP_SIZE:-400}GB), Config=${R_CONFIG_DIR:-/etc/biome-calc/profile.d/}"

# ──────────────────────────────────────────────────────────────
# PHASE 3: Generate version block for agent files
# ──────────────────────────────────────────────────────────────
echo ""
echo -e "${BLUE}[Phase 3] Generating pinned versions block...${NC}"

VERSIONS_BLOCK="## Pinned Versions (extracted from docker-compose.yml on $(date +%Y-%m-%d))

| Image | Version | Source |
|-------|---------|--------|"

for base in $(sorted_keys IMAGES); do
    VERSIONS_BLOCK+="
| \`$base\` | \`${IMAGES[$base]}\` | docker-compose.yml |"
done

echo "  Generated versions table with $(acount IMAGES) entries"

# ──────────────────────────────────────────────────────────────
# PHASE 4: Generate constraint block
# ──────────────────────────────────────────────────────────────
echo -e "${BLUE}[Phase 4] Generating constraint rules block...${NC}"

# Extract constraints as numbered list
RULES_BLOCK=""
rule_num=0
while IFS= read -r line; do
    if [[ "$line" =~ rule:\ \"(.*)\" ]]; then
        rule_num=$((rule_num + 1))
        RULES_BLOCK+="${rule_num}. ${BASH_REMATCH[1]}
"
    fi
done < "$PROJ_YML"

# Extract ethos one-liner and tier headline (best-effort grep; project.yml is yaml)
ETHOS_LINE=$(grep -m1 'one_liner:' "$PROJ_YML" | sed 's/.*one_liner:\s*"\(.*\)"/\1/' || true)
[ -z "$ETHOS_LINE" ] && ETHOS_LINE="ETHOS: Honest > optimistic. Pessimistic defaults. T1 (host) authoritative & continuously fixed; T2/T3 mirror T1."

TIERS_LINE="TIERS: T1=host AUTHORITATIVE_CONTINUOUSLY_FIXED | T2=docker MIGRATION_IN_PROGRESS (mirror T1) | T3=k8s SKELETON_NOT_READY (defer until T2 stable). Rule: fix in T1 first, port forward T1→T2→T3."

COMPACT_RULES="PROJECT: R-studioConf (RStudio Server + Nginx Portal + OIDC/SSSD/Samba)
PARADIGM: Pessimistic System Engineering — assume failure, bound resources, fail fast.
GENERATED: $(date +%Y-%m-%d) from project.yml + code scan

${ETHOS_LINE}

${TIERS_LINE}

HARD RULES (violating ANY makes output unusable):
${RULES_BLOCK}
COMPOSE FORMAT:
- Compose v2: NO \"version:\" key
- \"docker compose\" (space) NOT \"docker-compose\" (hyphen)
- Always: deploy, healthcheck, logging, labels, depends_on

PINNED UPSTREAM VERSIONS (extracted from Dockerfiles — do not override):
$(for base in $(sorted_keys DOCKERFILE_FROM); do echo "  $base: ${DOCKERFILE_FROM[$base]}"; done)
$(for base in $(sorted_keys UPSTREAM_IMAGES); do echo "  $base: ${UPSTREAM_IMAGES[$base]}"; done)

LOCALLY-BUILT IMAGES (tag via \${IMAGE_TAG} variable; production deploys MUST set a pinned tag):
$(for base in $(sorted_keys LOCAL_IMAGES); do echo "  $base: \${IMAGE_TAG:-latest} (locally built, not pulled from registry)"; done)

WHEN GENERATING CODE:
- Output COMPLETE files, not fragments
- Include file path as comment on line 1
- For compose: ALL mandatory sections (deploy, healthcheck, logging)
- For scripts: shebang + set -euo pipefail + color vars
- Do NOT suggest alternative tools unless asked

R RUNTIME RULES:
- BLAS: ${R_BLAS_OK:-libopenblas0-serial} (NOT ${R_BLAS_BANNED:-libopenblas0-pthread} — causes SIGSEGV)
- Large R temp: ${R_TMP_PATH:-/Rtmp} (${R_TMP_SIZE:-400}GB ext4) — NOT /tmp
- Modular R config: ${R_CONFIG_DIR:-/etc/biome-calc/profile.d/}
- Sandbox: KNOWN BROKEN — use user/researcher testing only

REFERENCE FILES (read on demand, do not embed):
- .ai/agents.md            full architecture, T1 script chain, R runtime
- .ai/project.yml          deployment_tiers, engineering_ethos, tier_deltas
- .agents/skills/          lazy-load skills:
    host-install-audit     (T1 host scripts/lib/templates/configs)
    compose-constraint-audit (T2 docker-compose.yml + Dockerfiles)
    k8s-manifest-audit     (T3 kubernetes-deploy/*.yaml)
    script-safety-review   (any *.sh)
    sandbox-test           SKIP — sandbox BROKEN"

# ──────────────────────────────────────────────────────────────
# PHASE 5: Write output files
# ──────────────────────────────────────────────────────────────
echo ""
echo -e "${BLUE}[Phase 5] Writing output files...${NC}"

if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}  DRY RUN — showing what would be written:${NC}"
    echo "    CLAUDE.md (compact rules + claude.md behavioral directives + pointer to agents.md)"
    echo "    .cursorrules (compact rules block)"
    echo "    .github/copilot-instructions.md (compact rules block)"
    echo "    .clinerules (compact rules block + pointer to agents.md)"
    echo "    .windsurfrules (compact rules block)"
    echo "    .aider.conf.yml (file references)"
    echo "    .ai/extracted_versions.env (already written)"
    exit 0
fi

write_file() {
    local target="$1"
    local content="$2"
    local label="$3"

    if [ "$CHECK_MODE" = true ]; then
        if [ -f "$target" ]; then
            existing=$(cat "$target")
            # Normalize the volatile generation date (ISO yyyy-mm-dd) so --check is
            # deterministic day-to-day — only real content drift fails the gate.
            local norm_existing norm_content
            norm_existing=$(sed -E 's/[0-9]{4}-[0-9]{2}-[0-9]{2}/<DATE>/g' <<<"$existing")
            norm_content=$(sed -E 's/[0-9]{4}-[0-9]{2}-[0-9]{2}/<DATE>/g' <<<"$content")
            if [ "$norm_existing" = "$norm_content" ]; then
                echo -e "  ${GREEN}✓${NC} $label is up-to-date"
            else
                echo -e "  ${RED}✗${NC} $label is OUTDATED — run .ai/generate.sh to update"
                ERRORS=$((ERRORS + 1))
            fi
        else
            echo -e "  ${RED}✗${NC} $label is MISSING — run .ai/generate.sh to create"
            ERRORS=$((ERRORS + 1))
        fi
    else
        echo "$content" > "$target"
        echo -e "  ${GREEN}✓${NC} $label ($(wc -l < "$target") lines)"
    fi
}

ERRORS=0

# 5a. CLAUDE.md — Claude Code CLI
# Token-optimized: compact rules block + behavioral directives only.
# Full narrative is in .ai/agents.md (read on-demand, not embedded).
CLAUDE_CONTENT="# CLAUDE.md — Auto-generated by .ai/generate.sh on $(date +%Y-%m-%d)
# Source: .ai/project.yml + codebase scan
# Do NOT edit manually — re-run .ai/generate.sh after changes.
# Full project context: .ai/agents.md

$COMPACT_RULES"

# Append claude.md behavioral directives (Claude-specific, not a repeat of agents.md)
if [ -f "$AI_DIR/claude.md" ]; then
    CLAUDE_CONTENT+="

---

$(cat "$AI_DIR/claude.md")"
fi

write_file "$PROJECT_ROOT/CLAUDE.md" "$CLAUDE_CONTENT" "CLAUDE.md (Claude Code CLI)"

# 5b. .cursorrules — Cursor IDE (compact, ~80 lines)
CURSOR_CONTENT="# .cursorrules — Auto-generated by .ai/generate.sh on $(date +%Y-%m-%d)
# Do NOT edit manually — re-run .ai/generate.sh after changes.

$COMPACT_RULES"
write_file "$PROJECT_ROOT/.cursorrules" "$CURSOR_CONTENT" ".cursorrules (Cursor IDE)"

# 5c. .github/copilot-instructions.md — GitHub Copilot
mkdir -p "$PROJECT_ROOT/.github"
COPILOT_CONTENT="# Auto-generated by .ai/generate.sh on $(date +%Y-%m-%d)
# Do NOT edit manually.

$COMPACT_RULES"
write_file "$PROJECT_ROOT/.github/copilot-instructions.md" "$COPILOT_CONTENT" ".github/copilot-instructions.md (Copilot)"

# 5d. .clinerules — Cline (compact rules + pointer)
# Token-optimized: full agents.md NOT embedded here.
# Cline loads .ai/agents.md via .aider.conf.yml or explicit file open.
CLINE_CONTENT="# .clinerules — Auto-generated by .ai/generate.sh on $(date +%Y-%m-%d)
# Full project context: .ai/agents.md (read that file for architecture, scripts, R runtime)

$COMPACT_RULES"
write_file "$PROJECT_ROOT/.clinerules" "$CLINE_CONTENT" ".clinerules (Cline VS Code)"

# 5e. .windsurfrules — Windsurf
WINDSURF_CONTENT="# .windsurfrules — Auto-generated by .ai/generate.sh on $(date +%Y-%m-%d)
# Do NOT edit manually — re-run .ai/generate.sh after changes.

$COMPACT_RULES"
write_file "$PROJECT_ROOT/.windsurfrules" "$WINDSURF_CONTENT" ".windsurfrules (Windsurf)"

# 5f. .aider.conf.yml — Aider
AIDER_CONTENT="# Auto-generated by .ai/generate.sh on $(date +%Y-%m-%d)
read:"
[ -f "$AI_DIR/agents.md" ] && AIDER_CONTENT+="
  - .ai/agents.md"
[ -f "$AI_DIR/claude.md" ] && AIDER_CONTENT+="
  - .ai/claude.md"
[ -f "$AI_DIR/gemini.md" ] && AIDER_CONTENT+="
  - .ai/gemini.md"
[ -f "$AI_DIR/chatgpt.md" ] && AIDER_CONTENT+="
  - .ai/chatgpt.md"
write_file "$PROJECT_ROOT/.aider.conf.yml" "$AIDER_CONTENT" ".aider.conf.yml (Aider)"

# ──────────────────────────────────────────────────────────────
# SUMMARY
# ──────────────────────────────────────────────────────────────
echo ""
if [ "$CHECK_MODE" = true ]; then
    if [ "$ERRORS" -gt 0 ]; then
        echo -e "${RED}✗ $ERRORS files are outdated or missing.${NC}"
        echo "  Run: .ai/generate.sh"
        exit 1
    else
        echo -e "${GREEN}✓ All generated files are up-to-date.${NC}"
        exit 0
    fi
else
    echo -e "${BOLD}═══════════════════════════════════════${NC}"
    echo -e "${GREEN}All files generated successfully.${NC}"
    echo ""
    echo "  Auto-loading tools configured:"
    echo "    CLAUDE.md                         → Claude Code"
    echo "    .cursorrules                      → Cursor IDE"
    echo "    .github/copilot-instructions.md   → GitHub Copilot"
    echo "    .clinerules                       → Cline"
    echo "    .windsurfrules                    → Windsurf"
    echo "    .aider.conf.yml                   → Aider"
    echo ""
    echo -e "  ${YELLOW}Manual tools (upload .ai/*.md files):${NC}"
    echo "    Claude.ai Project  → .ai/agents.md + .ai/claude.md"
    echo "    ChatGPT Custom GPT → .ai/agents.md + .ai/chatgpt.md"
    echo "    Gemini Gem         → .ai/gemini.md"
    echo ""
    echo "  Commit: git add CLAUDE.md .cursorrules .clinerules"
    echo "          git add .windsurfrules .github/ .aider.conf.yml"
    echo -e "${BOLD}═══════════════════════════════════════${NC}"
fi
