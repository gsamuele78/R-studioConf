<!-- docs/adr/0003-in-place-host-update-and-hotfix-contract.md -->
# ADR-0003: Update live hosts in place; hotfixes follow one contract and are absorbed by the next release

Status: Proposed
Date: 2026-10-12

## Context

The T1 configuration is deployed in production on the BIOME-CALC hosts. A full
reinstall (`scripts/50_setup_nodes.sh` from scratch) interrupts researchers'
sessions, re-runs phases that touch SSSD/PAM/Samba, and is not needed for most
fixes. Today there is no normal way to bring a host from one version of this
repository to the next:

- `50_setup_nodes.sh` is driven by an interactive `read -p` menu; single steps
  (e.g. step 8, Rprofile/Renviron) cannot be scripted or planned.
- Nothing on the host records which commit or release it runs (only
  `RPROFILE_VERSION` for the R profile). "Deployed" cannot be checked (ADR-0002, L4).
- Live fixes exist but each has its own convention:

| Script | Default | Dry run | Backup | Rollback | Atomic write |
|---|---|---|---|---|---|
| `scripts/fix_login_script_rlibs_inplace.sh` | dry run | yes | `cp -p` | `--rollback DIR` | `mv` |
| `scripts/fix_pam_segfault_inplace.sh` | **applies** | `--check` | `/root/...` | last backup | partial |
| `scripts/tools/hotfix_smtp_site_overrides.sh` | asks | `--dry-run` | yes | manual | no |
| `scripts/update_nginx_templates.sh` | **applies** | no | **no** | **no** | no (`tee`) |

`update_nginx_templates.sh` is the worst case: when `nginx -t` fails it leaves the
broken config on disk ("Changes applied but service NOT restarted"), and on success
it always restarts both nginx **and** rstudio-server, ending every active session.

- Hotfixes are not tied back to the code: a host patched live can diverge from what
  the next install would produce, and nobody can say whether the fix is "in main".
  The `setwd` fix stayed off the hosts for four months (D-R03, PR #26).

## Decision

### 1. Hosts run releases, and say which

Hosts are updated only to a **release tag** (`vX.Y.Z`, RELEASING.md, PR #30), never
to a moving `main`. Every update or hotfix writes `/etc/biome-calc/release.json`
(with `jq`, mode 0644, root-owned):

```json
{ "tag": "v0.1.1", "commit": "<sha>", "applied_at": "<ISO-8601>",
  "journal": "/var/backups/biome-calc/update-<ts>",
  "hotfixes": [ { "id": "HF-2026-001", "applied_at": "...", "absorbed_in": null } ] }
```

The SemVer rule in RELEASING.md decides the path: PATCH and MINOR are applied in
place by the update tool; MAJOR means a phase must be re-run or the consumer
contract (Infra-Iam-PKI) changes, and says so in its "Operator action".

### 2. One non-interactive update entry point

A new `scripts/update_host.sh` (name provisional) with three modes:

- `--plan` (**default**, read-only): render every managed artefact into a staging
  directory with the existing `process_template`, diff against what is deployed,
  list which services would be reloaded or restarted, report active RStudio
  sessions (`rstudio-server active-sessions`). Exit 0 = nothing to do, 10 = changes
  pending, ≥ 1 other = error.
- `--apply`: for each changed file, back up and record `sha256` before/after in a
  journal under `/var/backups/biome-calc/update-<ts>/`; write to a temp file in the
  **same directory** and `mv` (atomic); run the owning validator **before** the
  service sees the file (`nginx -t`, `bash -n`, R parse, `sssctl config-check`); on
  validator failure restore that file from the journal and stop. Prefer `reload`
  to `restart`. rstudio-server is restarted only with `--allow-restart`, after
  printing the active session count.
- `--rollback <journal>`: restore every file in the journal, verify the original
  `sha256`, reload the same services.

Render logic is moved out of the phases incrementally into "render only" functions
that both the install phase and the update tool call, so there is one way to
produce each file. First targets: step 8 (Rprofile/Renviron fragments under
`/etc/biome-calc/profile.d/`) and the nginx templates, replacing
`update_nginx_templates.sh`. Phases that change identity or PAM (SSSD join, Samba,
PAM stack) stay out of scope of `--apply` until each has its own validator and VM
test; for those, a release is MAJOR or ships a hotfix under section 3.

### 3. Hotfix contract

A live fix that cannot wait for a release lives in `scripts/hotfix/HF-<YYYY>-<NNN>_<slug>.sh`
and must:

- start with `#!/usr/bin/env bash` / `set -euo pipefail`, source shared helpers in
  `lib/` (backup, atomic swap, journal, `release.json` update) — no private copies;
- accept the same flags: `--check` (**default**, read-only, exit 0 = already
  applied or not needed, 10 = would change), `--apply`, `--rollback <journal>`;
- be **idempotent**: a second `--apply` changes 0 files and exits 0;
- record itself in `release.json.hotfixes[]`;
- be introduced **in the same PR** as the change to the template/phase that makes a
  fresh install produce the same result, plus a convergence test (render the
  template, apply the hotfix to the old output, compare).

### 4. Absorption

The next PATCH release lists the hotfix under "Hotfixes absorbed" (RELEASING.md).
On a hotfixed host, `update_host.sh --plan` for that release must show **0 diff**
on the files the hotfix touched; the update sets `absorbed_in` for that hotfix.
After the release ships, the hotfix script moves to `scripts/archive/hotfix/`.

### 5. Migration of existing scripts

In order of risk: `update_nginx_templates.sh` (no backup, broken config left
behind, forced RStudio restart) → `fix_pam_segfault_inplace.sh` (applies by
default) → `hotfix_smtp_site_overrides.sh` → `fix_login_script_rlibs_inplace.sh`
(already closest to the contract). Each migration is its own PR; the old script
stays until its replacement has reached L3.

## Measurement (pre-registered, ADR-0002)

| ID | Metric | Baseline (today) | Target | Evidence level |
|---|---|---|---|---|
| M1 | Lead time merge → all hosts for a PATCH | ~4 months (`setwd`) | ≤ 7 days | L4 |
| M2 | Share of PATCH/MINOR releases applied with `update_host.sh` (no phase re-run) | 0 (no mechanism) | ≥ 90 % | L4 |
| M3 | Files changed by a second `--apply` / hotfix `--apply` | not measurable | 0 | L2 VM |
| M4 | Rollbacks restoring the original `sha256` of every file | n/a (nginx script: no backup) | 100 % | L2 VM, then L3 |
| M5 | rstudio-server restarts per PATCH not declared in "Operator action" | 1 per nginx update | 0 | L3 |
| M6 | Diff on hotfix files after absorption (`--plan` on a hotfixed host) | not measurable | 0 | L2 VM, then L3 |
| M7 | Hosts reporting their release (`release.json`) | 0 | 100 % | L4 |
| Guard | Failed validator leaves the previous file in place | no (nginx script) | always | L2 mutation: inject a broken template |

Validation path: disposable Ubuntu 24.04 VM (L2, never the sandbox, which is
broken) → one canary host (L3) → fleet (L4). A target missed at L2 blocks L3.

## Consequences

- Positive: most fixes reach hosts without reinstalling or ending sessions; every
  host can say what it runs; live patches stop drifting from the code.
- Negative: extracting render functions from the phases is real refactoring work in
  scripts that run as root on production; each extraction needs its VM test.
- Negative: hosts must have the repository checked out at a tag (or a release
  tarball); this ADR does not pick the transport. Default proposed: `git fetch
  --tags && git checkout vX.Y.Z` in the existing checkout, decided in the first
  implementation PR.
- Risk: `--apply` on the PAM/SSSD side can lock users out; that is why those phases
  are explicitly excluded until they have validators and VM coverage.
- T2/T3 are not affected: containers are rebuilt from the same tag (rule: T1 first,
  then ported forward). Infra-Iam-PKI consumes images built from a tag, so a tag on
  the host and a tag in the image mean the same code.

## Alternatives considered

- **Reinstall from scratch for every release.** Rejected: interrupts researchers,
  re-runs identity phases, and is why fixes were not deployed.
- **Configuration management tool (Ansible etc.).** Rejected here: the stack is
  final (CLAUDE.md); the same idempotency and journal are reachable with the
  existing bash/`process_template` code. Can be revisited by a new ADR.
- **Keep ad-hoc `*_inplace.sh` scripts.** Rejected: four conventions, one without
  backup; no link to the release; no proof of absorption.

## Rollback

The ADR adds files and does not change existing scripts. Reverting it means
deleting `scripts/update_host.sh`, `scripts/hotfix/` and the `release.json`
writes; hosts keep running the files already deployed. Each implementation PR
carries its own rollback.
