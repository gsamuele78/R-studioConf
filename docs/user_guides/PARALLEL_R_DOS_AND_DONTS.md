<!-- docs/user_guides/PARALLEL_R_DOS_AND_DONTS.md -->
# Parallel R — Do's and Don'ts on `biome-calc`

> **Audience:** botanists / researchers writing R scripts that will run
> on the shared `biome-calc` cluster (with cgroup-bounded RAM and CPU,
> NFS home directories, and PSOCK/parLapply parallelism).
> **Companion to:** `scripts/99_diagnose_user_script.sh` (lint layer
> L0a). Each section below is anchored from
> `scripts/lib/r_lint_rules.tsv :: doc_anchor`.

---

## Why this guide exists

The cluster is **not** the old 16 vCPU / 512 GB / 2 TB no-cgroup VM.
On `biome-calc`:

* You get a **slice** of cores and RAM enforced by Linux cgroups.
  `parallel::detectCores()` lies — it returns the host's 24 cores, but
  the kernel will only schedule your fraction.
* `$HOME` is **NFS**. Every per-iteration write goes over the network.
* `/Rtmp` is **400 GB local SSD ext4** — use it for scratch, not `/tmp`,
  not `~/`.
* PSOCK workers (the safe default on Linux for `terra`/`sf`/NIMBLE) start
  with an **empty `globalenv()`**. Functions and objects are NOT
  inherited the way `mclapply` (fork) inherits them.

The system harness `99_diagnose_user_script.sh` will, after proving the
infrastructure is green (L0..L3), lint your `.R` file against 22 rules
and quote the relevant section below. **The system never edits your
script — that's HC-13.** The fix lives in your code. This document is
how to apply it.

If a section starts with **HIGH**, you must fix it before re-running on
production data. **MED** = will bite under load. **LOW** = style /
portability.

---

## Rule index

| Rule | Severity | Title |
|---|---|---|
| [R001](#r001-makecluster-clusterexport) | HIGH | makeCluster without clusterExport |
| [R002](#r002-mclapply-terra) | MED  | mclapply forks over terra/sf objects |
| [R003](#r003-chunk-size) | MED  | suspiciously small chunk_size |
| [R004](#r004-progress) | LOW  | progress prints without throttling |
| [R005](#r005-setwd) | HIGH | setwd to a hardcoded absolute path |
| [R006](#r006-terra-values) | MED  | terra::values() inside a hot loop |
| [R007](#r007-install-packages) | HIGH | install.packages() at script top level |
| [R008](#r008-library-position) | LOW  | library() called after non-trivial code |
| [R009](#r009-rm-ls) | LOW  | rm(list = ls()) wipes globalenv |
| [R010](#r010-detectcores) | MED  | detectCores() ignores cgroup |
| [R011](#r011-cross-user) | HIGH | cross-user absolute path |
| [R012](#r012-compilenimble) | HIGH | compileNimble() crossing PSOCK |
| [R013](#r013-outfile-nfs) | MED  | cluster outfile on NFS |
| [R014](#r014-cross-user-write) | MED  | save/writeRaster to another user's dir |
| [R015](#r015-globalenv-closure) | MED  | globalenv name indexed inside a closure |
| [R016](#r016-relative-paths) | MED  | relative path in load/source/readRDS |
| [R017](#r017-makecluster-type) | MED  | makeCluster without explicit type= |
| [R019](#r019-silent-trycatch) | HIGH | silent tryCatch (empty error handler) |
| [R020](#r020-credentials) | HIGH | hardcoded credential |
| [R021](#r021-mac-only-path) | MED  | Mac-only path (`/Volumes/...`) |
| [R023](#r023-install-github) | HIGH | install_github() in script |
| [R025](#r025-unbounded-retry) | MED  | unbounded retry on network call |
| [R028](#r028-project-tempdir) | MED  | project-local `_temp/` cache dir |

Plus: [Good example](#good-example-martina_test2r) — a clean reference fixture.

---

## R001 — makeCluster + clusterExport

**Severity:** HIGH

PSOCK workers start with an **empty `globalenv()`**. A function defined
at the top of your script is invisible inside `parLapply(cl, x, FUN)`.
The classic Lussu symptom: `"could not find function process_chunk"`
repeated `n_chunks` times.

### ✗ Don't

```r
process_chunk <- function(i) { ... }

cl <- makeCluster(8)
res <- parLapply(cl, 1:N, process_chunk)   # workers do NOT see process_chunk
```

### ✓ Do

```r
process_chunk <- function(i) { ... }

cl <- parallel::makeCluster(8, type = "PSOCK")
parallel::clusterEvalQ(cl, { library(terra); library(data.table) })
parallel::clusterExport(
    cl,
    varlist = c("process_chunk", "presence_rule", "amount_mode"),
    envir   = environment()
)
res <- parallel::parLapply(cl, 1:N, process_chunk)
parallel::stopCluster(cl)
```

Or use `furrr` with auto-detected globals:

```r
library(future); library(furrr)
plan(multisession, workers = 8)
res <- future_map(1:N, process_chunk,
                  .options = furrr_options(globals = TRUE,
                                           packages = c("terra", "data.table")))
```

---

## R002 — mclapply over terra/sf

**Severity:** MED

`terra` and `sf` carry C++/GDAL handles. `mclapply()` uses `fork()`,
which duplicates those handles **by reference**. The first child to
free a handle corrupts the others. Symptom: random SIGSEGV, NFS
deadlock, or "stale GDAL handle" under load.

### ✗ Don't

```r
parallel::mclapply(rast_paths, function(p) {
    r <- terra::rast(p)
    terra::global(r, "mean", na.rm = TRUE)
}, mc.cores = 8)
```

### ✓ Do

Use a **PSOCK** cluster and ship the **paths** (strings), not the
opened raster objects:

```r
cl <- parallel::makeCluster(8, type = "PSOCK")
parallel::clusterEvalQ(cl, library(terra))
res <- parallel::parLapply(cl, rast_paths, function(p) {
    r <- terra::rast(p)
    terra::global(r, "mean", na.rm = TRUE)
})
parallel::stopCluster(cl)
```

---

## R003 — chunk_size

**Severity:** MED

`chunk_size <= 10` means scheduler overhead dominates real work, and
you accumulate 10 000+ partial-result files on `/Rtmp`. Lussu's 4103
chunks at chunk_size = 1 produced 16k files in one run.

### ✓ Do

```r
chunk_size <- 200   # profile with proc.time() per chunk; 50..500 is typical
```

---

## R004 — progress prints

**Severity:** LOW

Per-iteration `cat()` to stderr floods the log under load and stalls
NFS log writes.

### ✗ Don't

```r
for (i in seq_along(chunks)) {
    cat("processing", i, "\n")   # 4103 lines/min
    ...
}
```

### ✓ Do

```r
if (i %% 100 == 0) message(sprintf("[%s] %d / %d", Sys.time(), i, N))
```

---

## R005 — setwd to absolute path

**Severity:** HIGH

`setwd("/Users/foo/bar")` or `setwd("/home/old_user/...")` is a portability
bomb. The path may not exist on this server. The "old VM" had it; this
one does not.

### ✓ Do

```r
# Pass the workdir as an argument:
args <- commandArgs(trailingOnly = TRUE)
work_dir <- args[1] %||% Sys.getenv("BIOME_DATA_DIR", ".")

# Or use here::here() (auto-detects project root via .here / .Rproj):
library(here)
data_path <- here("data", "input.rds")
```

Never `setwd()` inside a function or inside a parallel worker.

---

## R006 — terra::values() in hot loops

**Severity:** MED

`terra::values()` materializes the **entire raster** into RAM. Calling
it per-iteration in a `for`/`lapply` loop is the #1 cause of `mclapply`
OOM under cgroup MemoryMax. With a 12 GB raster and 8 workers, you
need 96 GB RAM you don't have.

### ✗ Don't

```r
for (p in rast_paths) {
    v <- terra::values(terra::rast(p))   # 12 GB each
    summary(v)
}
```

### ✓ Do

```r
# Extract only what you need (point sample):
pts <- terra::vect(coords, type = "points", crs = "EPSG:4326")
vals <- terra::extract(terra::rast(p), pts)

# Or windowed reduction without materialization:
mean_r <- terra::app(terra::rast(p), fun = mean, na.rm = TRUE)
```

---

## R007 — install.packages() in script

**Severity:** HIGH

`install.packages()` at script top level:

* Makes a network call mid-batch (slow, fragile).
* Will silently fail on biome-calc nodes — `/usr/lib/R` is read-only
  for non-root users.
* Breaks reproducibility (different CRAN snapshot per run).

### ✓ Do

Ask the sysadmin to add the package to
`config/r_env_manager.conf :: R_USER_PACKAGES_CRAN`. The next deploy
will pin it cluster-wide. In your script:

```r
suppressPackageStartupMessages({
    library(terra)
    library(data.table)
})
```

---

## R008 — library() position

**Severity:** LOW

`library()` should be at the **top** of the file. If you put it after
30 minutes of preprocessing and the package is missing, you have wasted
30 minutes.

### ✓ Do

```r
suppressPackageStartupMessages({
    library(terra)
    library(sf)
    library(nimble)
    library(data.table)
})

# ... rest of the script ...
```

---

## R009 — rm(list = ls())

**Severity:** LOW

Hides bugs (every interactive run starts from a "clean" state different
from the batch run) and can delete objects another sourced script just
defined.

### ✓ Do

* Start a **fresh R session** (RStudio: Session → Restart R).
* Or list specific objects: `rm(big_raster, working_df)`.

---

## R010 — detectCores()

**Severity:** MED

`parallel::detectCores()` returns the **host's** physical core count
(24 on biome-calc), ignoring the cgroup cpuset that limits you to a
slice (typically 4–8). Spawning 24 workers when you have 4 cores → 6×
oversubscription, thrashing, and OOM.

### ✓ Do

```r
n_workers <- min(
    parallel::detectCores(logical = FALSE) - 1,
    as.integer(Sys.getenv("BIOME_USER_CORES", "4"))
)
cl <- parallel::makeCluster(n_workers, type = "PSOCK")
```

`BIOME_USER_CORES` is set by the system per session.

---

## R011 — cross-user absolute path

**Severity:** HIGH

```r
read.csv("/nfs/home/some_other_user/data.csv")
```

Either you don't have permission (script fails late, after expensive
setup) or — worse — you do have permission and you silently corrupt
someone else's data when writing.

### ✓ Do

* Shared inputs go under `/media/r_projects/<project>/`. Ask the
  sysadmin to grant ACL.
* Or copy what you need into your own `~/`.

---

## R012 — compileNimble() crossing PSOCK

**Severity:** HIGH

Compiled NIMBLE C++ objects **cannot** be serialized across a PSOCK
socket. If you compile on the master and `parLapply()` workers receive
the compiled object, they will hang forever or crash with
`"external pointer is not valid"`.

### ✓ Do — option A: stay single-threaded

```r
mcmc <- nimbleMCMC(code = nimble_code, data = data_list,
                   inits = init_list, niter = 5000, nburnin = 1000)
```

### ✓ Do — option B: compile inside the worker

```r
worker_fn <- function(seed, code, data_list, inits, niter, nburn) {
    library(nimble)
    set.seed(seed)
    mod  <- nimbleModel(code = code, data = data_list, inits = inits)
    cmod <- compileNimble(mod)
    mcmc <- buildMCMC(cmod)
    cmcmc <- compileNimble(mcmc, project = mod)
    runMCMC(cmcmc, niter = niter, nburnin = nburn)
}
res <- parallel::parLapply(cl, seeds, worker_fn,
                           code = nimble_code, data_list = data_mod,
                           inits = init_list, niter = 5000, nburn = 1000)
```

Compile **inside** the worker. Never ship the compiled object across
the cluster.

---

## R013 — outfile on NFS

**Severity:** MED

```r
makeCluster(8, outfile = "cluster.log")    # ← resolves under getwd() = NFS
```

PSOCK worker logs hammered onto NFS deadlock the cluster under load.

### ✓ Do

```r
cluster_log <- file.path(
    Sys.getenv("BIOME_USER_TMP", "/Rtmp"),
    Sys.getenv("USER", "u"),
    "cluster.log"
)
dir.create(dirname(cluster_log), showWarnings = FALSE, recursive = TRUE)
cl <- parallel::makeCluster(8, type = "PSOCK", outfile = cluster_log)
```

---

## R014 — cross-user write

**Severity:** MED

Same as [R011](#r011-cross-user) but for writes:

```r
saveRDS(result, "/home/another_user/results.rds")    # PERMISSION DENIED
writeRaster(r, "/media/old_user/r_out.tif")          # silent ACL failure
```

Production nodes enforce strict ACLs. The script will fail late.

### ✓ Do

Write to your own `~/` or to a project-shared dir under
`/media/r_projects/<project>/`.

---

## R015 — globalenv name indexed inside a closure

**Severity:** MED

```r
worker_fn <- function(seed) {
    inits <- init_list[[seed]]    # ← init_list resolved at call time
    constants <- constants[["X"]]  # ← same problem
    runMCMC(...)
}
parLapply(cl, 1:K, worker_fn)
```

Inside a PSOCK worker, `init_list` and `constants` are not in the
worker's globalenv unless you `clusterExport` them. The worker errors
with `object 'init_list' not found`.

### ✓ Do

Pass dependencies as **explicit arguments**:

```r
worker_fn <- function(seed, init_list, constants) {
    runMCMC(..., inits = init_list[[seed]], constants = constants)
}
parLapply(cl, 1:K, worker_fn,
          init_list = init_list, constants = constants)
```

---

## R016 — relative paths in load/source/readRDS

**Severity:** MED

```r
load("Data_for_spGDMM.RData")   # resolves vs. getwd()
source("helpers.R")
readRDS("model.rds")
```

The harness changes `getwd()` between layers; a fragment loads on your
laptop and breaks at L1.

### ✓ Do

```r
data_dir <- Sys.getenv("BIOME_DATA_DIR", ".")
load(file.path(data_dir, "Data_for_spGDMM.RData"))

# Or:
library(here)
source(here("R", "helpers.R"))
```

---

## R017 — makeCluster without explicit type=

**Severity:** MED

```r
cl <- makeCluster(8)        # Linux default = FORK; Windows = PSOCK
```

FORK + `terra`/`sf`/NIMBLE = silent corruption (see [R002](#r002-mclapply-terra)).
Always be explicit.

### ✓ Do

```r
cl <- parallel::makeCluster(8, type = "PSOCK")
# Or use the system helper from /etc/R/Rprofile_site.d/30_psock_factory.R:
cl <- .biome_make_cluster(8)
```

---

## R019 — silent tryCatch

**Severity:** HIGH

```r
res <- tryCatch(expensive_call(), error = function(e) NULL)
res <- tryCatch(expensive_call(), error = function(e) { })   # empty body
```

Swallowing every error makes the script appear to "work" while
producing wrong/empty output. The botanist downstream sees missing
chains and blames the cluster.

### ✓ Do

At minimum, log the error:

```r
res <- tryCatch(
    expensive_call(),
    error = function(e) {
        message(sprintf("[ERROR @ %s] %s", Sys.time(), conditionMessage(e)))
        NA   # or a sentinel the caller can check
    }
)
```

---

## R020 — hardcoded credential

**Severity:** HIGH — **SECURITY**

```r
gbif_pwd <- "MyPassw0rd!"
api_key  <- "sk-AbCdE..."
```

A plaintext password committed to NFS or git is a confidentiality
breach. The harness's **L0a SECURITY banner** fires on this rule.

### ✓ Do

```r
gbif_pwd <- Sys.getenv("GBIF_PWD")
if (!nzchar(gbif_pwd)) stop("GBIF_PWD not set in ~/.Renviron")
```

Then in `~/.Renviron` (chmod 600):

```
GBIF_PWD=...
```

If you have already committed or shared a credential, **ask the
sysadmin to rotate it**. The leaked one is gone.

---

## R021 — Mac-only path (`/Volumes/...`)

**Severity:** MED

```r
data_dir <- "/Volumes/MyExternalHDD/SDM_data"
```

This path only exists on the macOS author's machine. Linux server →
first read fails.

### ✓ Do

Move data under `~/` or `/media/r_projects/<project>/` and use
relative paths or `here::here()`.

---

## R023 — install_github() in script

**Severity:** HIGH

```r
devtools::install_github("someuser/somerepo")
remotes::install_github("...")
pak::pkg_install("github::...")
```

Worse than [R007](#r007-install-packages):

* Arbitrary code from a third-party Git ref runs on every batch start.
* Supply-chain risk.
* Network failure stalls compute.
* The Git ref may move between runs (non-reproducible).

### ✓ Do

Ask the sysadmin to add the package to
`config/r_env_manager.conf :: R_USER_PACKAGES_GITHUB`. They'll pin it to
a specific commit SHA.

---

## R025 — unbounded retry

**Severity:** MED

```r
osm_data <- NULL
while (is.null(osm_data)) {
    osm_data <- try(opq("Italy") |> osmdata_sf(), silent = TRUE)
}
```

If the OSM/GBIF server is permanently down, this spins forever, holds
NFS handles, and never times out — your batch quietly burns its
wall-time budget.

### ✓ Do

Bounded retry with exponential backoff:

```r
osm_data <- NULL
for (i in 1:5) {
    osm_data <- tryCatch(
        opq("Italy") |> osmdata_sf(),
        error = function(e) { message("attempt ", i, ": ", conditionMessage(e)); NULL }
    )
    if (!is.null(osm_data)) break
    Sys.sleep(2^i)   # 2, 4, 8, 16, 32 seconds
}
if (is.null(osm_data)) stop("OSM unreachable after 5 attempts")
```

---

## R028 — project-local `_temp/` cache

**Severity:** MED

```r
saveRDS(intermediate, "_temp/chunk_001.rds")
writeRaster(r, "./tmp/r.tif")
write_csv(df, "cache/output.csv")
```

This puts intermediate cache **on NFS**, hammers the metadata server,
and is never cleaned. The 20 000-raster Lussu run produced 4 GB of
`_temp/` cruft over a weekend.

### ✓ Do

```r
cache_dir <- file.path(
    Sys.getenv("BIOME_USER_TMP", "/Rtmp"),
    Sys.getenv("USER", "u"),
    "cache"
)
dir.create(cache_dir, showWarnings = FALSE, recursive = TRUE)
saveRDS(intermediate, file.path(cache_dir, "chunk_001.rds"))
```

`/Rtmp` is local SSD ext4 (400 GB), wiped on reboot. Perfect for
intermediate cache. **Not** `/tmp` (small tmpfs, will fill).

---

## Good example — `martina_test2.R`

This fixture (under `tests/fixtures/r_lint/martina_test2.R`) is the
**canonical clean reference** — it produces zero lint findings.

```r
library(nimble)

# 1. Local SSD scratch dir (NOT /tmp, NOT NFS, NOT project-local _temp)
chunk_dir <- file.path(
    Sys.getenv("BIOME_USER_TMP", "/Rtmp"),
    Sys.getenv("USER", "biome_user"),
    "mcmc_chunks"
)
dir.create(chunk_dir, showWarnings = FALSE, recursive = TRUE)

# 2. Smoke knob — small workload when harness sets BIOME_DIAG_SMOKE=1
n_chunks    <- as.integer(Sys.getenv("BIOME_SMOKE_N_CHUNKS",  "10"))
chunk_iters <- as.integer(Sys.getenv("BIOME_SMOKE_CHUNK_SIZE", "300"))

# 3. Compile in master only — never serialize across PSOCK
chunk_files <- character(n_chunks)
for (i in seq_len(n_chunks)) {
    gc(verbose = FALSE)
    samples <- rnorm(chunk_iters)              # placeholder for runMCMC(...)
    chunk_files[i] <- file.path(chunk_dir, sprintf("chunk_%03d.rds", i))
    saveRDS(samples, chunk_files[i])
    rm(samples)
}

# 4. Merge from disk and clean up scratch
merged <- do.call(c, lapply(chunk_files, readRDS))
unlink(chunk_files)

cat(sprintf("Done: %d samples merged, scratch cleaned\n", length(merged)))
```

**What makes it good:**

* Uses `BIOME_USER_TMP`/`/Rtmp` (R028 ✓), not `/tmp` or `_temp/`.
* Uses `BIOME_SMOKE_*` env knobs so the harness's `--smoke` layer (L0b)
  can shrink the workload without editing the file (HC-13 ✓).
* `gc()` per chunk → bounded RSS.
* `saveRDS` + `unlink` → no scratch accumulation.
* Single-threaded — so no PSOCK/clusterExport pitfalls (R001/R012/R015 ✓).
* No `setwd()` (R005 ✓), no cross-user paths (R011/R014 ✓), no relative
  paths (R016 ✓), no hardcoded credentials (R020 ✓).

If your script doesn't need parallelism, **don't add it.** Single-threaded
chunked I/O with `gc()` per chunk is often faster than 8 fork/PSOCK
workers fighting over `/Rtmp` and the cgroup memory limit.

---

## When you're stuck

1. Run the diagnostic: `bash scripts/99_diagnose_user_script.sh --user $USER /path/to/your.R`
2. Open `/tmp/user_script_diag_<user>_<TS>/report.md` — the lint
   findings reference rule IDs (R001..R028) that anchor back to this
   document.
3. Re-run with `--smoke` to actually execute a shrunk version (you'll
   need `BIOME_SMOKE_*` env knobs in your script — see the good
   example above).
4. If exit code is `4`, the infrastructure is green and the fix is in
   your script. The `report.md` `old_vs_new` appendix shows your real
   cgroup limits vs. the legacy VM — useful evidence when the chat
   thread starts with "ma sul vecchio server funzionava".

The system never edits your `.R` (HC-13). You always have full control
over what changes and when.
