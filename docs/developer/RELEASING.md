<!-- docs/developer/RELEASING.md -->
# Releasing R-studioConf

R-studioConf is deployed on live BIOME-CALC hosts and vendored by
[Infra-Iam-PKI](https://github.com/gsamuele78/Infra-Iam-PKI) (`infra-rstudio/UPSTREAM.lock`).
A release is a git tag `vX.Y.Z` on `main` plus a matching `## [X.Y.Z] - YYYY-MM-DD`
section in [`CHANGELOG.md`](../../CHANGELOG.md). Hosts and the consumer should name a
release, not a branch or a bare commit.

## What the version number means

SemVer here is defined by **what an operator must do on a running host**, because
that is the cost a release imposes:

| Bump | Meaning | Operator action on a live host |
| :-- | :-- | :-- |
| **PATCH** `x.y.Z` | Fixes, including absorbed hotfixes. No new config keys without a safe default. | In place: check out the tag, run the targeted step(s) listed in the release section. No reinstall. Service restarts only if the section says so. |
| **MINOR** `x.Y.0` | New capability or config key (with default), new phase option. | In place, as for PATCH. May need a restart in a maintenance window: the section says which service and why. |
| **MAJOR** `X.0.0` | Re-running a phase from scratch, a manual migration, or a change to the consumer contract (`docker-deploy/` / `kubernetes-deploy/` layout, env var names, image names). | Planned window; migration steps in the section; Infra-Iam-PKI must be told before it syncs. |

`RPROFILE_VERSION` (the R runtime profile, HC-14) keeps its own numbering and log;
a release section names the Rprofile version it ships.

## Every release section must contain

- what changed (Keep a Changelog subsections);
- **Operator action**: the exact in-place step(s) and a verification command per
  host (this is what makes a fix count as deployed);
- **Rollback**: how to return a host to the previous tag;
- hotfixes absorbed by this release, if any.

## Cutting a release

1. Open a PR that moves the `[Unreleased]` entries under a new
   `## [X.Y.Z] - YYYY-MM-DD` heading and leaves an empty `## [Unreleased]` on top.
   `tests/lint/check_changelog.sh` (CI, `t1-static`) checks the structure.
2. After the PR is merged (maintainer's confirmation), tag the merge commit:
   `git tag -a vX.Y.Z -m "R-studioConf X.Y.Z" <merge-sha> && git push origin vX.Y.Z`.
3. `release.yml` publishes the GitHub Release with that section as notes. It fails if
   the section is missing.
4. Never move or delete a published tag; ship a new PATCH instead.

## On a host

```bash
cd /opt/R-studioConf
git fetch --tags origin
git checkout vX.Y.Z          # a tag, not main
# then the "Operator action" of every release between the deployed tag and vX.Y.Z
```
