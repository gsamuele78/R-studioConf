---
title: "BIOME-CALC R Cheat Sheet"
audience: researcher
status: current
source_path: docs/user_guides/BOTANIST_CHEATSHEET.md
last_verified: 2026-10-07
sharepoint_section: Researcher Hub
---
<!-- docs/user_guides/BOTANIST_CHEATSHEET.md -->
# BIOME-CALC R Cheat Sheet

**One page, ten habits. Write normal R; the server takes care of the rest.**

> If your script works on your laptop, it works here. You do not need any
> server-specific code, and you should not add any: your scripts must keep
> working for your collaborators, your reviewers, and you in five years.

---

## The 10 habits

### 1. Number of cores: always use `detectCores()`

- Do: `cl <- parallel::makeCluster(parallel::detectCores() - 1)`
- Do: `options(mc.cores = parallel::detectCores())`
- Don't: `parallel::makeCluster(64)` or `options(mc.cores = 64)` (a fixed
  number breaks on every other computer)

On the server `detectCores()` returns **your fair share** of the
processors; on your laptop it returns the laptop's cores. Same code,
right answer everywhere.

### 2. Math library threads: write nothing

- Do: nothing.
- Don't: `Sys.setenv(OPENBLAS_NUM_THREADS = 16)` or
  `RhpcBLASctl::blas_set_num_threads(16)` in a script.

The server sets these for you, also inside parallel workers. If you think
you need more threads, ask the admins.

### 3. Temporary files: `tempfile()` and `tempdir()`, never `/tmp`

- Do: `tmp <- tempfile(fileext = ".csv")`, `td <- tempdir()`
- Don't: `write.csv(x, "/tmp/big.csv")` or `setwd("/tmp")`

`tempdir()` already points to `/Rtmp`, a fast 400 GB scratch disk on the
server. `/tmp` is small and big files there can crash your session.

### 4. Stan / cmdstanr / brms: keep the defaults

- Do: `mod <- cmdstanr::cmdstan_model("m.stan")`, `brms::brm(y ~ x, data = d)`
- Don't: `options(cmdstanr_output_dir = "~/stan_out")` (your home folder is
  network storage, much slower)

The server already sends Stan output to the fast scratch disk.

### 5. NIMBLE / TMB: keep the defaults

- Do: `compileNimble(model)`, `TMB::compile("foo.cpp")`
- Don't: set your own compile folder in your home.

Compilation already happens on the fast scratch disk, separately for each
session.

### 6. Large rasters: trust `terra` and `sf`

- Do: `r <- terra::rast("big.tif")`
- Don't: `terra::terraOptions(memfrac = 0.95, threads = 32)`

The server sets terra to write large rasters to the scratch disk instead
of filling memory. Leave those settings alone.

### 7. `~/.Rprofile`: only cosmetic settings

- Do: `options(prompt = "R> ", digits = 6)`, colours, editor, CRAN mirror.
- Don't: threads, `mc.cores` or `setwd()` in `~/.Rprofile`.

If your `~/.Rprofile` changes threads or folders, the server's settings and
yours fight, and you lose hours finding out why.

### 8. Packages: your own library

- Do: `install.packages("foo")` (goes into your personal library)
- Do: `bspm::install_sys("foo")` (ready-made binary, seconds instead of
  minutes)
- Do: `renv::init()` in a project to record package versions
- Don't: `install.packages("foo", lib = "/usr/lib/R/site-library")` (read-only)

### 9. Long analyses: run them in the background

- Do: **Background Jobs** tab (next to the Console) → *Start Background Job*
- Do: in the portal's Terminal: `tmux`, then `Rscript my_job.R`; leave with
  **Ctrl+B then D**, come back later with `tmux attach`
- Don't: a 12-hour `brm()` in the interactive console

Your session waits for you about 48 hours, but a browser crash still loses
anything not saved to disk.

### 10. When something breaks: collect, don't guess

- Do: `sessionInfo()` and, right after the error, `traceback()`
- Do: `status()`
- Don't: "it crashed" (nobody can help with that)

---

## First things to check

| What you see | First check |
|---|---|
| Session crashes during `solve()` / `lm()` / `brm()` | Send `sessionInfo()` to the admins |
| `cannot allocate vector of size ...` | `status()`, then *Common Problems* §3 |
| `Disk quota exceeded` when saving | *Common Problems* §1 |
| `No space left on device` during Stan compile | `status()` (scratch disk use) |
| Parallel code uses 0 % CPU | *Common Problems* §5 |
| Script 10× slower than yesterday | Writing many files to `~/` instead of `tempfile()`? |
| R does not start at all | Terminal: `cat /tmp/biome_boot_errors_*.log`, send it to the admins |

---

## Built-in help, in R

```r
status()           # your memory, cores and scratch disk, right now
biome_help()       # list of the helper commands
biome_tutorial()   # short printed guide: resources, scratch disk, parallel examples
```

If R says the command does not exist, restart R (Session → Restart R) and
try again. If it still fails, tell the admins.

---

## What to send the admins

1. `sessionInfo()`
2. `traceback()`, run right after the error
3. The exact error text, copied (not a screenshot)
4. `status()`
5. The script path and the approximate time
6. If R did not start: the content of `/tmp/biome_boot_errors_*.log`

The admins fix problems on the server side. They will not ask you to put
server-specific code into your scripts.

---

## Old settings you can delete

You may find these in old scripts or e-mails. They do nothing on the
current server; remove them from your scripts:

| Setting | Status |
|---|---|
| `BIOME_FORCE_NFS_TMP` | does nothing; temporary files always go to the scratch disk |
| `BIOME_FORCE_TMP=/tmp` | does nothing |
| `R_DISABLE_QUOTA` | does nothing |
| `BIOME_LEGACY_BLAS` | does nothing |

Two switches exist for troubleshooting, **only when the admins ask you**,
for one session, never in `.Renviron` or in a script:

| Setting | Effect |
|---|---|
| `Sys.setenv(BIOME_DISABLE_FORK_GUARD = 1)` | switches off the automatic protection of `mclapply()` |
| `Sys.setenv(BIOME_TERRA_NORAM = 1)` (before `library(terra)`) | terra keeps rasters in memory again |

---

## Contact

Your lab's BIOME-CALC admin contact is shown in the welcome message when R
starts and when you open the Terminal.
