<!-- docs/user_guides/SERVER_NATIVE_API.md -->
# Server-Native API — Advanced / Optional

**Audience:** power users, admins, on-call engineers.
**Prerequisite:** you understand that anything on this page is **non-portable**.
A script using these functions **will not run on any other machine**.

If you are a botanist writing a normal analysis, you do **not** need this
document. See `BOTANIST_CHEATSHEET.md` — write portable R, we handle the
rest. This page exists only for the handful of cases where you genuinely
need to step around the invisible correction layer.

---

## When to use this page

- You're debugging why a parallel job is slower than expected.
- You need per-worker log files for a forensic post-mortem.
- You're opting *out* of a safety wrapper deliberately for one session.
- You're an admin writing cluster-wide health/audit scripts.

If none of those apply, close this tab.

---

## Cluster-building helpers

### `biome_make_cluster(workers, worker_threads = 1L, ...)`

What `parallel::makeCluster(N)` gets silently auto-routed to. Returns a
standard `cluster` object usable with every `parLapply`/`parApply`/
`clusterMap`/`foreach`/`future::cluster` pattern.

Adds on top of `parallel::makeCluster`:

- Per-worker BLAS cap (`OPENBLAS_NUM_THREADS = worker_threads`).
- Per-worker `outfile` pinned to `/Rtmp/biome_<user>/cluster_logs/<run_id>_w<i>.log`.
- `BIOME_RUN_ID` env var propagated to workers for cross-process correlation.
- Fork-safety pre-flight (refuses if active forked children detected).

```r
cl <- biome_make_cluster(4)        # identical to makeCluster(4) + safety
on.exit(parallel::stopCluster(cl))
parallel::parLapply(cl, seq, heavy_fn)
```

Use `parallel::makeCluster(4)` instead. Same thing. The auto-route is the
point.

---

## Thread-pool widening

### `biome_unleash_threads(n = 4L, gdal = FALSE)`

Temporarily raises `OMP_NUM_THREADS` / `OPENBLAS_NUM_THREADS` / `MKL_NUM_THREADS`
(and optionally GDAL/PROJ) for a scoped block of **non-forking** compute.
`n` is the target number of threads; caller is responsible for not forking
while raised.

### `biome_restore_threads()`

Restores all native thread caps to 1. Call this **before** any
`parallel::mclapply`, `future::plan("multicore")`, or `fork()` of any kind.

```r
biome_unleash_threads(8)           # wide matrix math, no forking
on.exit(biome_restore_threads())
res <- solve(crossprod(X))         # uses 8 BLAS threads
```

---

## Forensic helpers

### `biome_worker_diagnostics(cl)`

Dumps per-worker pid, tempdir, loaded packages, BLAS path, and thread env
vars. Useful when `parLapply()` hangs and you need to know which worker
is wedged.

### `biome_plot_budget()`

Reports RAM available to the current cgroup, usable `/Rtmp` bytes, and
recommended `mc.cores` / matrix-size ceilings.

### `biome_debug_dump()`

Tails the session sys_log (`/tmp/biome_debug_<user>_<pid>.log`). Only
populated when `BIOME_DEBUG=1` was set in the shell before starting R.

### `biome_tmb_compile(model, dir = NULL)`

Convenience wrapper around `TMB::compile()` that routes output to
`/Rtmp/biome_<user>/tmb/<run_id>/` instead of the user's NFS home.

### `biome_cluster_test(workers = 2)`

End-to-end sanity test: creates a cluster, runs a trivial map, verifies
BLAS caps + outfile routing + BIOME_RUN_ID propagation. Exits 0 on pass.

---

## Opt-out options (all default TRUE)

| `options(…)`                            | Disables                                    |
|-----------------------------------------|---------------------------------------------|
| `biome.strict_detectCores = FALSE`      | `parallel::detectCores()` cgroup clamp      |
| `biome.strict_mc_cores = FALSE`         | `options(mc.cores = N)` clamp               |
| `biome.strict_makecluster = TRUE`       | auto-route of `parallel::makeCluster`       |
| `biome.strict_setwd = FALSE`            | `setwd()` existence check                   |

| Turn ON (default FALSE)                 | Effect                                      |
|-----------------------------------------|---------------------------------------------|
| `biome.verbose = TRUE`                  | banner when a call is silently rerouted     |

---

## Shell-env overrides

Set in the shell **before** starting R. Inherited by the session and all
PSOCK workers.

| Env var                           | Effect                                              |
|-----------------------------------|-----------------------------------------------------|
| `BIOME_DEBUG=1`                   | mirror all sys_log to stderr + `/tmp/biome_debug_*` |
| `BIOME_WORKER_DEBUG=1`            | per-PSOCK-worker `/tmp/biome_worker_<pid>.log`      |
| `BIOME_DISABLE_BUNDLE=1`          | bypass byte-compiled fragment bundle, use per-fragment loop |
| `BIOME_DISABLE_FRAGMENTS="20,45"` | skip fragments with those prefixes or basenames     |
| `BIOME_TMP_DISK_GB=<int>`         | override `/Rtmp` size hint used for budgeting       |

---

## Invariants you must not violate

1. **Never publish scripts that call `biome_*` functions.** If you need
   `biome_unleash_threads` in a reproducible pipeline, wrap it in
   `if (exists("biome_unleash_threads"))` so the script runs off-cluster
   unchanged.

2. **Never flip `biome.strict_*` globally** (e.g. in a project-level
   `.Rprofile`). Scope flips with `withr::with_options()` or immediate
   `on.exit()` restoration.

3. **`biome_unleash_threads` is incompatible with `fork()`.** If you call
   `mclapply`, `future::plan("multicore")`, or any library that forks
   (e.g. `progressr` with certain handlers), restore threads first.

4. **Do not edit `/etc/R/Rprofile_site.d/*.R` directly.** Those are
   deployed artefacts. Changes belong in
   `templates/Rprofile_site.d/*.R.template` + a `50_setup_nodes.sh` run.

---

## If you're reading this to write user-facing docs

Stop. The user-facing doc is `BOTANIST_CHEATSHEET.md`. This file is
deliberately kept sparse and frictionful so it doesn't leak into end-user
training material. See `docs/architecture/USER_CONTRACT.md` for why.
