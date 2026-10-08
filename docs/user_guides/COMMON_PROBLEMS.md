---
title: "Common Problems and How to Solve Them"
audience: researcher
status: current
source_path: docs/user_guides/COMMON_PROBLEMS.md
last_verified: 2026-10-07
sharepoint_section: Researcher Hub
---
<!-- docs/user_guides/COMMON_PROBLEMS.md -->
# Common Problems and How to Solve Them

> **For researchers using R on BIOME-CALC.** Each section is one problem:
> what you see, why it happens, what you can do yourself, and when to ask
> the admins. Jump to the symptom that matches yours.

## Before you write to the admins

Run these in the RStudio console and paste the output into your message,
as text (not a screenshot):

```r
status()        # your memory, cores and disk on this server
sessionInfo()   # R version and loaded packages
traceback()     # right after an error: where it happened
```

Add the exact error message, the path of the script you were running, and
roughly when it happened. With this the admins can usually answer at once.

---

## 1. Saving fails with "Disk quota exceeded"

**What you see**

```
Error in gzfile(file, mode) : cannot open the connection
In addition: Warning message:
In gzfile(file, mode) :
  cannot open compressed file '/nfs/home/you/results.rds',
  probable reason 'Disk quota exceeded'
```

The same happens with `write.csv()`, `writeLines()` and any other export.
The word "compressed" is misleading: `saveRDS()` always opens files that
way. The real message is **Disk quota exceeded**.

**Why it happens**

Your home folder has a personal size limit (quota). When it is full, no new
file can be created, not even a tiny one. Tools that show free disk space
(the Files pane, `df`) show the space of the whole storage, not your
personal limit, so they can say "plenty of space" while your quota is full.

**What you can do**

- First run `status()` in R. The `Home (~)` line shows space used, your
  personal limit, percentage and when it was last updated. For the full
  explanation run `biome_quota()` (or `biome-quota` in the Terminal).
  If it says "information not available", send the admins the original error.
- See which of your folders are biggest (hidden folders such as `.cache`
  included; it can take a minute):

  ```r
  sizes <- sapply(list.dirs("~", recursive = FALSE), function(d)
    sum(file.info(list.files(d, recursive = TRUE, full.names = TRUE, all.files = TRUE))$size,
        na.rm = TRUE))
  round(sort(sizes, decreasing = TRUE) / 1e9, 2)   # GB
  ```

- Delete files you no longer need, or move old results to the project share.
- Save intermediate objects to the fast scratch disk instead of your home.
  `tempdir()` is already there:

  ```r
  saveRDS(big_intermediate, file.path(tempdir(), "chunk_01.rds"))
  ```

  Scratch files are deleted about 48 hours after you stop using them, so
  copy final results back to your home.
- Save single objects with `saveRDS()` instead of the whole workspace
  (`save.image()`): the files are much smaller.

**When to ask the admins**

When you have cleaned up and still need more space. Send the output of
`biome_quota()` and tell them how much space the project needs; they can raise
your quota. The number can be up to five minutes old.

---

## 2. "Permission denied" when writing to the project share

**What you see**

```
Error in file(con, "wb") : cannot open the connection
In addition: Warning message:
In file(con, "wb") :
  cannot open file '/mnt/ProjectStorage/myproject/out.csv': Permission denied
```

**Why it happens**

`/mnt/ProjectStorage` is the shared project archive. Being able to *see* a
folder there does not mean you can *write* to it: write access is given per
project.

**What you can do**

- Check whether you can write there:

  ```r
  file.access("/mnt/ProjectStorage/myproject", mode = 2)  # 0 = yes, -1 = no
  ```

- If not, save to your home folder and ask the admins to copy the files to
  the project folder.

**When to ask the admins**

If you should have write access to that project folder. Send the exact path
and the project name.

---

## 3. Out of memory: "cannot allocate vector of size ..."

**What you see**

A plain R error:

```
Error: cannot allocate vector of size 74.5 Gb
```

or a BIOME-CALC warning *before* the calculation starts, for example:

```
BIOME-CALC: solve() on 50000 x 50000 matrix (~19 GB) needs ~38 GB.
  Available RAM: ~24 GB. OOM risk is HIGH.
  BLAS: serial (no thread reduction available).
  Alternatives: Matrix::Cholesky() for SPD, or sparse methods.
```

Similar warnings exist for `dist()`, `outer()` and `expand.grid()`:

```
BIOME-CALC: dist() on 100000 observations will create a 37.3 GB dist object.
  as.matrix() on this would need 74.5 GB. Available RAM: ~24 GB.
  For N > 20,000: consider sparse distance methods or spatial indexing.
```

**Why it happens**

The server is shared, and each user gets a share of its memory. The
warning estimates how much memory the calculation needs and tells you
before R runs out. If you go ahead anyway and the memory really runs out,
the R session is stopped (see section 4).

**What you can do**

- See your memory: `status()` shows how much RAM is available to you now.
- Follow the alternatives printed in the warning. For large distance
  matrices see the guide *Working with Large Spatial Correlation
  Matrices* (sparse matrices, `Matrix::Cholesky()`, `data.table::CJ()`
  instead of `expand.grid()`).
- Remove big objects you no longer need: `rm(big_object); gc()`.
- Work in chunks and save each chunk with `saveRDS()` (section 1).

**When to ask the admins**

If your analysis really needs more memory than `status()` shows. Send the
warning text and the script path.

---

## 4. "R session aborted"

**What you see**

RStudio shows **"R session aborted"** and restarts with an empty
environment. Your next session may start with:

```
WARNING: Previous session killed by OOM
```

Sometimes the browser tab crashes instead ("Aw, Snap!"), usually when
RStudio reloads a very large workspace.

**Why it happens**

Almost always the session ran out of its memory share and was stopped
(section 3). Saving the workspace on exit is switched off on this server
for this reason, but loading a very large `.RData` file yourself can still
crash the browser.

**What you can do**

- Anything that was only in memory is lost; what you saved to disk is safe.
  Restart from your last `saveRDS()` file.
- If you used `biome_save_session()`, restore with `biome_load_session()`.
  It warns you if the backup is too big for the memory you have now.
- In long scripts, save results step by step with `saveRDS()`.
- For long NIMBLE runs: wait until `compileNimble()` has finished before
  closing the browser tab, and save a checkpoint first.

**When to ask the admins**

If it keeps crashing at the same point after you reduced memory use. Send
the script path, the time of the crash, and whether
`file.exists("~/ULTIMO_CRASH_RAM.txt")` is `TRUE`.

---

## 5. Parallel code hangs or workers fail

**What you see**

`parallel::mclapply()` starts, uses no CPU and never ends. Or the workers
stop with:

```
Error in unserialize(node$con) : error reading from connection
```

**Why it happens**

1. **`mclapply()` with spatial packages.** `mclapply()` copies the running R
   session. Packages such as terra, sf and GDAL do not survive being copied
   and can freeze. The server already protects you: when those packages
   are loaded, `mclapply()` is switched to a safe cluster automatically.
2. **Sending compiled objects to workers.** Compiled NIMBLE/Stan/TMB models
   and `terra` rasters live outside R's memory and cannot be sent to another
   process (see `?serialize`). Each worker must load or compile its own copy.

**What you can do**

- Use a cluster and load packages and data *inside* the workers:

  ```r
  cl <- parallel::makeCluster(4)
  parallel::clusterEvalQ(cl, library(terra))
  res <- parallel::parLapply(cl, paths, function(p) {
    r <- terra::rast(p)              # read inside the worker
    terra::global(r, "mean", na.rm = TRUE)
  })
  parallel::stopCluster(cl)
  ```

- For `terra` objects already in memory: `terra::wrap()` before sending,
  `terra::unwrap()` inside the worker.
- Check that parallel computing works for you: `biome_cluster_test()`.
- See why recent workers failed: `biome_worker_diagnostics()`.

More patterns in *Safe Parallel R — Do's and Don'ts*.

**When to ask the admins**

If `biome_cluster_test()` reports `[FAIL]`, or workers keep failing after
you load everything inside them. Send the output of both functions above.

---

## 6. detectCores() returns fewer cores than the server has

**What you see**

```r
parallel::detectCores()
# [1] 8        # on a server with many more cores
```

**Why it happens**

This is on purpose. Each user gets a fair share of the processors, and
`detectCores()` returns **your** share. The same script on your laptop
returns the laptop's cores, so your code works in both places without
changes. `options(mc.cores = ...)` is limited to your share in the same way.

**What you can do**

- Size clusters from `detectCores()` and never type a fixed number:

  ```r
  n_workers <- max(1L, parallel::detectCores() - 1L)
  cl <- parallel::makeCluster(n_workers)
  ```

- `status()` shows your current share.

**When to ask the admins**

If `biome_cgroup_verify()` prints `[ACTION NEEDED]`. First log out of
RStudio and back in; if the message stays, ask the admins.

---

## 7. A package will not install, or "there is no package called ..."

**What you see**

```
Warning in install.packages :
  'lib = "/var/lib/biome-Rlibs/you/4.5"' is not writable
```

```
Error in library(foo) : there is no package called 'foo'
```

or, only during periods when installing has been switched off centrally:

```
BIOME-CALC: install.packages() is disabled on this cluster.
            Ask the sysadmin to add 'foo' to
            config/r_env_manager.conf :: R_USER_PACKAGES_CRAN,
            then re-run.
```

**Why it happens**

- Your packages go into your own library on the server. Packages installed
  for all users are read-only.
- "There is no package called" after you installed it some time ago usually
  means it was installed for an older R version, or into the older library
  in your home folder.
- The last message means the admins have temporarily centralised package
  installation; just send them the package name.

**What you can do**

- See your libraries, first one = where new packages go:

  ```r
  .libPaths()
  ```

- Install normally and load:

  ```r
  install.packages("foo")
  library(foo)
  ```

- Ready-made binaries install in seconds: `bspm::install_sys("foo")`.

**When to ask the admins**

If the "not writable" warning appears in every session, or installation is
switched off and you need a package. Send the package name (for GitHub
packages, the repository) and the output of `.libPaths()`.

---

## 8. A setwd() warning, and files saved in the wrong folder

**What you see**

```
Warning message:
BIOME-CALC safe_setwd: target directory does not exist: '/nfs/home/you/projet'
  cwd remains: /nfs/home/you
  This guard prevents the 'unserialize(node$con)' class of bug.
  To override (not recommended): options(biome.strict_setwd = FALSE)
```

**Why it happens**

The folder you gave `setwd()` does not exist (often a typo). In RStudio the
working folder **does not change**, R only warns, and the script continues.
Everything it saves then goes into the *previous* folder, so your results
seem to disappear. In `Rscript` or in parallel workers the same mistake
stops the script at once.

**What you can do**

- Read the warning: it shows the folder you asked for and the one you are in
  (`getwd()`).
- Fix the path and run `setwd()` again.
- Better: avoid `setwd()` and build paths with `here::here()` or
  `file.path()`.
- Lost files are usually in the folder shown after `cwd remains:`.

**When to ask the admins**

Only if `setwd()` fails for a folder that really exists
(`dir.exists("...")` returns `TRUE`).

---

## 9. The Plots pane stays empty

**What you see**

`plot(1, 1)` or `print(my_ggplot)` gives no error, but nothing appears in
the **Plots** pane.

**What you can do**

- Restart R (Session → Restart R) and try `plot(1, 1, main = "test")`.
- Check the graphics device:

  ```r
  options("device")   # inside RStudio it should mention RStudioGD
  ```

- Plots made by background jobs, `Rscript` or tmux never appear in a pane.
  Save them to a file instead: `ggsave("out.png")`, or
  `png("out.png"); plot(...); dev.off()`.

**When to ask the admins**

If `plot(1, 1)` still shows nothing after a restart, or `options("device")`
does not mention `RStudioGD`. Send that output and `sessionInfo()`.

---

## 10. Reading many files from your home folder is slow

**What you see**

Reading or writing many files in your home folder (`~`) is much slower than
in `tempdir()`. A large raster in your home loads slowly.

**Why it happens**

Your home folder is on network storage shared by all servers, so each read
goes over the network. The scratch disk `/Rtmp` (where `tempdir()` points)
is a fast local disk inside each server.

**What you can do**

- Keep inputs and final results in your home folder (kept, visible from
  every server).
- Put scratch and intermediate files in `tempdir()` / `tempfile()`.
- For a big raster you read many times, copy it to scratch first:

  ```r
  local_copy <- file.path(tempdir(), basename(path))
  file.copy(path, local_copy)
  r <- terra::rast(local_copy)
  ```

- `biome_plot_budget()` shows how much scratch space you use.

**When to ask the admins**

If scratch itself is slow or `status()` says it is nearly full (you get a
warning at 80 %).

---

## 11. Files in /Rtmp disappeared

**What you see**

Files you wrote to `/Rtmp` (or `tempdir()`) a few days ago are gone.

**Why it happens**

`/Rtmp` is scratch space. Old files are deleted automatically after the
period shown by `status()` (`Tmp Cleanup: Files >N hours`, about 48 hours).
It is local to each server and has no backup.

**What you can do**

- Treat `/Rtmp` as disposable: copy results to your home at the end of each
  script.
- Files you need for longer belong in your home (mind the quota, section 1)
  or the project share.

---

## 12. Cannot log in, or the R session does not start

**What you see**

- The login page rejects your university credentials, or shows an error.
- RStudio opens but the session never finishes starting, or you get a new
  empty session instead of your previous one.

**Why it happens**

- You log in with your university (Active Directory) username and
  password. A wrong or expired password, or a locked account, is the most
  common cause.
- Your previous R session is kept for about 48 hours after you close the
  browser. After that it is closed and a new one starts. That is normal.

**What you can do**

- Log out completely and log in again.
- Try a private/incognito browser window (old cookies can break the login).
- If R starts but behaves strangely, open the portal's **Terminal** and
  run:

  ```bash
  cat /tmp/biome_boot_errors_*.log
  ```

  If a file is shown, send its content to the admins.

**When to ask the admins**

If you cannot log in at all, or the session repeatedly fails to start.
Send the exact error, the time, your username, and the boot log above if
it exists.

---

## 13. Long analyses: how not to lose your work

**What you see**

You left a 10-hour script running in the console, closed the laptop, and
the next morning the session was gone.

**Why it happens**

The session waits for you about 48 hours, but a browser crash or running
out of memory still loses everything that was not saved to disk. The
console is the wrong place for long runs.

**What you can do**

- **RStudio Background Jobs** (easiest): the **Background Jobs** tab next
  to the Console → *Start Background Job* → choose your script. It keeps
  running even if you close RStudio.
- **tmux** in the portal's Terminal, for `Rscript`:

  ```bash
  tmux                       # a green bar appears at the bottom
  Rscript my_script.R        # start your analysis
  # press Ctrl+B, release, then D → you leave it running
  tmux attach                # next day: back to it
  ```

- Inside long loops, save results with `saveRDS()` every few iterations, so
  a crash only costs the last step.
- Before leaving a long interactive session, run `biome_save_session()`.

**When to ask the admins**

If a background job or tmux run was stopped before finishing. Send the
script path, the start time, and `status()` from a new session.
