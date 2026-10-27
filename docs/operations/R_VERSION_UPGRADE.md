<!-- docs/operations/R_VERSION_UPGRADE.md -->
# Upgrading a host's R to the pinned version

Script: `scripts/fix_r_version_inplace.sh`. The pinned version is
`DEFAULT_R_VERSION` in `config/pin_r_version.vars.conf` (HARD RULE 19). This
page moves one host to it. It does not change the pin.

## When the repository no longer has the pinned version

On 2026-10-27, `apt-cache policy r-base-core` on biome-calc03 showed candidate
4.6.1 at priority 500. A 4.6.0 entry would have been chosen at priority 1001 by
the pin, so 4.6.0 is no longer offered by the CRAN repository. The `.deb`
files come from a host that runs 4.6.0. Confirm this first with:

```bash
apt-cache madison r-base-core | head
```

## Steps (calc03 from calc01)

1. **On calc01** (it runs 4.6.0), export the four packages:

   ```bash
   cd /home/ladmin/configServices/R-studioConf
   sudo bash scripts/fix_r_version_inplace.sh --export-debs /root/r-4.6.0-debs
   ```

   Each `.deb` comes from the apt cache, then the repository, then `dpkg-repack`
   (rebuilt from the installed files). If it fails with "no .deb", run
   `sudo apt-get install dpkg-repack` and try again. The directory gets a
   `SHA256SUMS` file.
2. **Copy** the directory to calc03, for example
   `sudo scp -r /root/r-4.6.0-debs ladmin@biome-calc03:/tmp/`, then on calc03
   `sudo mv /tmp/r-4.6.0-debs /root/`.
3. **On calc03, plan** (changes nothing):

   ```bash
   sudo bash scripts/fix_r_version_inplace.sh --debs /root/r-4.6.0-debs
   ```

   Check:
   - the four packages go from 4.5.3 to 4.6.0;
   - nothing is removed;
   - rollback is possible for every replaced package;
   - the user-library line: users whose personal packages exist only for R 4.5
     will reinstall them under 4.6. Tell them in advance.
4. **Apply** when nobody is working (the script refuses while an R session runs):

   ```bash
   sudo bash scripts/fix_r_version_inplace.sh --debs /root/r-4.6.0-debs --commit
   ```

   This takes a few minutes. It loads every installed R package before and
   after the upgrade, and restarts rstudio-server.
5. **Verify:**
   - `R --version | head -1` shows 4.6.0;
   - log in to RStudio on calc03;
   - `scripts/99_check_pkg_host_drift.sh` shows one R version across the hosts.

## Results and rollback

| Exit | Meaning |
|---|---|
| 0 | done (or dry-run, or nothing to do) |
| 3 | refused, host unchanged: read the message |
| 5 | R upgraded, but packages that loaded before do not load now: `regressions.txt` in the backup dir. Reinstall them, or roll back |
| 1 | failed: the message gives the rollback command |

```bash
sudo bash scripts/fix_r_version_inplace.sh --rollback /var/backups/biome-calc/r-version-<ts>
```

The rollback reinstalls the saved 4.5.3 `.deb` files and restarts rstudio-server.
The pin would bring 4.6.0 back on the next `apt upgrade`. To keep the rollback,
run `sudo apt-mark hold r-base r-base-core r-base-dev r-recommended` until the
cause is fixed.

Backup dir `/var/backups/biome-calc/r-version-<ts>/`:
- `before.tsv` and `after.tsv`: every `r-*` package;
- `plan.tsv`;
- `debs/`;
- `load_before.tsv`, `load_after.tsv` and `regressions.txt`.

After applying it, record the host and date in
[HOTFIX_REGISTER.md](HOTFIX_REGISTER.md).
