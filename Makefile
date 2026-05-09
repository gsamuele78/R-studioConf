# Makefile — R-studioConf top-level convenience targets.
# Pessimistic by design: every target fails fast on first error.

SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

AI_DIR := .ai

.PHONY: help audit validate generate generate-check ai-regen clean-archive

help: ## Show this help
	@awk 'BEGIN {FS=":.*##"; printf "\nR-studioConf Make targets\n  (T1 host = authoritative; T2 docker / T3 k8s mirror T1)\n\n"} /^[a-zA-Z_-]+:.*?##/ {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

audit: validate generate-check ## Full audit gate: validate constraints + verify generated files are up-to-date
	@echo "[audit] PASS — constraints validated and IDE rule files in sync."

validate: ## Run .ai/validate.sh (constraint compliance)
	@bash $(AI_DIR)/validate.sh

generate: ## Regenerate IDE rule files (CLAUDE.md, .clinerules, .cursorrules, .windsurfrules, .aider.conf.yml, copilot-instructions)
	@bash $(AI_DIR)/generate.sh

generate-check: ## Verify IDE rule files match what generate.sh would produce (CI mode)
	@bash $(AI_DIR)/generate.sh --check

ai-regen: generate ## Alias for `generate`

clean-archive: ## List quarantined orphan paths (does NOT delete; archive/ is reversible)
	@find archive/ -type f 2>/dev/null | sort || echo "no archive/ yet"
