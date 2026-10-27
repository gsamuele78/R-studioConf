<!-- docs/operations/R_VERSION_UPGRADE.md -->
# Upgrading a host's R to the pinned version

Script: `scripts/fix_r_version_inplace.sh`. The pinned version is
`DEFAULT_R_VERSION` in `config/pin_r_version.vars.conf` (HARD RULE 19). This
page moves one host to it. It does not change the pin.

## What changes besides R

On a minor-version change (for example 4.5 → 4.6), compiled packages built for
the old R can call C functions the new R removed. On biome-calc03 (2026-10-27)
R 4.6 no longer had `SETLENGTH`, and the old `r-cran-rlang` and
`r-cran-data.table` builds called it: 136 of 446 packages stopped loading, all
the tidyverse among them. The repository builds of the same packages work.

So on a minor-version change the plan also upgrades, in the same apt
transaction, every installed `r-cran-*` package that has a newer repository
build. `--core-only` skips that and prints a warning; do not use it across a
minor version. Packages installed by hand under `/usr/local/lib/R/site-library`
are not touched: the load test shows whether they still load.

## When the repository no longer has the pinned version

Check with:

```bash
apt-cache madison r-base-core | head
```

If the pinned version is listed, skip to the steps without `--debs`. On
2026-10-27 the repository still offered 4.6.0-2.2404.0 (`apt-cache policy` had
been misread that morning). If it is not listed, take the `.deb` files from a
host that runs it:

1. On that host:

   ```bash
   cd /home/ladmin/configServices/R-studioConf
   sudo bash scripts/fix_r_version_inplace.sh --export-debs /root/r-<version>-debs
   ```

   Each `.deb` comes from the apt cache, then the repository, then `dpkg-repack`
   (rebuilt from the installed files). If it fails with "no .deb", run
   `sudo apt-get install dpkg-repack` and try again. The directory gets a
   `SHA256SUMS` file.
2. Copy the directory to the target host, for example
   `sudo scp -r /root/r-<version>-debs ladmin@<host>:/tmp/`, then
   `sudo mv /tmp/r-<version>-debs /root/` there.
3. Add `--debs /root/r-<version>-debs` to the commands below. When the
   repository offers the same version, apt may download it from there instead;
   the plan says so.

## Steps

1. **Plan** (changes nothing):

   ```bash
   sudo bash scripts/fix_r_version_inplace.sh
   ```

   Check:
   - the core packages go to the pinned version;
   - the `r-cran-*` line: how many packages get the new build;
   - nothing is removed;
   - rollback coverage. Old `r-cran-*` builds are often gone from the
     repository, so a full rollback is rarely possible across a minor version;
     `--accept-partial-rollback` is then needed. Those old builds are the ones
     that would not load under the new R anyway;
   - the user-library line: users whose non-empty personal library exists
     only for the old R X.Y will reinstall those packages. Tell them in advance.
2. **Apply** when nobody is working (the script refuses while an R session runs):

   ```bash
   sudo bash scripts/fix_r_version_inplace.sh --commit [--accept-partial-rollback]
   ```

   It loads every installed R package before and after the upgrade (one
   progress line per batch of 40, a few minutes each time), then restarts
   rstudio-server.
3. **Verify:**
   - `R --version | head -1` shows the pinned version;
   - log in to RStudio on the host and run `library(tidyverse)`;
   - `scripts/99_check_pkg_host_drift.sh` shows one R version across the hosts.

## Results and rollback

| Exit | Meaning |
|---|---|
| 0 | done (or dry-run, or nothing to do) |
| 3 | refused, host unchanged: read the message |
| 5 | R upgraded, but packages that loaded before do not load now: `regressions.txt` in the backup dir |
| 1 | failed: the message gives the rollback command |

On exit 5, find the cause first:

```bash
Rscript --vanilla -e 'loadNamespace("<package>")'
```

An `undefined symbol` error means an old compiled build: upgrade it with
`sudo bash scripts/fix_r_pkg_versions_inplace.sh` (dry-run, then `--commit`), or
reinstall a hand-installed package from source. Roll back only if that cannot
be done in the maintenance window:

```bash
sudo bash scripts/fix_r_version_inplace.sh --rollback /var/backups/biome-calc/r-version-<ts>
sudo apt-mark hold r-base r-base-core r-base-dev r-recommended
```

The rollback reinstalls the saved `.deb` files and restarts rstudio-server. The
hold stops the pin from bringing the new R back on the next `apt upgrade`.

Backup dir `/var/backups/biome-calc/r-version-<ts>/`:
- `before.tsv` and `after.tsv`: every `r-*` package;
- `plan.tsv`;
- `debs/`;
- `load_before.tsv`, `load_after.tsv` and `regressions.txt`.

After applying it, record the host and date in
[HOTFIX_REGISTER.md](HOTFIX_REGISTER.md).
