#!/bin/bash
set -euo pipefail

# .ai/install-hooks.sh
# One-time setup: installs git hooks and generates agent files.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

GREEN='\033[0;32m' BLUE='\033[0;34m' NC='\033[0m'

echo -e "${BLUE}Installing R-studioConf development hooks...${NC}"

# 1. Install pre-commit hook
GIT_HOOKS="$PROJECT_ROOT/.git/hooks"
if [ -d "$GIT_HOOKS" ]; then
    cp "$SCRIPT_DIR/hooks/pre-commit" "$GIT_HOOKS/pre-commit"
    chmod +x "$GIT_HOOKS/pre-commit"
    echo -e "${GREEN}✓${NC} Pre-commit hook installed"
else
    echo "Warning: .git/hooks not found — is this a git repository?"
fi

# 2. Generate agent context files
if [ -f "$SCRIPT_DIR/generate.sh" ]; then
    chmod +x "$SCRIPT_DIR/generate.sh"
    "$SCRIPT_DIR/generate.sh"
else
    echo "Warning: generate.sh not found"
fi

echo ""
echo -e "${GREEN}Setup complete.${NC}"
echo "  Pre-commit hook: validates constraints before every commit"
echo "  Agent files: generated from project.yml + code scan"
echo ""
echo "  To update after code changes: .ai/generate.sh"
echo "  To validate manually:         .ai/validate.sh --fix-hint"
