<!-- docs/architecture/USER_CONTRACT.md -->
# The Biome-Calc User Contract

**Audience:** system architects, future maintainers, code reviewers.
**Status:** normative. Every fragment in `templates/Rprofile_site.d/` exists
to enforce this contract.

---

## The one-line contract

> **Users write portable R. The system silently corrects unsafe choices.
> No biome-specific API appears in user code.**

---

## Why this contract exists

Botanists and ecologists who use this cluster are not systems programmers.
Their scripts are:

- **Shared** — co-authored with collaborators on other institutions, other
  hardware, other OSes.
- **Re-run** — months or years later, on different machines, when the
  author has forgotten everything about the original environment.
- **Published** — as supplementary material, data repositories, reproducible
  research bundles. Any line that reads `biome_something(...)` breaks on
  every other R installation in the world.

If we expose a custom API (e.g. `biome_make_cluster`, `biome_tutorial`,
`biome_unleash_threads`) and document it as "the way to parallelise on our
cluster", we have:

1. Forced every user to mutilate their portable scripts.
2. Guaranteed that those scripts will crash the moment they leave our
   infrastructure.
3. Created a permanent training burden for every new hire.
4. Built a silent trap: copy-pasting a collaborator's portable script back
   into our cluster will *also* run unsafely, because the biome API was
   never there.

The contract inverts the burden: **we absorb every hack**, so the user
never has to know.

---

## What "silently corrects" means

| User writes (portable R) | System does invisibly                              | Fragment |
|--------------------------|----------------------------------------------------|----------|
| `parallel::detectCores()`             | returns cgroup share, not host count  | `05_thread_guard` |
| `parallel::makeCluster(N)`            | routes to `biome_make_cluster` (BLAS caps, run-id, outfile) | `45_memory_guards` |
| `options(mc.cores = 64)`              | clamps to cgroup cap                   | `55_options_guard` |
| `setwd("~/missing")` (batch)          | hard-fails with clear message — prevents Martina-gate `unserialize()` bug | `60_safe_setwd` |
| `setwd("~/typo")` (interactive)       | warns, cwd unchanged                   | `60_safe_setwd` |
| `library(polars)`                     | caps `POLARS_MAX_THREADS`              | `50_pkg_hooks` |
| `library(torch)`                      | caps intra/inter-op pools              | `50_pkg_hooks` |
| `library(collapse)`                   | sets `collapse_nthreads`               | `50_pkg_hooks` |
| `library(terra)`                      | pins to single-thread (fork-safe), routes tempdir to `/Rtmp` | `50_pkg_hooks` |
| `solve(big_matrix)`                   | OOM guard, thread reduction            | `45_memory_guards` |
| `dist(big_df)`                        | RAM-exceeds warning                    | `45_memory_guards` |
| `outer(X, Y)` (large)                 | RAM-exceeds warning                    | `45_memory_guards` |
| `library(rJava)`                      | dynamic `-Xmx` from cgroup RAM         | `50_pkg_hooks` |

None of these require the user to change their code. All of them are opt-out
via standard `options(biome.strict_* = FALSE)` — but opt-out is **never**
recommended and never appears in user-facing documentation.

---

## What "no biome API in user code" means

There **are** `biome_*` helper functions in the system (`biome_make_cluster`,
`biome_unleash_threads`, `biome_tutorial`, `biome_worker_diagnostics`, …).
They exist for two reasons:

1. **Internal plumbing.** The auto-routers delegate to them.
2. **Expert opt-in.** A power-user who *knows* they are not going to fork
   can call `biome_unleash_threads(8)` to widen BLAS caps for a scoped
   compute block.

They are **never** taught as "the way to work on our cluster". The cheat
sheet (`docs/user_guides/BOTANIST_CHEATSHEET.md`) and the MOTD
(`templates/motd_biome_rules.template`) teach portable R only. The
server-native API is documented separately in
`docs/user_guides/SERVER_NATIVE_API.md` and flagged as *advanced / optional*.

---

## Invariants every new fragment must respect

When proposing a new guard, it is admissible **only if** it passes all three:

1. **Invisibility.** The guard fires without producing interactive output
   in the common case. Warnings/messages are opt-in via `options(biome.verbose = TRUE)`.
   Only genuine errors (batch mode setwd, OOM near-miss) surface.

2. **No new user-visible API.** The guard wraps an existing base/CRAN
   function. If you find yourself introducing a new function name the user
   has to call, stop — that's a violation. Rework as a wrapper.

3. **Fail-open.** If the guard cannot resolve (e.g. cgroup path missing,
   package symbol not found), it passes the call through unchanged. The
   user's script never breaks *because of us*.

---

## Non-goals

- **Replacing portable R with a DSL.** We are not building Spark-on-R.
- **Preventing every misuse.** A user who reads 400GB into `data.frame()`
  will still OOM. We guard the statistically common traps.
- **Silent *correctness* changes.** We clamp *resource* use (threads, RAM,
  cores). We never silently change numerical results, function signatures,
  or return types.

---

## Tripwires (when the contract is being violated)

- Cheat sheet / MOTD / tutorial starts showing `biome_*` function calls.
- A new option defaults to `biome.verbose = TRUE`.
- A guard `stop()`s in interactive mode for a recoverable situation.
- A fragment introduces a new globally-visible function without an
  underscore prefix.
- Deploy script fails because a fragment references an unreleased
  upstream package.

Any of these signals a scope-creep PR that should be rejected or reworked
until the contract holds.

---

## Escape hatches (documented, not advertised)

These exist for the rare power-user who knows the system:

| Knob                                    | Effect                                      |
|-----------------------------------------|---------------------------------------------|
| `options(biome.strict_detectCores = FALSE)` | raw host count                         |
| `options(biome.strict_mc_cores = FALSE)`    | pass-through `options(mc.cores = ...)` |
| `options(biome.strict_makecluster = TRUE)`  | disable auto-route (user must call biome_make_cluster manually) |
| `options(biome.strict_setwd = FALSE)`       | disable setwd guard                    |
| `options(biome.verbose = TRUE)`             | opt into "I rerouted your call" banners|
| `BIOME_DEBUG=1` (shell env)                 | full sys_log to stderr + /tmp          |
| `BIOME_DISABLE_FRAGMENTS=NN`                | skip fragment NN (debug only)          |
| `biome_unleash_threads(n)` / `biome_restore_threads()` | scoped BLAS widening          |

These are in `SERVER_NATIVE_API.md`, not the botanist cheat sheet.
