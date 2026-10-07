---
title: "How BIOME-CALC Works for You"
audience: researcher
status: current
source_path: docs/user_guides/understanding_the_new_server.md
last_verified: 2026-10-07
sharepoint_section: Researcher Hub
---

# How BIOME-CALC Works for You

BIOME-CALC is a shared RStudio Server for the lab's R work: large rasters,
spatial statistics, Bayesian models. This chapter explains what is
different from your laptop and why, so the server's messages make sense.

## 1. Getting in

1. Open the portal address the admins gave you, in any browser.
2. Log in once with your **university username and password**.
3. The portal shows tiles:
   - **RStudio** — your usual RStudio, in the browser.
   - **Terminal** — a Linux command line on the server (for `tmux`,
     `Rscript`, `git`).
   - **Files** — upload files from your computer, where your node has it.
4. Click RStudio. You are not asked for the password again.

No VPN client, no SSH client, nothing to install on your computer.

**One session per person.** You can have one R session at a time. If you
open RStudio in a second browser or on a second server, the first window
is disconnected and shows *"another browser connected"*. Your work is not
lost: the second window shows the same session. This is a limit of the
free RStudio Server, not a fault.

**Your session waits for you.** If you close the browser, the R session
keeps running on the server for about 48 hours. Log in again and you are
back where you left it. After 48 hours of inactivity it is closed.

## 2. Where your files go

| Place | What it is | Use it for | Keep in mind |
|---|---|---|---|
| Home folder (`~`) | Network storage, the same on every server | Scripts, input data, final results | Has a **personal size limit**; reading thousands of small files is slower |
| `tempdir()` / `tempfile()` (on `/Rtmp`) | Fast 400 GB disk inside each server | Intermediate files, chunks, raster temp files | Deleted automatically about **48 hours** after last use; not on the other servers |
| `/mnt/ProjectStorage` | Shared project archive | Sharing data within a project | Write access is given per project |
| `/tmp` | Small system folder | Nothing | Big files here can crash your session |

You never need to type `/Rtmp`: `tempdir()` and `tempfile()` already point
there, so the same code works on your laptop.

## 3. Sharing memory and processors

Many people use the server at once, so each person gets a **fair share** of
memory and processors. The share grows when the server is quiet and
shrinks when it is busy.

- `parallel::detectCores()` returns **your** share, so
  `makeCluster(detectCores() - 1)` is always right.
- `status()` shows your memory, cores and scratch disk at this moment.
- Math libraries use one thread per process. This keeps parallel code
  (`parLapply`, `foreach`, `future`) from overloading the server; you do not
  need to set any thread variable.

## 4. Warnings before the crash

Some functions can ask for more memory than exists: `solve()`, `dist()`,
`outer()`, `expand.grid()` on large inputs. Before they run, the server
estimates the memory needed and prints a `BIOME-CALC:` warning with the
estimate and an alternative, for example `Matrix::Cholesky()` or sparse
methods. Read it before you continue: if the memory really runs out, the R
session is stopped and everything not saved to disk is lost.

The chapter *Working with Large Spatial Correlation Matrices* shows the
alternatives with examples.

## 5. Things the server does for you

You do not need any special code for these; your scripts stay the same as
on your laptop.

- **Spatial packages and `mclapply()`.** `mclapply()` can freeze with terra,
  sf or GDAL loaded. The server switches it to a safe cluster
  automatically.
- **terra.** Large rasters are written to the scratch disk instead of
  filling memory.
- **NIMBLE, Stan, TMB.** Model compilation happens on the scratch disk,
  separately for each session.
- **Packages.** `install.packages()` goes to your personal library.
  `bspm::install_sys("sf")` installs a ready-made binary in seconds instead
  of compiling for many minutes.
- **No automatic `.RData`.** The workspace is not saved on exit, because
  reloading a multi-GB workspace crashes the browser. Save what you need
  with `saveRDS()`.

## 6. Helpers you can call

```r
status()          # memory, cores, scratch disk, right now
biome_help()      # list of helper commands
biome_tutorial()  # short printed guide with examples
```

Where the admins installed it, `ask_ai("How do I convert this to a sparse
matrix?")` asks a language model that runs on the server, so your data and
code do not leave it.

## 7. When something goes wrong

See the companion guide **BIOME-CALC Common Problems and Solutions**. It
lists the usual error messages, what they mean, and what to do.
