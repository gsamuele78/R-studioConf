# AI Agent Context Optimization — R-studioConf

## Problem Statement

The current agent context system works correctly but wastes tokens at every load.
The core constraint set is 12 hard rules (~400 tokens). Those 12 rules are currently
copy-pasted **verbatim** into 7 different files: `agents.md`, `CLAUDE.md`, `.clinerules`,
`.cursorrules`, `.github/copilot-instructions.md`, `claude.md`, and all three `SKILL.md`
files reference them again. Every agent session re-reads the same rules 2–3 times.

Additionally, `agents.md` (the SSOT for narrative context) has not been updated since
`2026-03-12` and is missing 6+ weeks of architectural decisions captured in conversation logs:
- `/Rtmp` disk migration (replacing tmpfs)
- Modular `profile.d/` R configuration
- OpenBLAS serial migration
- NIMBLE MCMC workload hardening
- Session forensic diagnostics
- `50_setup_nodes.sh` + `r_env_manager.sh` additions

---

## Diagnosis: Token Waste Map

| Layer | File | Useful tokens | Wasted tokens (duplication) |
|---|---|---|---|
| SSOT | `.ai/project.yml` | 100% | 0% |
| Narrative | `.ai/agents.md` | 100% | 0% |
| Claude overlay | `.ai/claude.md` | ~30% unique | ~70% repeats agents.md |
| Gemini overlay | `.ai/gemini.md` | ~40% unique | ~60% repeats agents.md |
| ChatGPT overlay | `.ai/chatgpt.md` | ~35% unique | ~65% repeats agents.md |
| Auto-loaded | `CLAUDE.md` | generated | entire agents.md embedded |
| Auto-loaded | `.clinerules` | generated | entire agents.md embedded |
| Auto-loaded | `.cursorrules` | generated | 12 rules + versions |
| Auto-loaded | `.github/copilot-instructions.md` | generated | 12 rules + versions |
| Skills | `compose-constraint-audit/SKILL.md` | unique | re-lists 5 of 12 rules in prose |
| Skills | `script-safety-review/SKILL.md` | unique | re-lists HC-03/04/10/12 in prose |
| Skills | `sandbox-test/SKILL.md` | compact | mostly unique ✓ |

**Root issue in generated files:** `CLAUDE.md` and `.clinerules` each embed the full
`agents.md` (157 lines) after the compact rules block. An agent reading either file
sees the 12 rules twice. The `generate.sh` should stop embedding the full narrative
in auto-loaded files — the compact rules block is sufficient for IDE/CLI agents.

---

## Open Questions

> [!IMPORTANT]
> **Q1 — `agents.md` update scope:** Should I update `agents.md` to reflect the
> architectural changes from the past 6 weeks (Rtmp disk, profile.d, OpenBLAS serial,
> NIMBLE hardening, new scripts `50_setup_nodes.sh`, `r_env_manager.sh`, forensic diag
> script)? This is the only file that requires human judgment to maintain (per README).
> **Default: YES** — it is clearly stale.

> [!IMPORTANT]
> **Q2 — `CLAUDE.md` / `.clinerules` generation:** Should I modify `generate.sh` so
> that the auto-generated files contain ONLY the compact rules block (without embedding
> the full `agents.md` narrative)? The narrative is available on-demand via
> `agents.md` / `.ai/claude.md`. This cuts ~60% tokens from every IDE agent session.
> **Default: YES** — but this changes the contract of the generated files.

> [!WARNING]
> **Q3 — `extracted_versions.env` stale data:** Multiple images are still tagged
> `latest` (botanicals, rstudio-botanical-*). This violates HC-07 and is called out
> in the skill. Should I flag this in the plan or is this a known intentional local
> image naming convention?

---

## Proposed Changes

### 1. `.ai/agents.md` — Update narrative SSOT
#### [MODIFY] [agents.md](file:///home/jfs/00_Antigravity_workspace/R-studioConf/.ai/agents.md)

- Bump version to `3.0.0`, date to `2026-04-23`
- Add new scripts to Section 5: `50_setup_nodes.sh`, `r_env_manager.sh`,
  `scripts/system_diagnostic.R`
- Add new subsection **3.5 R Runtime Hardening** documenting:
  - Storage: `/Rtmp` (400GB ext4, replaces tmpfs) for NIMBLE/big-data workloads
  - R config: modular `/etc/biome-calc/profile.d/` loader pattern
  - BLAS: `libopenblas0-serial` (not pthread) — thread-safety for matrix ops
  - Session resilience: NGINX payload tuning for OOM-prone RStudio sessions
- Remove verbose "How to Use This File" preamble (Section 0) — replaced by
  a 3-line terse header. Agents don't benefit from meta-instructions about
  how to read the file; they just need the content.

---

### 2. `.ai/claude.md` — Deduplicate, add Antigravity-specific rules
#### [MODIFY] [claude.md](file:///home/jfs/00_Antigravity_workspace/R-studioConf/.ai/claude.md)

Current state: 63 lines. ~40 lines are a straight copy of the constraints checklist
already in `agents.md`.

Proposed: strip the project summary (already in agents.md which is loaded alongside)
and keep ONLY:
- Claude behavioral corrections (over-explaining, apology, code-first)
- Output format rules (complete files, path-as-comment, no `# ... rest of config`)
- The constraints checklist (as a quick-verify block — keep this, it's unique value)
- Add: Antigravity-specific note — Antigravity loads skills lazily; always check
  `.agents/skills/` before implementing compose/script/sandbox tasks

Target: ~45 lines (↓ from 63). Mostly cuts repeated project summary.

---

### 3. `.ai/gemini.md` — Deduplicate, add Antigravity grounding
#### [MODIFY] [gemini.md](file:///home/jfs/00_Antigravity_workspace/R-studioConf/.ai/gemini.md)

Proposed: Same approach as claude.md. Remove redundant project summary block.
Keep only gemini-specific behavioral corrections (4 mistake types) and the
constraint checklist. Cut from 83 to ~55 lines.

---

### 4. `.ai/chatgpt.md` — Deduplicate
#### [MODIFY] [chatgpt.md](file:///home/jfs/00_Antigravity_workspace/R-studioConf/.ai/chatgpt.md)

ChatGPT uses this as a standalone file (no agents.md alongside), so the project
summary is needed. But the "How to Use This File with ChatGPT" section (14 lines)
can be trimmed to a 3-line note. Keep the "Compact Rules Block" as-is — it is
designed to be copied to Custom Instructions. No change to the behavioral correction
sections. Target: ~70 lines (↓ from 91).

---

### 5. `generate.sh` — Stop embedding full agents.md in auto-loaded files
#### [MODIFY] [generate.sh](file:///home/jfs/00_Antigravity_workspace/R-studioConf/.ai/generate.sh)

Currently `generate.sh` appends `agents.md` verbatim into `CLAUDE.md` and `.clinerules`.
This means every Claude Code / Cline session loads:
1. The compact rules block (useful, ~60 lines)
2. The full agents.md narrative (157 lines, entirely redundant — agent can just open agents.md)

**Fix:** In the sections that generate `CLAUDE.md` and `.clinerules`, replace the
`cat agents.md` embed with a single pointer line:
```
# Full narrative context: .ai/agents.md (read on-demand)
```
This saves ~157 lines (~1200 tokens) per auto-loaded file, per session.

> [!WARNING]
> This means `.clinerules` will no longer be fully self-contained. Cline agents
> working without file access to `.ai/agents.md` may miss context. Acceptable
> trade-off for most sessions since the constraints block is complete.

---

### 6. `.agents/skills/compose-constraint-audit/SKILL.md` — Add version cross-ref
#### [MODIFY] [SKILL.md](file:///home/jfs/00_Antigravity_workspace/R-studioConf/.agents/skills/compose-constraint-audit/SKILL.md)

Add note that local botanical images use `:latest` by convention (they are locally
built, never pulled from a registry), which is an intentional exception to HC-07.
Without this note, every agent flags the local images as HC-07 violations. Also
add the `/Rtmp` tmpfs context to the resource limits section.

---

### 7. `.agents/skills/script-safety-review/SKILL.md` — Add new scripts
#### [MODIFY] [SKILL.md](file:///home/jfs/00_Antigravity_workspace/R-studioConf/.agents/skills/script-safety-review/SKILL.md)

Add to the script coupling dependency chain: `50_setup_nodes.sh` → `r_env_manager.sh`
→ `/etc/biome-calc/profile.d/` → RStudio container. Without this, agents editing
`50_setup_nodes.sh` miss the modular profile.d downstream.

---

### 8. `.ai/project.yml` — Add funded projects and R-runtime context
#### [MODIFY] [project.yml](file:///home/jfs/00_Antigravity_workspace/R-studioConf/.ai/project.yml)

Add `r_runtime` section (non-extractable from code, needed by generate.sh):
```yaml
r_runtime:
  blas: libopenblas0-serial   # pthread variant causes SIGSEGV with matrix ops
  tmp_disk: /Rtmp             # 400GB ext4, replaces tmpfs (since 2026-04)
  config_dir: /etc/biome-calc/profile.d/  # modular R config loader
  workloads: [NIMBLE MCMC, geospatial, big-data matrix]
```
Also bump `version` to `2.0.0` to match agents.md.

---

## Files NOT changed

| File | Reason |
|---|---|
| `.aider.conf.yml` | Only 5 lines, correct, no change needed |
| `.github/copilot-instructions.md` | Generated — will auto-update when generate.sh runs |
| `CLAUDE.md` | Generated — will auto-update when generate.sh runs |
| `.clinerules` | Generated — will auto-update when generate.sh runs |
| `.cursorrules` | Generated — will auto-update when generate.sh runs |
| `.agents/skills/sandbox-test/SKILL.md` | Already compact and accurate |
| `.ai/hooks/pre-commit` | Not in scope |
| `.github/workflows/*` | Not in scope |

---

## Verification Plan

### After edits
1. Run `.ai/generate.sh` to regenerate all auto-loaded files with new template.
2. Run `.ai/validate.sh --fix-hint` — expect 0 new failures.
3. Manual token count comparison: `wc -w` on `CLAUDE.md` before and after.
4. Spot-check that `CLAUDE.md` no longer contains the full narrative prose
   (search for "BIOME research group" — should NOT appear in generated files after change).
5. Spot-check that `.clinerules` constraint checklist is still complete.

### Expected savings
| File | Before (lines) | After (lines) | Delta |
|---|---|---|---|
| `CLAUDE.md` | 269 | ~115 | −154 |
| `.clinerules` | 160 | ~110 | −50 |
| `.ai/claude.md` | 63 | ~45 | −18 |
| `.ai/gemini.md` | 83 | ~55 | −28 |
| `.ai/agents.md` | 157 | ~185 | +28 (new arch content) |

**Net effect per Antigravity/Claude session loading all context:**
~250 fewer lines to process on every task that touches compose or scripts.
