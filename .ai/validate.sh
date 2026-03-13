#!/bin/bash
set -euo pipefail

# .ai/validate.sh
# ══════════════════════════════════════════════════════════════
# Validates the ACTUAL CODEBASE against the project's hard
# constraints. This is the enforcement layer — run locally
# before committing or in CI on every push.
#
# Usage:
#   .ai/validate.sh              # Full validation
#   .ai/validate.sh --ci         # CI mode (no colors, exit code only)
#   .ai/validate.sh --fix-hint   # Show fix suggestions for failures
#
# Exit codes:
#   0 = All checks passed
#   1 = Hard constraint violations found (MUST fix before merge)
#   2 = Warnings found (should review but not blocking)
# ══════════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Parse flags
CI_MODE=false
SHOW_HINTS=false
for arg in "$@"; do
    case "$arg" in
        --ci) CI_MODE=true ;;
        --fix-hint) SHOW_HINTS=true ;;
    esac
done

# Colors (disabled in CI)
if [ "$CI_MODE" = true ]; then
    RED="" GREEN="" YELLOW="" BLUE="" NC="" BOLD=""
else
    RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m'
    BLUE='\033[0;34m' NC='\033[0m' BOLD='\033[1m'
fi

ERRORS=0
WARNINGS=0
CHECKS=0

pass() { echo -e "  ${GREEN}✓${NC} $1"; }
fail() { echo -e "  ${RED}✗ FAIL:${NC} $1"; ERRORS=$((ERRORS + 1)); }
warn() { echo -e "  ${YELLOW}⚠ WARN:${NC} $1"; WARNINGS=$((WARNINGS + 1)); }
hint() { [ "$SHOW_HINTS" = true ] && echo -e "    ${BLUE}→ Fix:${NC} $1"; }
section() { echo ""; echo -e "${BOLD}[$1]${NC}"; }

COMPOSE_FILES="$PROJECT_ROOT/docker-deploy/docker-compose.yml"
SANDBOX_COMPOSE=$(ls "$PROJECT_ROOT"/sandbox/*.yml 2>/dev/null || true)
ALL_COMPOSE="$COMPOSE_FILES $SANDBOX_COMPOSE"
SCRIPTS=$(find "$PROJECT_ROOT/scripts" -name '*.sh' -not -path '*/.git/*' 2>/dev/null || true)
DOCKERFILES=$(find "$PROJECT_ROOT" -name 'Dockerfile*' -not -path '*/.git/*' -not -path '*/kubernetes-deploy/*' 2>/dev/null || true)

echo -e "${BOLD}═══════════════════════════════════════${NC}"
echo -e "${BOLD}  R-studioConf Constraint Validator${NC}"
echo -e "${BOLD}═══════════════════════════════════════${NC}"
echo "  Project root: $PROJECT_ROOT"
echo "  Mode: $([ "$CI_MODE" = true ] && echo 'CI' || echo 'Interactive')"

# ──────────────────────────────────────────────────────────────
# HC-01: Every container MUST have deploy.resources.limits
# ──────────────────────────────────────────────────────────────
section "HC-01: Resource limits on all containers"
for f in $COMPOSE_FILES; do
    CHECKS=$((CHECKS + 1))
    rel_path="${f#$PROJECT_ROOT/}"
    # Extract service names
    services=$(grep -E '^\s{2}\S+:' "$f" | grep -v '^\s*#' | sed 's/://;s/^ *//' | grep -v '^networks$\|^volumes$\|^x-' || true)
    for svc in $services; do
        # Check if this service has deploy.resources.limits
        # Use a simple approach: look for 'limits:' inside the service block
        # This is a heuristic — proper YAML parsing would need yq
        if ! awk '/^  '"${svc}"':/{flag=1; print; next} /^  [a-zA-Z]/{if(flag) exit} flag' "$f" | grep -q 'limits:'; then
            # Exempt one-shot containers that have restart: "no" or no restart policy
            # But still flag them as warnings
            if awk '/^  '"${svc}"':/{flag=1; print; next} /^  [a-zA-Z]/{if(flag) exit} flag' "$f" | grep -qE 'restart:\s*"?no"?'; then
                warn "$rel_path → service '$svc' has no resource limits (one-shot, non-critical)"
            else
                fail "$rel_path → service '$svc' missing deploy.resources.limits"
                hint "Add deploy.resources.limits.memory and deploy.resources.limits.cpus"
            fi
        fi
    done
done
[ "$ERRORS" -eq 0 ] && pass "All production compose services have resource limits"

# ──────────────────────────────────────────────────────────────
# HC-02: No named Docker volumes
# ──────────────────────────────────────────────────────────────
section "HC-02: No named Docker volumes (bind mounts only)"
HC02_ERRORS_BEFORE=$ERRORS
for f in $COMPOSE_FILES; do
    CHECKS=$((CHECKS + 1))
    rel_path="${f#$PROJECT_ROOT/}"
    # Check for top-level 'volumes:' section (named volume definitions)
    if grep -qE '^volumes:' "$f"; then
        fail "$rel_path → has top-level 'volumes:' section (named volumes)"
        hint "Replace named volumes with bind mounts (e.g., ./data:/path)"
    fi
done
[ "$ERRORS" -eq "$HC02_ERRORS_BEFORE" ] && pass "No named volumes in production compose files"

# Note: sandbox compose files ARE allowed named volumes (documented exception)
for f in $SANDBOX_COMPOSE; do
    rel_path="${f#$PROJECT_ROOT/}"
    if grep -qE '^volumes:' "$f"; then
        warn "$rel_path → has named volumes (acceptable in sandbox only)"
    fi
done

# ──────────────────────────────────────────────────────────────
# HC-03: Scripts MUST begin with set -euo pipefail
# ──────────────────────────────────────────────────────────────
section "HC-03: Scripts have strict error handling"
HC03_ERRORS_BEFORE=$ERRORS
for f in $SCRIPTS; do
    CHECKS=$((CHECKS + 1))
    rel_path="${f#$PROJECT_ROOT/}"
    # Check first 25 lines for set -euo pipefail or set -e (minimum)
    head_content=$(head -25 "$f")
    if ! echo "$head_content" | grep -q 'set -e'; then
        fail "$rel_path → missing 'set -euo pipefail' (or at minimum 'set -e')"
        hint "Add 'set -euo pipefail' as the second line after shebang"
    elif ! echo "$head_content" | grep -q 'set -euo pipefail'; then
        warn "$rel_path → has 'set -e' but not full 'set -euo pipefail'"
    fi
done
[ "$ERRORS" -eq "$HC03_ERRORS_BEFORE" ] && pass "All scripts have strict error handling"

# ──────────────────────────────────────────────────────────────
# HC-05: PostgreSQL ports NEVER exposed
# ──────────────────────────────────────────────────────────────
section "HC-05: No PostgreSQL ports exposed to host"
HC05_ERRORS_BEFORE=$ERRORS
for f in $COMPOSE_FILES; do
    CHECKS=$((CHECKS + 1))
    rel_path="${f#$PROJECT_ROOT/}"
    # Look for postgres services that have 'ports:' section
    if awk '/postgres/{flag=1; print; next} /^  [a-zA-Z]/{if(flag) exit} flag' "$f" | grep -qE '^\s+ports:'; then
        fail "$rel_path → PostgreSQL service has exposed ports"
        hint "Remove the ports: section from the PostgreSQL service"
    fi
done
[ "$ERRORS" -eq "$HC05_ERRORS_BEFORE" ] && pass "No PostgreSQL ports exposed"

# ──────────────────────────────────────────────────────────────
# HC-06: No runtime package installs in entrypoints
# ──────────────────────────────────────────────────────────────
section "HC-06: No runtime package installs in compose entrypoints"
HC06_ERRORS_BEFORE=$ERRORS
for f in $COMPOSE_FILES $SANDBOX_COMPOSE; do
    CHECKS=$((CHECKS + 1))
    rel_path="${f#$PROJECT_ROOT/}"
    # Check entrypoint/command blocks for apk add or apt-get install
    if grep -nE '(apk add|apt-get install|apt install)' "$f" | grep -vE '^\s*#' > /dev/null 2>&1; then
        fail "$rel_path → contains runtime package installation in compose"
        hint "Move package installs to Dockerfile (RUN apk add --no-cache ...)"
    fi
done
[ "$ERRORS" -eq "$HC06_ERRORS_BEFORE" ] && pass "No runtime package installs in compose files"

# ──────────────────────────────────────────────────────────────
# HC-07: No :latest tags on upstream images
# ──────────────────────────────────────────────────────────────
section "HC-07: All images pinned to specific versions"
HC07_ERRORS_BEFORE=$ERRORS
for f in $COMPOSE_FILES; do
    CHECKS=$((CHECKS + 1))
    rel_path="${f#$PROJECT_ROOT/}"
    # Find image: lines with :latest or without any tag (implicit latest)
    while IFS= read -r line; do
        # Skip comments and build contexts
        [[ "$line" =~ ^\s*# ]] && continue
        image_val=$(echo "$line" | sed 's/.*image:\s*//' | tr -d '"' | tr -d "'" | xargs)
        # Skip local builds (no / in name, has : with local tag)
        [[ "$image_val" == *":latest"* ]] && {
            fail "$rel_path → image '$image_val' uses :latest tag"
            hint "Pin to specific version (e.g., postgres:15-alpine)"
        }
        # Check for images without ANY tag (implicit :latest)
        # Only for known upstream images (contain / or are well-known names)
        if [[ "$image_val" == *"/"* ]] && [[ "$image_val" != *":"* ]]; then
            fail "$rel_path → image '$image_val' has no version tag (implicit :latest)"
            hint "Add explicit version tag"
        fi
    done < <(grep -E '^\s+image:' "$f" 2>/dev/null || true)
done
[ "$ERRORS" -eq "$HC07_ERRORS_BEFORE" ] && pass "All upstream images have pinned versions"

# ──────────────────────────────────────────────────────────────
# HC-08: .env not tracked in git
# ──────────────────────────────────────────────────────────────
section "HC-08: .env files excluded from git"
CHECKS=$((CHECKS + 1))
if [ -f "$PROJECT_ROOT/.gitignore" ]; then
    if grep -qE '^\*?\.env$|^\.env$' "$PROJECT_ROOT/.gitignore"; then
        pass ".gitignore excludes .env files"
    else
        fail ".gitignore does not exclude .env files"
        hint "Add '.env' and '*.env' to .gitignore (keep !.env.example and !*.env.sandbox)"
    fi
else
    fail "No .gitignore found at project root"
fi

# Check if any .env (non-sandbox, non-example) is tracked
CHECKS=$((CHECKS + 1))
if command -v git &>/dev/null && [ -d "$PROJECT_ROOT/.git" ]; then
    tracked_envs=$(git -C "$PROJECT_ROOT" ls-files '*.env' 2>/dev/null | grep -v '.env.sandbox' | grep -v '.env.example' | grep -v '.env.template' | grep -v '^.ai/extracted_versions.env$' || true)
    if [ -n "$tracked_envs" ]; then
        fail "Production .env files tracked in git: $tracked_envs"
        hint "git rm --cached <file> && add to .gitignore"
    else
        pass "No production .env files tracked in git"
    fi
fi

# ──────────────────────────────────────────────────────────────
# HC-09: No direct docker.sock mounts (except socket-proxy)
# ──────────────────────────────────────────────────────────────
section "HC-09: No direct docker.sock mounts (use socket-proxy)"
HC09_ERRORS_BEFORE=$ERRORS
for f in $COMPOSE_FILES; do
    CHECKS=$((CHECKS + 1))
    rel_path="${f#$PROJECT_ROOT/}"
    # Find services mounting docker.sock that are NOT the socket-proxy or watchtower
    while IFS= read -r line; do
        # Get the service name that owns this volume mount
        svc_name=$(awk -v line_num="$line" 'NR<=line_num && /^  [a-z]/' "$f" | tail -1 | sed 's/://' | xargs)
        case "$svc_name" in
            *socket-proxy*|*watchtower*) ;; # Acceptable
            *)
                fail "$rel_path → service '$svc_name' mounts docker.sock directly"
                hint "Use docker-socket-proxy (tecnativa) instead of direct mount"
                ;;
        esac
    done < <(grep -Fn 'docker.sock' "$f" 2>/dev/null | grep -v '^\s*#' | cut -d: -f1 || true)
done
[ "$ERRORS" -eq "$HC09_ERRORS_BEFORE" ] && pass "No unauthorized docker.sock mounts"

# ──────────────────────────────────────────────────────────────
# HC-11: No external CDN calls in themes
# ──────────────────────────────────────────────────────────────
section "HC-11: No external CDN calls in UI themes"
HC11_ERRORS_BEFORE=$ERRORS
THEME_FILES=$(find "$PROJECT_ROOT" \( -name '*.css' -o -name '*.ftl' -o -name '*.html' \) -not -path '*/.git/*' -not -path '*/node_modules/*' 2>/dev/null || true)
for f in $THEME_FILES; do
    CHECKS=$((CHECKS + 1))
    rel_path="${f#$PROJECT_ROOT/}"
    # Check for external URLs (CDN, Google Fonts, etc.)
    if grep -nE '(fonts\.googleapis|cdn\.|cdnjs\.|unpkg\.com|jsdelivr)' "$f" 2>/dev/null | grep -v '^\s*//' | grep -v '^\s*\*' > /dev/null; then
        fail "$rel_path → contains external CDN reference"
        hint "Bundle assets locally or use system-ui font stack"
    fi
done
[ "$ERRORS" -eq "$HC11_ERRORS_BEFORE" ] && pass "No external CDN calls in theme files"

# ──────────────────────────────────────────────────────────────
# EXTRA: Version consistency check
# Verify same image is pinned to same version across all compose files
# ──────────────────────────────────────────────────────────────
section "EXTRA: Image version consistency across compose files"
declare -A IMAGE_VERSIONS
for f in $COMPOSE_FILES; do
    while IFS= read -r line; do
        img=$(echo "$line" | sed 's/.*image:\s*//' | tr -d '"' | tr -d "'" | xargs)
        [ -z "$img" ] && continue
        base=$(echo "$img" | cut -d: -f1)
        ver=$(echo "$img" | grep -o ':.*' | sed 's/://' || echo "none")
        key="${base}"
        if [ -n "${IMAGE_VERSIONS[$key]+x}" ]; then
            existing="${IMAGE_VERSIONS[$key]}"
            if [ "$existing" != "$ver" ]; then
                warn "Image '$base' has inconsistent versions: '$existing' vs '$ver'"
            fi
        else
            IMAGE_VERSIONS[$key]="$ver"
        fi
    done < <(grep -E '^\s+image:' "$f" 2>/dev/null || true)
done

# ──────────────────────────────────────────────────────────────
# EXTRA: Container-internal scripts must not use interactive input
# ──────────────────────────────────────────────────────────────
section "EXTRA: Container-internal scripts have no interactive input"
CONTAINER_SCRIPTS=()
for rel in "${CONTAINER_SCRIPTS[@]}"; do
    f="$PROJECT_ROOT/$rel"
    [ ! -f "$f" ] && continue
    CHECKS=$((CHECKS + 1))
    if grep -nE 'read -[rp]|read -s' "$f" | grep -v '^\s*#' > /dev/null 2>&1; then
        fail "$rel → container-internal script uses interactive input (read -p)"
        hint "This script runs inside a container without TTY. Remove all read commands."
    fi
done

# ──────────────────────────────────────────────────────────────
# EXTRA: Compose files have no version: key
# ──────────────────────────────────────────────────────────────
section "EXTRA: No deprecated version: key in compose files"
for f in $COMPOSE_FILES $SANDBOX_COMPOSE; do
    CHECKS=$((CHECKS + 1))
    rel_path="${f#$PROJECT_ROOT/}"
    if head -5 "$f" | grep -qE '^version:'; then
        warn "$rel_path → has deprecated 'version:' key (Compose v2 doesn't need it)"
    fi
done

# ──────────────────────────────────────────────────────────────
# EXTRA: Agent context files are in sync (if they exist)
# ──────────────────────────────────────────────────────────────
section "EXTRA: Agent context file presence"
for agentfile in "CLAUDE.md" ".cursorrules" ".github/copilot-instructions.md" ".clinerules"; do
    CHECKS=$((CHECKS + 1))
    if [ -f "$PROJECT_ROOT/$agentfile" ]; then
        pass "$agentfile exists"
    else
        warn "$agentfile not found — run .ai/generate.sh to create"
    fi
done

# ══════════════════════════════════════════════════════════════
# SUMMARY
# ══════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}═══════════════════════════════════════${NC}"
echo -e "  Checks run: ${BOLD}$CHECKS${NC}"
echo -e "  Errors:     ${RED}$ERRORS${NC}"
echo -e "  Warnings:   ${YELLOW}$WARNINGS${NC}"
echo -e "${BOLD}═══════════════════════════════════════${NC}"

if [ "$ERRORS" -gt 0 ]; then
    echo -e "${RED}  ✗ VALIDATION FAILED — $ERRORS hard constraint violations${NC}"
    echo ""
    [ "$SHOW_HINTS" = false ] && echo "  Run with --fix-hint to see fix suggestions"
    exit 1
elif [ "$WARNINGS" -gt 0 ]; then
    echo -e "${YELLOW}  ⚠ PASSED WITH WARNINGS — review recommended${NC}"
    exit 2
else
    echo -e "${GREEN}  ✓ ALL CHECKS PASSED${NC}"
    exit 0
fi
