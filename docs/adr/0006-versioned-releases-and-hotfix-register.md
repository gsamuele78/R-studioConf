<!-- docs/adr/0006-versioned-releases-and-hotfix-register.md -->
# ADR-0006: Versioned releases, a hotfix register and a host deployment ledger

Status: Accepted (first release `v2026.10.0`, 2026-10-20)
Date: 2026-10-20

## Context

- `CHANGELOG.md` had a single `[Unreleased]` section covering months of work.
  Nothing said which changes a host runs, and the repo had no git tags.
- The R banner does not identify the code either: `RPROFILE_VERSION` stays
  `12.11` across v12.11, v12.11-fix, -fix2 and -fix3 (the fixes do not bump it).
  On 2026-10-20, calc04 and a fixed host would have shown the same banner.
- Hosts are patched in place (`scripts/fix_*_inplace.sh`, `scripts/tools/hotfix_*.sh`)
  before a release absorbs the fix. Which host got which hotfix was recorded only
  in PR threads and ADR rollout logs.
- Host checkouts drift: on 2026-10-20 calc04 was on an unmerged 2026-07 branch,
  and a Step 8 redeploy from it rolled back the bspm fix. calc01-03 are on `main`
  with 13-15 locally modified files each.

## Decision

1. **Repo releases use calendar versions**, tagged on `main`: `vYYYY.MM.N`
   (`N` counts from 0 within the month). `RPROFILE_VERSION` keeps its own
   numbering. Each release names the R profile version it ships.
2. **`CHANGELOG.md` gets one section per release**: `## [YYYY.MM.N] - <date> — Rprofile <version>`.
   Each section opens with four lines: profile shipped, how to deploy, the in-place
   hotfixes it absorbs, and the hosts it was tested on. Then come the Keep a
   Changelog groups (Security, Fixed, Added, Changed). New work lands in
   `[Unreleased]` and moves under the release when it is tagged.
3. **Every in-place hotfix gets a row in [`docs/operations/HOTFIX_REGISTER.md`](../operations/HOTFIX_REGISTER.md)**
   in the PR that ships it, and an update when it is applied: hosts, date, backup
   directory, and the release that absorbs it. Until a release absorbs it, the
   hotfix is "pending" and a redeploy of an older release would undo it.
4. **The same file keeps a host deployment ledger**: host, release tag, branch,
   date. A host deploys only from a release tag or from `main`, never from a
   feature branch except the test host during a PR test.
5. **A GitHub Release is created from each tag.** Its body is the release's
   `CHANGELOG.md` section.

## Consequences

- One identifier (the tag) answers "what runs on this host" and "what changed
  between two hosts": `git log vA..vB` and the two changelog sections.
- The register and the ledger are maintained by hand. They go stale if a
  hotfix or a redeploy is not recorded. Mitigation: the PR checklist and the
  roadmap's definition of done require the update.
- Existing hotfix scripts other than the bspm one have no recorded host state.
  The register lists them as "unknown" until they are checked on the hosts.
- Not done yet:
  - Step 8 does not write the deployed tag on the host, so the ledger cannot be
    checked automatically. Proposed follow-up: Step 8 writes
    `git describe --tags --always --dirty` to a stamp file under `/etc/biome-calc/`,
    and a read-only drift check compares the stamps across hosts.
  - `50_setup_nodes.sh` does not refuse to deploy an older template over a newer
    one (the calc04 incident). Proposed follow-up, separate PR.

## Rollback

Documentation only. Deleting a tag (`git push origin :refs/tags/vX`) and its
GitHub Release undoes a release; host files are not touched by this ADR.
