<!-- docs/adr/0004-replicated-local-r-libraries.md -->
# ADR-0004: Keep R libraries on local disk and replicate their contents across hosts

Status: Proposed
Date: 2026-10-15

## Context

On 2026-10-15 a researcher's mlr3 script was compared across hosts. Read as the
researcher, with the same `.libPaths()` on both hosts:

| Package | biome-calc01 | biome-calc04 | Loaded from |
|---|---|---|---|
| mlr3 | 1.8.0 | not installed | `/usr/lib/R/site-library` |
| mlr3spatiotempcv | 2.3.5 | not installed | `/usr/lib/R/site-library` |
| future | 1.76.0 | 1.70.0 | `/usr/lib/R/site-library` |
| ranger | 0.18.0 | 0.18.0 | `/usr/lib/R/site-library` |

The NFS home (`biome-store03:/mnt/zpool/home`) is the same mount on both hosts and
the researcher's NFS library holds one entry on both. So the difference is in
`/usr/lib/R/site-library`, which is **local to each host**.

How packages get there: the profile enables bspm
(`templates/Rprofile_site.R.template`, section 0, `bspm.sudo = TRUE`), so
`install.packages()` becomes an apt install of `r-cran-*` into the system library
of the host the user is on. An admin running `sudo R` does the same. Nothing
replicates that install to the other hosts and nothing reports the difference.
`scripts/99_check_pkg_drift.sh` compares one host with its own past baseline, not
hosts with each other.

Effect for researchers: "it works on server X but not on Y" is usually package
drift, not a defect. It cost a full investigation on 2026-10-15 (ranger error).

Constraint from history: v12.4 moved `R_LIBS_USER` **off** NFS to
`/var/lib/biome-Rlibs/<user>/<ver>` because of the "NFS Library Storm": with many
parallel workers, each `library()` performs thousands of metadata lookups on NFS
(`docs/operations/UPGRADE_TO_v12.4.md`). Any fix must not put package loading back
on NFS.

### Baseline (measured 2026-10-15, `99_check_pkg_host_drift.sh --compare`, 4 hosts)

| Measure | Value |
|---|---|
| Packages seen across hosts | 690 |
| Missing on at least one host | 246 |
| Same package, different version | 180 |
| Drifting packages | **426 (62 %)** |
| R version | 4.6.0 on calc01/02/04, **4.5.3 on calc03** (pin is 4.6.0, HARD RULE 19) |

Pattern: biome-calc01 carries the newest versions and most extra packages
(e.g. the whole mlr3 stack incl. mlr3spatiotempcv 2.3.5); calc02 has an older
mlr3 1.6.0 without mlr3spatiotempcv; calc03/04 have no mlr3 at all; calc04 alone
has the nimble* extensions. Core compiled packages drift too (rlang 1.3.0 /
1.2.0 / 1.1.7; terra 1.9-50 / 1.9-25 / 1.9-1; Rcpp 1.1.2 / 1.1.1).

## Decision

R packages stay on **local disk** on every host; what is installed is made the
**same on every host** by replication, and drift is measured.

1. **Measure (this ADR's first step).** `scripts/99_check_pkg_host_drift.sh`
   snapshots the system libraries of each host (reads `DESCRIPTION` files: no R
   start, no profile, no NFS) and compares snapshots. Exit `1` on any missing
   package, version mismatch or R version mismatch.
2. **Declare.** The base set stays in `config/r_env_manager.conf`
   (`R_USER_PACKAGES_CRAN`, the single source of truth, HARD RULE 19). Packages
   installed later on any host are appended to a small shared request list (one
   line per install; a tiny NFS write, not a lookup storm). Format and location are
   decided in step 3, not here.
3. **Reconcile (later, test host first).** A per-host job (systemd timer or
   `update_host.sh`, ADR-0003) installs, through apt, whatever in the base set or
   the request list is missing on that host, and aligns versions, not only names.
   The drift check runs after it and is the acceptance test.

Metric: number of drifting packages between hosts from step 1. Target: `0` after
each reconcile run; the current value is measured on every host before step 3.

## Consequences

- Package loading stays local: no return of the v12.4 NFS storm.
- A researcher's install appears on the other hosts after the next reconcile run,
  not immediately. Until then the drift check reports it.
- Versions: apt/r2u serve "latest at install time". Two hosts installing on
  different days can differ in patch level unless the reconciler pins versions.
  This is the main open design question of step 3.
- Per-user local libraries (`/var/lib/biome-Rlibs/<user>/<ver>`) are also host-local
  and are **not** covered by step 1, which reads only the system libraries. If they
  turn out to hold real research dependencies they need the same treatment.
- T2/T3: one container image per build; packages are baked at build time (HARD
  RULE 10), so cross-host drift does not arise there. No tier delta needed.

## Alternatives considered

- **Personal libraries on NFS, bspm off for researchers** — identical on every
  host by construction, but brings back the v12.4 NFS Library Storm. Rejected.
- **Keep today's state** — every install widens the gap; already caused a false
  "server bug" report. Rejected.
- **Only admins install packages (bspm off for users)** — removes self-service the
  researchers rely on and still needs replication across hosts for admin installs.
  Rejected as a standalone fix; may be combined with step 3.

## Rollback

Step 1 is read-only: delete the script. Steps 2–3 add a list and a job; disabling
the job stops replication and leaves every host exactly as it is.
