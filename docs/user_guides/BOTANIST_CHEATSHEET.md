<!-- docs/user_guides/BOTANIST_CHEATSHEET.md — Path A rewrite (v2, portable R only) -->
# 🌿 BIOME-CALC — R Cheat Sheet for Botanists / Ecologists

**One page. Ten rules. Write portable R — the system handles the rest.**

> **The Contract.** Write standard CRAN-idiomatic R code.
> If your script works on your laptop, it will work here.
> You do **not** need to learn a server-specific API.
> The system profile silently enforces safety for you.

This means: do **not** put anything server-specific into your scripts.
Your scripts must stay portable to your collaborator, to a reviewer, to
a supplementary-materials reader, and to yourself in 5 years.

---

## ✅ DO / ❌ DON'T — The 10 habits

### 1. Parallel cores — use `detectCores()`, it is already safe

- ✅ `cl <- parallel::makeCluster(parallel::detectCores() - 1)`
- ✅ `options(mc.cores = parallel::detectCores())`
- ❌ `options(mc.cores = 64)` *(hard-coded — breaks on laptops)*
- ❌ `parallel::makeCluster(64)` *(hard-coded — same)*

> On this server, `detectCores()` is wrapped to return **your cgroup
> fair share**, not the host's 64 cores. On your laptop it returns
> the laptop's cores. Same code, correct behavior everywhere.

---

### 2. BLAS / OpenMP threads — do nothing

- ✅ *(write nothing about threads)*
- ❌ `Sys.setenv(OPENBLAS_NUM_THREADS = 16)` inside a script
- ❌ `RhpcBLASctl::blas_set_num_threads(16)` inside a script

> The system caps BLAS/OMP threads to 1 by default (fork-safety).
> Inside a `makeCluster()` cluster the workers automatically get
> thread-1 too. You do not need to touch any `*_NUM_THREADS` variable.
> If you think you need more, email the admin — don't hardcode.

---

### 3. Temporary files — always `tempfile()`, never `/tmp`

- ✅ `tmp <- tempfile(fileext = ".csv")`
- ✅ `td <- tempdir()`
- ❌ `write.csv(x, "/tmp/big.csv")` *(tmpfs — will OOM-kill on 10 GB rasters)*
- ❌ `setwd("/tmp"); ...`

> `tempfile()` / `tempdir()` already route to `/Rtmp` (400 GB local ext4).
> The redirection is done once in `Renviron.site`. Portable code, fast disk.

---

### 4. Stan / cmdstanr / brms — let defaults stand

- ✅ `mod <- cmdstanr::cmdstan_model("m.stan")`
- ✅ `fit <- brms::brm(y ~ x, data = d)`
- ❌ `options(cmdstanr_output_dir = "~/stan_out")` *(NFS — 100× slower)*
- ❌ `setwd("~/project"); cmdstanr::cmdstan_model(...)` *(same)*

> The profile already sets `cmdstanr_output_dir` to a fast local path
> per session. Do not override it from your script.

---

### 5. NIMBLE / TMB — use defaults

- ✅ `compileNimble(model)`
- ✅ `TMB::compile("foo.cpp")` *(compiles in cwd — which should be tempdir)*
- ❌ `options(nimble.dirName = "~/...")` *(NFS — deadlock risk)*

> NIMBLE's default `tempdir()` is already `/Rtmp/RtmpXXXX` per session.
> Do not hardcode a compile dir.

---

### 6. Large rasters — trust `terra` / `sf` defaults

- ✅ `r <- terra::rast("big.tif")`
- ❌ `terra::terraOptions(memfrac = 0.95, threads = 32)`

> Since v12.4 the profile sets `memfrac=0.5`, `todisk=TRUE`,
> `threads=1`, and points `terra`'s tempdir to `/Rtmp`. Leave it alone.
> If you ever need to keep rasters in RAM for a one-off measurement,
> `Sys.setenv(BIOME_TERRA_NORAM=1)` before `library(terra)` reverts to
> the upstream defaults — but only for that session.

---

### 7. `~/.Rprofile` — keep it cosmetic only

- ✅ `options(prompt = "R> ", digits = 6)` in `~/.Rprofile`
- ✅ Personal color / editor / repo settings
- ❌ `Sys.setenv(OMP_NUM_THREADS = 16)` in `~/.Rprofile`
- ❌ `options(mc.cores = 32)` in `~/.Rprofile`
- ❌ `setwd("~/project")` in `~/.Rprofile`

> Threading + cwd belong to the system, not your profile. If your
> `~/.Rprofile` fights the system profile, the system will usually win
> — but you'll waste hours debugging why.

---

### 8. Packages — install into your own library, let `bspm` pick binaries

- ✅ `install.packages("foo")` *(goes to your personal lib)*
- ✅ `bspm::install_sys("foo")` *(Ubuntu binary — faster, no compile)*
- ❌ `install.packages("foo", lib = "/usr/lib/R/site-library")` *(will fail — not writable)*
- ❌ Copy-pasting `remotes::install_github("...")` from a 2018 blog post

> Use `renv::init()` in your project to pin versions for reproducibility.
> Works on every server, laptop, and CI system.

---

### 9. Long jobs — run them as background jobs

- ✅ RStudio → **Tools → Background Jobs → Start Background Job**
- ✅ Terminal: `nohup Rscript my_job.R > out.log 2>&1 &`
- ✅ Terminal (better): `tmux` / `screen`
- ❌ Leaving a 12-hour `brm()` running in the interactive console

> Interactive sessions time out. Background jobs don't. Portable skill.

---

### 10. When things break — collect info, don't guess

- ✅ In R: `sessionInfo()` — paste into ticket
- ✅ In R: `traceback()` right after an error — paste into ticket
- ✅ In shell: `journalctl --user -n 200` — paste into ticket
- ❌ "It crashed" (helps nobody)

> All three commands are standard R / Linux. Every admin on Earth
> can read that output. Including me.

---

## 🚨 Red-flag symptoms → what to check FIRST

| Symptom | First check |
|---|---|
| Session crashes during `solve()` / `lm()` / `brm()` | `sessionInfo()` — BLAS line — paste to admin |
| `cannot allocate vector of size …` | `gc()`, then email admin with size |
| `No space left on device` during Stan compile | `df -h /Rtmp` |
| Parallel job uses 0% CPU | Since v12.4 `mclapply()` after `library(terra)` is auto-rerouted to PSOCK — no action needed. If still stuck, send `sessionInfo()` + `Sys.getpid()` to the admin. |
| Script runs 10× slower than yesterday | Did you write files to `~/...` instead of `tempfile()`? |
| R won't start at all | `cat /tmp/biome_boot_errors_*.log` — paste to admin |

---

## 📖 You don't need to read more than this page

But if you want to:

- `docs/user_guides/large_spatial_matrices.md` — advanced spatial workflows
- `docs/user_guides/NIMBLE_User_Guide.md` — MCMC chains on this server
- `docs/user_guides/understanding_the_new_server.md` — why the server behaves as it does
- `docs/architecture/USER_CONTRACT.md` — the formal version of *this* cheat sheet

**Server-specific helpers are in `SERVER_NATIVE_API.md` — for admins and
power users only. A normal research script should never need them.**

---

## 🆘 Built-in help — try these first, in R

The system profile pre-loads two helpers. They are the **only**
server-specific commands you should remember:

```r
biome_help()        # one-screen reminder of the 10 rules above
biome_tutorial()    # step-by-step interactive walk-through (5 min)
```

If a command is not recognised, your session loaded a **stale** profile —
restart RStudio (Session → Restart R) and try again. If it still fails,
file a bug (next section).

---

## 🐞 Bug-report path — what to attach

Don't write "it crashed". Paste these **six items** into the ticket:

1. `sessionInfo()` — output of the R console line (BLAS row matters).
2. `traceback()` — run **immediately** after the error.
3. The exact error text (copy/paste, not a screenshot).
4. `Sys.getpid()` — the PID of your R session.
5. Approximate wall-clock time (admin matches against system logs).
6. Emergency boot log if the session won't even start:
   `cat /tmp/biome_boot_errors_<PID>.log`.

Send to `%%BIOME_CONTACT%%`. The admin will run the L0–L5 diagnostic
ladder (`scripts/99_diagnose_user_script.sh`) — **no edits to your code**.

> The server contract (HC-13): the admin adapts the *system* to your
> portable R, never the other way round. If a fix is needed, it lands
> in `Rprofile_site.d/`, not in your `.R`.

---

## ⚠️ LEGACY env vars — ignore them

You may find these in old scripts, mailing-list threads, or copy-pasted
snippets. They are **no-ops** on the current server and should be deleted
from any script you maintain:

| Variable                | What it used to do        | Status now                           |
|-------------------------|---------------------------|--------------------------------------|
| `BIOME_FORCE_NFS_TMP`   | route tempdir to NFS      | **no-op** since v12.0 — uses `/Rtmp` |
| `BIOME_FORCE_TMP=/tmp`  | force tempdir to tmpfs    | **no-op** — would OOM-kill anyway    |
| `R_DISABLE_QUOTA`       | bypass `rlimit_as`        | **no-op** — cgroup still applies     |
| `BIOME_LEGACY_BLAS`     | re-enable pthread BLAS    | **no-op** — pthread BLAS = SIGSEGV   |

**Troubleshooting bypasses (v12.4)** — single-session only, never put in `.Renviron`:

| Variable                    | Effect                                                       |
|-----------------------------|--------------------------------------------------------------|
| `BIOME_DISABLE_FORK_GUARD=1`| Disable `mclapply→PSOCK` reroute (you accept fork-deadlock risk) |
| `BIOME_TERRA_NORAM=1`       | Disable `terra` `todisk=TRUE` default (rasters back in RAM)   |

If you genuinely need to lift a limit, email the admin (§ above). Do not
sprinkle environment hacks across your code.

---

## 📫 Help

- **Contact:** %%BIOME_CONTACT%%
- **Host:** %%BIOME_HOST%%
- **Emergency log:** `/tmp/biome_boot_errors_<PID>.log`

---

*Generated for BIOME-CALC Rprofile v%%RPROFILE_VERSION%%.*
*The contract: you write portable R. The server handles the rest.*
