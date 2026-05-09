# Makefile — R-studioConf top-level convenience targets.
# Pessimistic by design: every target fails fast on first error.

SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

AI_DIR := .ai

.PHONY: help audit validate generate generate-check ai-regen clean-archive doc-coherence


help: ## Show this help
	@awk 'BEGIN {FS=":.*##"; printf "\nR-studioConf Make targets\n  (T1 host = authoritative; T2 docker / T3 k8s mirror T1)\n\n"} /^[a-zA-Z_-]+:.*?##/ {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

audit: validate generate-check doc-coherence ## Full audit gate: validate constraints + verify generated files + doc coherence (HC-14)
	@echo "[audit] PASS — constraints validated, IDE rule files in sync, doc-coherence OK."

doc-coherence: ## HC-14: RPROFILE_VERSION must have a matching CHANGELOG section
	@VER=$$(grep -E '^RPROFILE_VERSION=' config/setup_nodes.vars.conf | head -1 | cut -d'"' -f2); \
	 if [ -z "$$VER" ]; then \
	   echo "[doc-coherence] FAIL — RPROFILE_VERSION not found in config/setup_nodes.vars.conf"; \
	   exit 1; \
	 fi; \
	 if ! grep -qE "^## v$${VER} " docs/reference/Rprofile_site.CHANGELOG.md; then \
	   echo "[doc-coherence] FAIL — RPROFILE_VERSION=$${VER} but no '## v$${VER} ' section in docs/reference/Rprofile_site.CHANGELOG.md (HC-14)"; \
	   echo "[doc-coherence] HINT — append a '## v$${VER} (YYYY-MM-DD) — \"<headline>\"' block with CONTEXT/ARCHITECTURE/WHAT CHANGED/VERIFICATION/ROLLBACK/TIER DELTAS."; \
	   exit 1; \
	 fi; \
	 echo "[doc-coherence] PASS — RPROFILE_VERSION=$${VER} documented in CHANGELOG."

validate: ## Run .ai/validate.sh (constraint compliance)
	@bash $(AI_DIR)/validate.sh

generate: ## Regenerate IDE rule files (CLAUDE.md, .clinerules, .cursorrules, .windsurfrules, .aider.conf.yml, copilot-instructions)
	@bash $(AI_DIR)/generate.sh

generate-check: ## Verify IDE rule files match what generate.sh would produce (CI mode)
	@bash $(AI_DIR)/generate.sh --check

ai-regen: generate ## Alias for `generate`

clean-archive: ## List quarantined orphan paths (does NOT delete; archive/ is reversible)
	@find archive/ -type f 2>/dev/null | sort || echo "no archive/ yet"
