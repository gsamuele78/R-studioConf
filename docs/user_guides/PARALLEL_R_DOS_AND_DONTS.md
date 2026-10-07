---
title: "Safe Parallel R — Do's and Don'ts"
audience: researcher
status: current
source_path: docs/user_guides/PARALLEL_R_DOS_AND_DONTS.md
last_verified: 2026-10-07
sharepoint_section: Researcher Hub
---
<!-- docs/user_guides/PARALLEL_R_DOS_AND_DONTS.md -->
# Safe Parallel R on BIOME-CALC — Do's and Don'ts

> For researchers writing R scripts that run on the shared BIOME-CALC
> server. The rule numbers (R001, R002, ...) are the same codes the admins
> use when they send you a review of a script.

---

## Why this guide exists

BIOME-CALC is shared: each user gets a fair share of the processors and
memory. The server already makes standard R safer, but a few habits keep
your code fast, portable and safe for everyone.

What to know about the server:

- **`tempdir()` / `tempfile()`** point to `/Rtmp`, a fast 400 GB local disk.
  Use them for scratch files, not your home folder and not `/tmp`.
- **Your home folder is network storage.** Writing many small files there is
  slow.
- **`parallel::detectCores()`** returns your share of the processors, not
  the total of the machine.
- **`parallel::mclapply()` is protected.** When terra, sf or raster are
  loaded, the server switches it to a safe cluster automatically.
- **`nimble::compileNimble()`** compiles on the fast scratch disk
  automatically.
- **Packages** install into your personal library with `install.packages()`.
  If you ever see "install.packages() is disabled on this cluster", follow
  the message and send the package name to the admins.

The admins never edit your scripts. The changes below are ones you make in
your own code, and they work the same on your laptop.

---

## Quick reference: Do / Don't

| Situation | ✗ Don't | ✓ Do |
|---|---|---|
| Parallel workers | `makeCluster(8)` without `type=` | `parallel::makeCluster(n, type = "PSOCK")` |
| Fork-based parallel with spatial packages | `mclapply(..., mc.cores = 8)` after `library(terra)` | Use PSOCK cluster or let the platform auto-reroute |
| Scratch / temp files | `saveRDS(x, "/tmp/myfile.rds")` | `saveRDS(x, file.path(tempdir(), "myfile.rds"))` |
| Working directory | `setwd("/home/olduser/project")` | Use `here::here()` or pass paths as arguments |
| Package installation | `install.packages("pkg", lib = "/usr/lib/R/site-library")` | `install.packages("pkg")` (default per-user library) |
| GitHub package install | `devtools::install_github("user/repo")` inside a script | Install once, record versions with `renv` |
| Core count | `makeCluster(64)` (fixed number) | `max(1L, parallel::detectCores() - 1L)` |
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

Printing a message for every iteration floods the log and slows the job
down.

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

### R007 — Install packages into your own library, not the system one

`install.packages()` works on BIOME-CALC and installs into your per-user
library on local disk (`/var/lib/biome-Rlibs/<you>/<R-version>/`). What
fails is trying to write into the read-only system library.

**✗ Don't:**

```r
install.packages("foo", lib = "/usr/lib/R/site-library")   # read-only, fails
```

**✓ Do:**

```r
install.packages("foo")     # per-user library (the default)
# or faster, Ubuntu binary, no compile:
bspm::install_sys("foo")
```

Put `install.packages()` in a separate setup script, not in the analysis
script that you run many times. If the whole team needs a package, ask the
admins to install it for everyone. If you ever see "install.packages() is
disabled on this cluster", installation is temporarily centralised: send
the package name to the admins.

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

### R010 — Size clusters from `detectCores()`, never a fixed number

On BIOME-CALC `parallel::detectCores()` returns your share of the
processors. Leave one for the main session:

```r
n_workers <- max(1L, parallel::detectCores() - 1L)
cl <- parallel::makeCluster(n_workers, type = "PSOCK")
```

This is portable: on your laptop it returns the laptop's cores.

---

### R011 — Do not use hardcoded paths to other users' directories

```r
read.csv("/home/otheruser/data.csv")   # permission denied or worse
```

**✓ Do:**

- Shared inputs go in the project share, `/mnt/ProjectStorage/<project>/`.
- Or copy what you need into your own home folder.

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
    mcmc <- buildMCMC(mod)
    cmcmc <- compileNimble(mcmc, project = mod)
    runMCMC(cmcmc, niter = niter, nburnin = nburn)
}
res <- parallel::parLapply(cl, seeds, worker_fn,
                           code = nimble_code, data_list = data_mod,
                           inits = init_list, niter = 5000, nburn = 1000)
```

---

### R013 — Keep cluster logs on the scratch disk

Many workers writing one log file in your home folder (network storage) can
make the whole cluster hang.

**✓ Do:**

```r
cluster_log <- file.path(tempdir(), "cluster.log")
cl <- parallel::makeCluster(8, type = "PSOCK", outfile = cluster_log)
```

---

### R014 — Write only to your own directories

```r
saveRDS(result, "/home/otheruser/results.rds")   # permission denied
```

**✓ Do:**

Write to your own home folder or to your project folder under
`/mnt/ProjectStorage/<project>/`.

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
# Pass the data folder as an argument, or use here::here():
library(here)
source(here("R", "helpers.R"))
```

---

### R017 — Always specify `type = "PSOCK"` in `makeCluster()`

The default is already `"PSOCK"`, but writing it makes the intent clear
and protects you if the default is changed (`FORK` is unsafe with spatial
packages).

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
api_key <- "sk-1234abcd"   # visible in git, backups, logs
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
and breaks reproducibility — two runs a week apart can install different
code.

**✓ Do:**

Install it once from the console (or a setup script) with a fixed
version, and record versions with `renv` in your project. If the team needs
it, ask the admins to install it for everyone.

---

### R030 — Keras / TensorFlow models: train inside the worker, return a file path

Keras models are C++ objects and cannot cross a PSOCK socket. Build and
train the model inside the worker, save it to disk, and return only the
file name. Also cap TensorFlow's threads per worker so N workers do not
fight for the CPU.

**✓ Do:**

```r
train_worker <- function(lr, x, y) {
    library(keras3)   # or keras
    tensorflow::tf$config$threading$set_intra_op_parallelism_threads(2L)
    tensorflow::tf$config$threading$set_inter_op_parallelism_threads(2L)
    model <- keras_model_sequential(input_shape = ncol(x)) |>
        layer_dense(units = 64, activation = "relu") |>
        layer_dense(units = 1)
    model |> compile(optimizer = optimizer_adam(lr), loss = "mse")
    model |> fit(x, y, epochs = 10, verbose = 0)
    out <- file.path(tempdir(), paste0("model_lr_", lr, ".keras"))
    save_model(model, out)
    out   # return the path, NOT the model object
}
```

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

### R028 — Do not put cache folders inside your project in your home

```r
saveRDS(intermediate, "_temp/chunk_001.rds")   # writes to network storage
```

**✓ Do:**

```r
cache_dir <- file.path(tempdir(), "cache")
dir.create(cache_dir, showWarnings = FALSE, recursive = TRUE)
saveRDS(intermediate, file.path(cache_dir, "chunk_001.rds"))
```

Files under `tempdir()` are on the fast scratch disk and are deleted about
48 hours after last use: copy what you want to keep to your home folder.

---

### R029 — Temporary files go to `tempdir()`, not `/tmp` or your home

`/tmp` is small and fills quickly; your home folder is slow for frequent
temporary files.

**✓ Do:**

```r
# For terra (the server already does this; only needed elsewhere):
terra::terraOptions(tempdir = file.path(tempdir(), "terra_temp"))

# For your own files:
my_temp <- tempfile(fileext = ".rds")
saveRDS(data, my_temp)
```

---

## Good example — single-threaded chunked processing

This pattern produces clean, portable code that works well on BIOME-CALC:

```r
library(nimble)

# 1. Scratch folder on the fast local disk (not /tmp, not your home)
chunk_dir <- file.path(tempdir(), "mcmc_chunks")
dir.create(chunk_dir, showWarnings = FALSE, recursive = TRUE)

# 2. Size of the work (start small to test, then increase)
n_chunks    <- 10
chunk_iters <- 300

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

- Uses `tempdir()` for scratch, not `/tmp` or the home folder.
- `gc()` per chunk keeps memory usage bounded.
- `saveRDS` + `unlink` prevents scratch accumulation.
- Single-threaded — no PSOCK/clusterExport pitfalls.
- No `setwd()`, no hardcoded paths, no credentials.
- Easy to test on a small workload first.

If your script does not need parallelism, **do not add it.**
Single-threaded chunked I/O with `gc()` per chunk is often faster than
multiple workers competing for memory and disk.

---

## When you need help

1. Check this guide first — most common issues are covered above.
2. Look up the error message in *Common Problems and Solutions*.
3. If your script hangs or crashes, write to the admins with `status()`,
   `sessionInfo()`, the error text and the script path. They can check
   whether the problem is on the server or in the code. They never edit
   your scripts.

---
