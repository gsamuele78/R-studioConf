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

# 1a. Extract image versions from production compose files
declare -A IMAGES
for f in "$PROJECT_ROOT"/docker-deploy/docker-compose.yml "$PROJECT_ROOT"/sandbox/*.yml; do
    [ ! -f "$f" ] && continue
    while IFS= read -r line; do
        img=$(echo "$line" | sed 's/.*image:\s*//' | tr -d '"' | tr -d "'" | xargs)
        [ -z "$img" ] && continue
        base=$(echo "$img" | cut -d: -f1)
        ver=$(echo "$img" | grep -o ':.*' | sed 's/://' || echo "untagged")
        IMAGES["$base"]="$ver"
    done < <(grep -E '^\s+image:' "$f" 2>/dev/null || true)
done

echo "  Extracted ${#IMAGES[@]} unique images:"
VERSIONS_FILE="$AI_DIR/extracted_versions.env"
: > "$VERSIONS_FILE"
for base in $(echo "${!IMAGES[@]}" | tr ' ' '\n' | sort); do
    echo "    $base:${IMAGES[$base]}"
    # Sanitize key for env file (replace / and - with _)
    key=$(echo "$base" | tr '/-' '__' | tr '[:lower:]' '[:upper:]')
    echo "${key}=${IMAGES[$base]}" >> "$VERSIONS_FILE"
done

# 1b. Extract script inventory
echo ""
echo "  Scanning scripts..."
SCRIPT_COUNT=$(find "$PROJECT_ROOT/scripts" -name '*.sh' | wc -l)
echo "    Found $SCRIPT_COUNT scripts"

# 1c. Extract .env variable names from sandbox files
echo "  Scanning .env.sandbox files..."
declare -A ENV_VARS
for f in "$PROJECT_ROOT"/docker-deploy/.env.sandbox; do
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
CONSTRAINT_COUNT=$(grep -c '  - id: "HC-' "$PROJ_YML" || echo 0)
BUG_COUNT=$(grep -c '  - id: "TD-' "$PROJ_YML" || echo 0)
echo "  $CONSTRAINT_COUNT hard constraints"
echo "  $BUG_COUNT known issues"

# ──────────────────────────────────────────────────────────────
# PHASE 3: Generate version block for agent files
# ──────────────────────────────────────────────────────────────
echo ""
echo -e "${BLUE}[Phase 3] Generating pinned versions block...${NC}"

VERSIONS_BLOCK="## Pinned Versions (extracted from docker-compose.yml on $(date +%Y-%m-%d))

| Image | Version | Source |
|-------|---------|--------|"

for base in $(echo "${!IMAGES[@]}" | tr ' ' '\n' | sort); do
    VERSIONS_BLOCK+="
| \`$base\` | \`${IMAGES[$base]}\` | docker-compose.yml |"
done

echo "  Generated versions table with ${#IMAGES[@]} entries"

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

COMPACT_RULES="PROJECT: R-studioConf (RStudio Server + Nginx Portal + OIDC/SSSD/Samba)
PARADIGM: Pessimistic System Engineering — assume failure, bound resources, fail fast.
GENERATED: $(date +%Y-%m-%d) from project.yml + code scan

HARD RULES (violating ANY makes output unusable):
${RULES_BLOCK}
COMPOSE FORMAT:
- Compose v2: NO \"version:\" key
- \"docker compose\" (space) NOT \"docker-compose\" (hyphen)
- Always: deploy, healthcheck, logging, labels, depends_on

PINNED VERSIONS (extracted from code — do not override):
$(for base in $(echo "${!IMAGES[@]}" | tr ' ' '\n' | sort); do echo "  $base: ${IMAGES[$base]}"; done)

WHEN GENERATING CODE:
- Output COMPLETE files, not fragments
- Include file path as comment on line 1
- For compose: ALL mandatory sections (deploy, healthcheck, logging)
- For scripts: shebang + set -euo pipefail + color vars
- Do NOT suggest alternative tools unless asked"

# ──────────────────────────────────────────────────────────────
# PHASE 5: Write output files
# ──────────────────────────────────────────────────────────────
echo ""
echo -e "${BLUE}[Phase 5] Writing output files...${NC}"

if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}  DRY RUN — showing what would be written:${NC}"
    echo "    CLAUDE.md (compact rules + full agents.md if present)"
    echo "    .cursorrules (compact rules block)"
    echo "    .github/copilot-instructions.md (compact rules block)"
    echo "    .clinerules (full agents.md if present)"
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
            if [ "$existing" = "$content" ]; then
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
CLAUDE_CONTENT="# CLAUDE.md — Auto-generated by .ai/generate.sh on $(date +%Y-%m-%d)
# Source: .ai/project.yml + codebase scan
# Do NOT edit manually — re-run .ai/generate.sh after changes.

$COMPACT_RULES"

# If agents.md exists (manually maintained rich version), append it
if [ -f "$AI_DIR/agents.md" ]; then
    CLAUDE_CONTENT+="

---

# FULL PROJECT DOCUMENTATION (from .ai/agents.md)

$(cat "$AI_DIR/agents.md")"
fi

# Append claude.md supplement if it exists
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

# 5d. .clinerules — Cline (full agents.md)
if [ -f "$AI_DIR/agents.md" ]; then
    CLINE_CONTENT="# .clinerules — Auto-generated by .ai/generate.sh on $(date +%Y-%m-%d)
# Source: .ai/agents.md

$(cat "$AI_DIR/agents.md")"
else
    CLINE_CONTENT="$COMPACT_RULES"
fi
write_file "$PROJECT_ROOT/.clinerules" "$CLINE_CONTENT" ".clinerules (Cline VS Code)"

# 5e. .windsurfrules — Windsurf (same as cursor)
write_file "$PROJECT_ROOT/.windsurfrules" "$CURSOR_CONTENT" ".windsurfrules (Windsurf)"

# 5f. .aider.conf.yml — Aider
AIDER_CONTENT="# Auto-generated by .ai/generate.sh on $(date +%Y-%m-%d)
read:"
[ -f "$AI_DIR/agents.md" ] && AIDER_CONTENT+="
  - .ai/agents.md"
[ -f "$AI_DIR/claude.md" ] && AIDER_CONTENT+="
  - .ai/claude.md"
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
