# .ai/ — Agent Context System

## Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│                        SINGLE SOURCE OF TRUTH                        │
│                                                                      │
│  .ai/project.yml          (manually maintained constraints)          │
│       +                                                              │
│  Actual codebase           (image versions, scripts, .env vars)      │
│       ↓                                                              │
│  .ai/generate.sh           (extracts + merges → generates files)     │
│       ↓                                                              │
│  ┌────────────────────────────────────────────────────────────────┐  │
│  │  AUTO-LOADING FILES (committed to git)                         │  │
│  │                                                                │  │
│  │  CLAUDE.md                    → Claude Code CLI                │  │
│  │  .cursorrules                 → Cursor IDE                     │  │
│  │  .github/copilot-instructions → GitHub Copilot                │  │
│  │  .clinerules                  → Cline (VS Code)                │  │
│  │  .windsurfrules               → Windsurf                       │  │
│  │  .aider.conf.yml              → Aider                          │  │
│  └────────────────────────────────────────────────────────────────┘  │
│  ┌────────────────────────────────────────────────────────────────┐  │
│  │  MANUAL-UPLOAD FILES (committed to git, uploaded to platforms) │  │
│  │                                                                │  │
│  │  .ai/agents.md + .ai/claude.md   → Claude.ai Project          │  │
│  │  .ai/agents.md + .ai/chatgpt.md  → ChatGPT Custom GPT         │  │
│  │  .ai/gemini.md                    → Gemini Gem                  │  │
│  └────────────────────────────────────────────────────────────────┘  │
│       ↑                                                              │
│  .ai/validate.sh          (checks code against constraints)          │
│       ↑                                                              │
│  .ai/hooks/pre-commit     (blocks commits violating constraints)     │
│       ↑                                                              │
│  .github/workflows/ai-context.yml  (CI enforcement on push/PR)       │
└──────────────────────────────────────────────────────────────────────┘
```

## Files

| File | Maintained By | Purpose |
|------|--------------|---------|
| `project.yml` | Human (you) | Hard constraints, known bugs, branding, script categories |
| `agents.md` | Human (you) | Rich narrative documentation for all agents |
| `claude.md` | Human (you) | Claude-specific behavioral corrections |
| `gemini.md` | Human (you) | Gemini-specific grounding rules |
| `chatgpt.md` | Human (you) | ChatGPT-specific behavioral corrections |
| `generate.sh` | **Automated** | Extracts from code + project.yml → generates tool files |
| `validate.sh` | **Automated** | Checks codebase against hard constraints |
| `extracted_versions.env` | **Generated** | Image versions found in actual compose files |
| `hooks/pre-commit` | **Automated** | Blocks commits that violate constraints |
| `install-hooks.sh` | Run once | Sets up git hooks + generates files |

## Quick Start

```bash
# One-time setup (installs hooks + generates all files)
chmod +x .ai/install-hooks.sh
.ai/install-hooks.sh

# After any code change that affects compose/scripts
.ai/generate.sh

# Manual validation with fix hints
.ai/validate.sh --fix-hint

# CI check (used in GitHub Actions)
.ai/validate.sh --ci
.ai/generate.sh --check
```

## What Gets Updated When

| You Change... | Action Needed |
|---------------|---------------|
| Image version in docker-compose.yml | Run `.ai/generate.sh` (auto-extracts new version) |
| Add/remove a script | Run `.ai/generate.sh` (updates script inventory) |
| Add/remove a .env variable | Run `.ai/generate.sh` (updates variable reference) |
| Change a hard constraint | Edit `project.yml` → run `.ai/generate.sh` |
| Add a known bug | Edit `project.yml` (generate.sh is optional) |
| Add a new compose service | Run `.ai/validate.sh` to check it has limits/healthcheck |

## What Is NOT Automated

| Task | Why Not | What To Do |
|------|---------|-----------|
| Updating agents.md narrative | Rich prose requires human judgment | Edit manually when architecture changes |
| Updating model-specific .md files | Behavioral corrections are model-specific | Edit manually when you notice new agent mistakes |
| Uploading to Claude.ai/ChatGPT/Gemini | No API for knowledge upload | Re-upload .ai/*.md files when they change |

## Design Principles

1. **Code is truth.** Image versions are extracted FROM compose files, not declared in a separate config. If the compose file says `postgres:15-alpine`, that's what all agent files will say.

2. **project.yml is minimal.** It contains ONLY what can't be extracted from code: engineering philosophy, constraint rationale, bug severity, script behavioral categories.

3. **Generated files are disposable.** Delete CLAUDE.md, .cursorrules, etc. and regenerate them. The source of truth is project.yml + code.

4. **Enforcement has three layers:**
   - **Pre-commit hook** → catches violations before they enter git
   - **CI pipeline** → catches violations that bypass the hook
   - **Agent context** → prevents violations from being generated in the first place

5. **Pessimistic by design.** The validator assumes code is wrong until proven right. The generator assumes generated files are outdated until regenerated. The CI assumes nothing passes until it runs.
