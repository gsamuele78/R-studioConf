<!-- docs/user_guides/PARALLEL_R_DOS_AND_DONTS.md -->
# Safe Parallel R on BIOME-CALC — Do's and Don'ts

> **Audience:** botanists / researchers writing R scripts that run on the
> shared BIOME-CALC platform.
> **Last verified:** 2026-06-08
> **Rprofile version:** 12.10

---

## Why this guide exists

BIOME-CALC is a shared research platform with resource limits enforced by
the operating system. Your R session runs inside a **cgroup slice** that
bounds your CPU and RAM. The platform also provides transparent guards
that make standard R functions safer, but you still need to follow a few
rules to keep your code portable and efficient.

Key facts about the platform:

- **`/Rtmp`** is a 400 GB local SSD disk for temporary files. Use it for
  scratch data, not your home directory and not `/tmp`.
- **Your home directory is on NFS** (network storage). Frequent small
  writes over NFS are slow. Route temporary I/O to `/Rtmp`.
- **`parallel::detectCores()` is cgroup-aware** on BIOME-CALC. It returns
  the number of cores allocated to your session, not the full host count.
- **`parallel::mclapply()` is guarded.** When you have loaded packages
  that are unsafe to fork (terra, sf, raster), the platform automatically
  reroutes to a safer PSOCK cluster.
- **`nimble::compileNimble()` is wrapped** to route compilation scratch
  to `/Rtmp` automatically.
- **Package installation inside scripts is blocked** by default. Ask the
  sysadmin to add packages to the platform configuration.

The platform **never edits your R scripts** (that is a hard rule, HC-13).
The fixes described here are changes you make in your own code.

---

## Quick reference: Do / Don't

| Situation | ✗ Don't | ✓ Do |
|---|---|---|
| Parallel workers | `makeCluster(8)` without `type=` | `parallel::makeCluster(n, type = "PSOCK")` |
| Fork-based parallel with spatial packages | `mclapply(..., mc.cores = 8)` after `library(terra)` | Use PSOCK cluster or let the platform auto-reroute |
| Scratch / temp files | `saveRDS(x, "/tmp/myfile.rds")` | `saveRDS(x, file.path(Sys.getenv("BIOME_USER_TMP"), "myfile.rds"))` |
| Working directory | `setwd("/home/olduser/project")` | Use `here::here()` or pass paths as arguments |
| Package installation | `install.packages("pkg")` inside a script | Ask sysadmin to add to `config/r_env_manager.conf` |
| GitHub package install | `devtools::install_github("user/repo")` | Ask sysadmin; they pin a specific commit |
| Core count | `parallel::detectCores()` without `logical = FALSE` | `max(1L, parallel::detectCores(logical = FALSE) - 1L)` |
| NIMBLE across workers | Compile on master, send compiled object to workers | Compile inside each worker |
| Hardcoded credentials | `api_key <- "sk-1234abcd"` | `Sys.getenv("MY_API_KEY")` with `~/.Renviron` |
| Silent error handling | `tryCatch(work(), error = function(e) NULL)` | Log the error: `message(conditionMessage(e))` |

---

## Detailed rules

### R001 — Use explicit PSOCK clusters

PSOCK workers start with an empty workspace. Functions and objects
defined in your main script are not visible inside `parLapply()` unless
you export them.

**✗ Don't:**

```r
process_chunk <- function(i) { mean(rnorm(1000)) }
cl <- makeCluster(8)
res <- parLapply(cl, 1:100, process_chunk)   # workers don't see process_chunk
```

**✓ Do:**

```r
process_chunk <- function(i) { mean(rnorm(1000)) }
cl <- parallel::makeCluster(8, type = "PSOCK")
parallel::clusterExport(cl, varlist = "process_chunk", envir = environment())
res <- parallel::parLapply(cl, 1:100, process_chunk)
parallel::stopCluster(cl)
```

---

### R002 — Avoid forking with spatial packages

Packages like `terra`, `sf`, and `raster` use C++ objects that cannot be
safely duplicated by `fork()`. On BIOME-CALC the platform automatically
reroutes `mclapply()` to PSOCK when these packages are loaded, but it is
still better practice to use PSOCK explicitly.

**✗ Don't:**

```r
library(terra)
results <- parallel::mclapply(rast_paths, function(p) {
    r <- terra::rast(p)
    terra::global(r, "mean", na.rm = TRUE)
}, mc.cores = 8)
```

**✓ Do:**

```r
library(terra)
cl <- parallel::makeCluster(8, type = "PSOCK")
parallel::clusterEvalQ(cl, library(terra))
results <- parallel::parLapply(cl, rast_paths, function(p) {
    r <- terra::rast(p)
    terra::global(r, "mean", na.rm = TRUE)
})
parallel::stopCluster(cl)
```

---

### R003 — Choose a reasonable chunk size

If you split work into chunks, avoid tiny chunks (≤ 10 iterations).
Scheduler overhead dominates and you create thousands of temporary files.

**✓ Do:**

```r
chunk_size <- 200   # 50–500 is typical; profile with proc.time()
```

---

### R004 — Throttle progress messages

Printing a message for every iteration floods the log and slows down
NFS writes.

**✗ Don't:**

```r
for (i in seq_along(chunks)) {
    cat("processing", i, "\n")
}
```

**✓ Do:**

```r
if (i %% 100 == 0) message(sprintf("[%s] %d / %d", Sys.time(), i, N))
```

---

### R005 — Do not use `setwd()` with hardcoded paths

`setwd("/home/olduser/project")` breaks when the script runs on a
different machine or by a different user.

**✓ Do:**

```r
# Pass the work directory as a command-line argument:
args <- commandArgs(trailingOnly = TRUE)
work_dir <- args[1]

# Or use here::here() to auto-detect the project root:
library(here)
data_path <- here("data", "input.csv")
```

Never call `setwd()` inside a parallel worker.

---

### R006 — Avoid `terra::values()` in hot loops

`terra::values()` reads an entire raster into RAM. Calling it inside a
loop with many workers can exhaust memory.

**✗ Don't:**

```r
for (p in rast_paths) {
    v <- terra::values(terra::rast(p))   # 12 GB each
    summary(v)
}
```

**✓ Do:**

```r
# Extract only what you need:
pts <- terra::vect(coords, type = "points", crs = "EPSG:4326")
vals <- terra::extract(terra::rast(p), pts)

# Or use windowed reduction:
mean_r <- terra::app(terra::rast(p), fun = mean, na.rm = TRUE)
```

---

### R007 — Do not install packages inside scripts

`install.packages()` inside a script causes network calls mid-batch,
breaks reproducibility, and may fail with permission errors on the
shared platform.

**✓ Do:**

Ask the sysadmin to add the package to the platform configuration
(`config/r_env_manager.conf`). The package will be installed cluster-wide
at the next deployment.

In your script, simply load the package:

```r
library(terra)
library(data.table)
```

---

### R008 — Put `library()` calls at the top

If a package is missing, you want to know immediately, not after
30 minutes of computation.

**✓ Do:**

```r
library(terra)
library(sf)
library(data.table)

# ... rest of the script ...
```

---

### R009 — Avoid `rm(list = ls())`

This hides bugs by making interactive runs different from batch runs.

**✓ Do:**

- Start a fresh R session (Session → Restart R in RStudio).
- Or remove specific objects: `rm(big_raster, temp_df)`.

---

### R010 — Use `detectCores(logical = FALSE)`

On BIOME-CALC, `parallel::detectCores()` is wrapped to return your
cgroup-effective core count. Use `logical = FALSE` for physical cores:

```r
n_workers <- max(1L, parallel::detectCores(logical = FALSE) - 1L)
cl <- parallel::makeCluster(n_workers, type = "PSOCK")
```

This is portable: on your laptop it returns the honest physical core
count; on BIOME-CALC it returns your allocated slice.

---

### R011 — Do not use hardcoded paths to other users' directories

```r
read.csv("/home/otheruser/data.csv")   # permission denied or worse
```

**✓ Do:**

- Shared inputs go under `/media/r_projects/<project>/`.
- Or copy what you need into your own home directory.

---

### R012 — Compile NIMBLE inside each worker

Compiled NIMBLE objects cannot be sent across a PSOCK socket. Compile
inside the worker, not on the master.

**✓ Do — compile inside the worker:**

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

---

### R013 — Keep cluster logs off NFS

PSOCK worker logs written to NFS can deadlock under load.

**✓ Do:**

```r
cluster_log <- file.path(
    Sys.getenv("BIOME_USER_TMP", "/Rtmp"),
    "cluster.log"
)
cl <- parallel::makeCluster(8, type = "PSOCK", outfile = cluster_log)
```

---

### R014 — Write only to your own directories

```r
saveRDS(result, "/home/otheruser/results.rds")   # permission denied
```

**✓ Do:**

Write to your own home directory or to a shared project directory under
`/media/r_projects/<project>/`.

---

### R015 — Pass dependencies as explicit arguments to workers

Variables from your main session are not visible inside PSOCK workers
unless you export them.

**✗ Don't:**

```r
worker_fn <- function(seed) {
    inits <- init_list[[seed]]    # init_list not found in worker
    runMCMC(...)
}
parLapply(cl, 1:K, worker_fn)
```

**✓ Do:**

```r
worker_fn <- function(seed, init_list) {
    runMCMC(..., inits = init_list[[seed]])
}
parLapply(cl, 1:K, worker_fn, init_list = init_list)
```

---

### R016 — Avoid relative paths in `load()`, `source()`, `readRDS()`

Relative paths depend on the current working directory, which can change.

**✓ Do:**

```r
data_dir <- Sys.getenv("BIOME_DATA_DIR", ".")
load(file.path(data_dir, "workspace.RData"))

# Or use here::here():
library(here)
source(here("R", "helpers.R"))
```

---

### R017 — Always specify `type = "PSOCK"` in `makeCluster()`

The default type on Linux is `"FORK"`, which is unsafe with spatial
packages.

**✓ Do:**

```r
cl <- parallel::makeCluster(8, type = "PSOCK")
```

---

### R019 — Do not silently swallow errors

An empty error handler makes failures invisible.

**✗ Don't:**

```r
res <- tryCatch(expensive_call(), error = function(e) NULL)
```

**✓ Do:**

```r
res <- tryCatch(
    expensive_call(),
    error = function(e) {
        message(sprintf("[ERROR @ %s] %s", Sys.time(), conditionMessage(e)))
        NA
    }
)
```

---

### R020 — Never hardcode credentials

```r
api_key <- "sk-1234abcd"   # visible in git, NFS, logs
```

**✓ Do:**

```r
api_key <- Sys.getenv("MY_API_KEY")
if (!nzchar(api_key)) stop("MY_API_KEY not set in ~/.Renviron")
```

Store the value in `~/.Renviron` (with permissions `600`):

```
MY_API_KEY=sk-1234abcd
```

---

### R021 — Avoid Mac-only paths

```r
data_dir <- "/Volumes/ExternalDrive/data"   # only exists on macOS
```

**✓ Do:**

Move data to your home directory or a shared project directory, and use
relative paths or `here::here()`.

---

### R023 — Do not install from GitHub inside scripts

`devtools::install_github()` runs arbitrary code from a Git repository
and breaks reproducibility.

**✓ Do:**

Ask the sysadmin to add the package to `config/r_env_manager.conf` with
a pinned commit SHA.

---

### R025 — Bound your retries

An infinite retry loop on a network call can burn your entire wall-time
budget.

**✓ Do:**

```r
for (i in 1:5) {
    result <- tryCatch(
        fetch_data(),
        error = function(e) { message("attempt ", i, ": ", conditionMessage(e)); NULL }
    )
    if (!is.null(result)) break
    Sys.sleep(2^i)
}
```

---

### R028 — Do not use project-local cache directories on NFS

```r
saveRDS(intermediate, "_temp/chunk_001.rds")   # writes to NFS
```

**✓ Do:**

```r
cache_dir <- file.path(Sys.getenv("BIOME_USER_TMP", "/Rtmp"), "cache")
dir.create(cache_dir, showWarnings = FALSE, recursive = TRUE)
saveRDS(intermediate, file.path(cache_dir, "chunk_001.rds"))
```

`/Rtmp` is local SSD storage, wiped on reboot — ideal for intermediate
results.

---

### R029 — Direct temporary files to `/Rtmp`, not `/tmp` or NFS

`/tmp` is a small RAM-based filesystem that fills quickly. NFS is slow
for frequent temporary I/O.

**✓ Do:**

```r
# For terra:
terra::terraOptions(
    tempdir = file.path(Sys.getenv("BIOME_USER_TMP", "/Rtmp"), "terra_temp")
)

# For R's tempfile():
my_temp <- file.path(Sys.getenv("BIOME_USER_TMP", "/Rtmp"), "my_temp_file.rds")
saveRDS(data, my_temp)
```

---

## Good example — single-threaded chunked processing

This pattern produces clean, portable code that works well on BIOME-CALC:

```r
library(nimble)

# 1. Use local SSD scratch (not /tmp, not NFS)
chunk_dir <- file.path(
    Sys.getenv("BIOME_USER_TMP", "/Rtmp"),
    "mcmc_chunks"
)
dir.create(chunk_dir, showWarnings = FALSE, recursive = TRUE)

# 2. Support smoke testing (small workload for quick validation)
n_chunks    <- as.integer(Sys.getenv("BIOME_SMOKE_N_CHUNKS",  "10"))
chunk_iters <- as.integer(Sys.getenv("BIOME_SMOKE_CHUNK_SIZE", "300"))

# 3. Process in chunks, writing to local disk
chunk_files <- character(n_chunks)
for (i in seq_len(n_chunks)) {
    gc(verbose = FALSE)
    samples <- rnorm(chunk_iters)              # replace with runMCMC(...)
    chunk_files[i] <- file.path(chunk_dir, sprintf("chunk_%03d.rds", i))
    saveRDS(samples, chunk_files[i])
    rm(samples)
}

# 4. Merge from disk and clean up
merged <- do.call(c, lapply(chunk_files, readRDS))
unlink(chunk_files)

cat(sprintf("Done: %d samples merged, scratch cleaned\n", length(merged)))
```

**Why this is good:**

- Uses `/Rtmp` for scratch, not `/tmp` or NFS.
- `gc()` per chunk keeps memory usage bounded.
- `saveRDS` + `unlink` prevents scratch accumulation.
- Single-threaded — no PSOCK/clusterExport pitfalls.
- No `setwd()`, no hardcoded paths, no credentials.
- Supports `BIOME_SMOKE_*` environment variables for quick testing.

If your script does not need parallelism, **do not add it.**
Single-threaded chunked I/O with `gc()` per chunk is often faster than
multiple workers competing for memory and disk.

---

## When you need help

1. Check this guide first — most common issues are covered above.
2. If your script hangs or crashes, contact the sysadmin. They can run
   diagnostics that identify whether the problem is in the platform
   configuration or in your code.
3. The platform **never edits your R scripts**. You always control what
   changes and when.

---

*Authoritative source: [`docs/user_guides/PARALLEL_R_DOS_AND_DONTS.md`](https://github.com/gsamuele78/R-studioConf/blob/main/docs/user_guides/PARALLEL_R_DOS_AND_DONTS.md) — last verified 2026-06-08.*
