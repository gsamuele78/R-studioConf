<!-- docs/developer/git_submodule_workflow.md -->
# Infra-Iam-PKI Consumer Workflow

## Current state

`R-studioConf` has no Git submodules as of 2026-10-06:

- `.gitmodules` is absent.
- the Git index contains no `160000` gitlink entries.
- `.ai/project.yml` declares `submodules: {}`.

`Infra-Iam-PKI` was formerly a submodule. Commit `37fdb32` removed that relationship when the T2 and T3 deployment trees became self-contained in this repository.

## Repository relationship

`Infra-Iam-PKI` is now a downstream consumer, not a directory to edit from this repository. It vendors byte-identical copies of:

- `docker-deploy/`
- `kubernetes-deploy/`

The consumer records the source revision in `infra-rstudio/UPSTREAM.lock` and refreshes its copies with `scripts/infra-rstudio/sync_rstudioconf.sh` in the `Infra-Iam-PKI` repository.

## Required workflow

1. Make and validate RStudio deployment changes in `R-studioConf`.
2. Fix host behavior in T1 first when the defect exists there.
3. Port the behavior to T2 and then T3, or record an explicit tier delta in `.ai/project.yml`.
4. Keep `docker-deploy/` and `kubernetes-deploy/` self-contained: no `../` paths and no reads from root `config/` or `templates/`.
5. Commit and publish the `R-studioConf` change through the normal repository workflow.
6. In the separate `Infra-Iam-PKI` checkout, run its sync script and review the vendored diff and updated lock before committing there.

Do not run `git submodule update`, stage an `Infra-Iam-PKI` directory, or attempt to update a submodule pointer in this repository. Those instructions describe the pre-`37fdb32` layout.

## Protected legacy path

`Infra-Iam-PKI.backup` is excluded by project policy and must not be touched. It is not an active integration surface.

Unverified: the downstream consumer checkout and its `UPSTREAM.lock` are outside this repository, so their current revision and sync result were not inspected in this audit.
