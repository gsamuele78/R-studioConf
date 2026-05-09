<!-- docs/operations/LUSSU_HANG_BISECTION.md -->
# Lussu Hang Bisection — HC-13 Worked Example

**Audience:** sysadmin / IT officer.
**Status:** worked example. Read `USER_SCRIPT_TROUBLESHOOTING.md` first.
**User script:** `plan/Test/test_Lussu/block1_aoh_to_rij.R` (DO NOT EDIT).

---

## Responsibility Boundaries (HC-13 — read first)

> *We adapt system → profile → fragments → env so that portable user R code
> keeps working. **We do not patch user scripts.** When the system has been
> exhausted and the failure persists, the clean-VM baseline (L4) proves
> whether the residual issue is in the user's code or upstream.*

The Lussu script is **portable R**. It uses `parallel::mclapply()`,
`terra::rast()`, `data.table`, and reads from NFS. Every `Sys.setenv()`
and `terraOptions()` line in the file is **commented out** — the author
left them as a hint. Per HC-13 we do **not** uncomment them; we land the
equivalent on the system side.

---

## The hang pattern (what the user reports)

> "The script starts, prints `chunk NNNNN START`, then nothing. After 30
> minutes I kill it. Top shows N R workers in `D` state. I have to
> `kill -9` them."

Surface diagnosis (before running the harness):

- **Parallel backend:** `mclapply` (fork). PSOCK is *not* in use, so this
  is **not** a socket-deadlock — that rules out half of the usual parallel
  bug catalog.
- **Per-worker work:** `terra::rast(file)` on **NFS** (`/nfs/home/...`),
  followed by `terra::project(method="near")` and `terra::values()`.
- **Hypothesis up front:** fork-inherited GDAL/terra state on NFS deadlocks
  when N forks open the same NFS-backed driver concurrently. Probe E
  (PSOCK swap) should make it pass; probe F (terra todisk) should reduce
  but not eliminate the hang.

---

## Step 1 — Run the overlay harness

```bash
# Run as the user, not root, so NFS perms match production
sudo -u gianfranco.samuele2 \
  /usr/local/bin/99_diagnose_lussu_hang.sh \
  /nfs/home/gianfranco.samuele2/test_Michele/.../block1_aoh_to_rij.R
```

Outputs land in `/tmp/lussu_diag_<ts>/`:

```
/tmp/lussu_diag_20260509_091500/
├── report.md                  # generic L0..L3 verdict
├── summary.tsv                # generic per-layer status
├── lussu_overlay.tsv          # E, F status
├── L0_infra_health.{log,err}
├── L1_pure_R_minimal.{log,err}
├── L2_all_fragments_off.{log,err}
├── L3_full_profile.{log,err}
├── probe_E_psock.{log,err}
├── probe_F_terra_todisk.{log,err}
└── shims/
    ├── probe_E_psock.R
    └── probe_F_terra_todisk.R
```

The shims `source(USER_SCRIPT, echo=FALSE)` — the user file is read but
**never written**. This is the HC-13-compliant way to test "what would
happen if mclapply were PSOCK?" without touching the script.

---

## Step 2 — Read the verdict line

The expected matrix for the Lussu pattern is:

| Layer / Probe | Expected | Meaning |
|---------------|----------|---------|
| L0 infra_health | PASS | NFS healthy, fork ok at small scale |
| L1 pure_R_minimal | **FAIL/TIMEOUT** | hang reproduces under pure R → not a profile issue |
| L2 all_fragments_off | **FAIL/TIMEOUT** | confirms fragments are blameless |
| L3 full_profile | **FAIL/TIMEOUT** | production reference |
| Probe E (PSOCK swap) | **PASS** | mclapply→PSOCK fixes it → fork+terra+NFS is the surface |
| Probe F (terra todisk) | partial PASS | reduces RAM pressure under fork but may still hang on the NFS-driver path |

Verdict line from the generic harness:

> `LAYERS L1+L3 BOTH FAILED: NOT a profile issue → infra+terra+NFS or user-script bug`

Combined with `Probe E PASS`, the diagnosis is **Surface 3 — Fork + NFS / terra**.

---

## Step 3 — Attach to a hung worker (evidence collection)

While L3 is hung, in another terminal:

```bash
# Find children
pgrep -f 'block1_aoh_to_rij.R' | xargs -I{} ps -o pid,ppid,stat,wchan:30,pcpu,rss,comm -p {}
# Typical bad output: STAT=Dl, wchan=rpc_wait_bit_killable
```

Then dump kernel state with the forensic helper:

```bash
PIDS=$(pgrep -f 'block1_aoh_to_rij.R' | tr '\n' ',' | sed 's/,$//')
r_minimal -e "biome_hang_diag(c($PIDS))" | tee /tmp/lussu_hang_$(date +%s).txt
```

Look for:

- `wchan: rpc_wait_bit_killable` → NFS-side wait.
- `stack: nfs_..._readpage` → terra read on NFS during fork-inherited state.
- `stack: __mutex_lock` inside `libgdal` → driver mutex held across fork.

Save this output. It is the kernel-stack evidence required by HC-13
before you can write *anything* user-facing about their code.

---

## Step 4 — Land the system-side fix

Per HC-13 the fix lands on the **system**, not in `block1_aoh_to_rij.R`.
Three options, in order of preference:

### Option A (preferred) — terra todisk default in fragment 50

Edit `templates/Rprofile_site.d/50_pkg_hooks.R.template` so that on
`library(terra)` we set:

```r
terra::terraOptions(todisk = TRUE,
                    memfrac = 0.2,
                    tempdir = Sys.getenv("BIOME_USER_TMP", "/Rtmp"))
```

This is invisible to the user (per `USER_CONTRACT.md`), survives across
fork (children inherit env + options), and addresses surface 3 by keeping
GDAL's heap-resident raster footprint small enough that fork+NFS does not
explode.

### Option B — NFS mount option tightening

In the host's `/etc/fstab` for `/nfs/home`:

- ensure `hard` (NOT `soft` — `soft` returns EIO under load and breaks
  long terra reads).
- ensure `actimeo` is **not** 0 (cache must be on for terra metadata).
- `rsize=1048576,wsize=1048576` (already in production).
- `nconnect=4` (already in production) — keep.

Validate with `biome_nfs_check()` after remount.

### Option C — documented PSOCK launcher (escape hatch)

If A+B do not fully resolve, ship a documented helper in
`SERVER_NATIVE_API.md`:

```r
biome_make_cluster(n)   # PSOCK, BLAS-capped, fork-free
```

— power-users opt in. The Lussu script keeps using `mclapply` and runs
fine because A+B reduced the per-fork memory + NFS contention enough.

**What we DO NOT do:**

- ❌ Edit `block1_aoh_to_rij.R` to swap `mclapply` for `parLapply`.
- ❌ Uncomment the `Sys.setenv(GDAL_NUM_THREADS=...)` block.
- ❌ Tell the user "your script is wrong, please rewrite parallelism".

---

## Step 5 — Verify and re-run

After landing the system-side fix:

```bash
# Re-deploy the fragment / mount option
sudo bash scripts/50_setup_nodes.sh   # menu option H or full deploy

# Re-run only the production-baseline layer
sudo -u gianfranco.samuele2 Rscript /path/to/block1_aoh_to_rij.R
```

Expected: chunk progress lines stream past, no `D`-state workers,
completion in expected wall time.

If still hung → escalate to L4 (`CLEAN_VM_BASELINE.md`).

---

## Step 6 — User-facing message (template)

> Hi Gianfranco,
>
> The hang you reported in `block1_aoh_to_rij.R` was caused by a
> system-level interaction between `terra`'s default in-RAM raster
> handling and our NFS home directory under `mclapply` fork. We have
> adapted the system: `terraOptions(todisk=TRUE, memfrac=0.2)` is now
> set automatically when you `library(terra)`. Your script is unchanged
> — please just re-run it.
>
> If the same script ever runs slower elsewhere (a laptop, another
> cluster), nothing in your code needs to change; the system there will
> simply use its own defaults. This is by design (HC-13 — adapt system,
> not user script).

---

## See also

- `docs/operations/USER_SCRIPT_TROUBLESHOOTING.md` — generic decision tree.
- `docs/operations/CLEAN_VM_BASELINE.md` — L4 reference VM SOP.
- `docs/architecture/USER_CONTRACT.md` — why we never edit user `.R`.
- `templates/Rprofile_site.d/50_pkg_hooks.R.template` — where the
  `terraOptions(todisk=TRUE)` default lives.
- `scripts/99_diagnose_lussu_hang.sh` — the harness this doc walks through.
