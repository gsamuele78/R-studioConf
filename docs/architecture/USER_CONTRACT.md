<!-- docs/architecture/USER_CONTRACT.md -->
---
title: "BIOME-CALC User Contract"
audience: researcher, sysadmin
status: current
tier: T1
source_path: docs/architecture/USER_CONTRACT.md
last_verified: 2026-10-06
sharepoint_section: Operations Hub
---

# BIOME-CALC User Contract

## 1. Contract

> Users write portable R. The platform changes system configuration and runtime
> policy before it asks a researcher to change a script. A user script is never
> silently rewritten.

This is HC-13. It applies to incident handling, Rprofile development,
diagnostics, and documentation.

It does **not** promise that every unsafe or incorrect R program will be made
safe. It defines who owns each layer and the order in which failures are
investigated.

## 2. What the platform provides

### 2.1 Persistent and temporary storage

- The user's persistent home is `/nfs/home/<user>` on TrueNAS SCALE.
- TrueNAS enforces a per-user ZFS quota. Free filesystem space does not imply
  remaining user quota.
- R temporary files use the local 400 GiB ext4 disk mounted at `/Rtmp`.
  `TMPDIR`, `TMP`, `TEMP`, and `R_TEMPDIR` are set to `/Rtmp`.
- `/tmp` is not the R temporary-data location.
- Compiled user packages use
  `/var/lib/biome-Rlibs/<user>/<R-ver>/` when local libraries are enabled.
  The NFS user library remains a fallback for previously installed packages.
- Project/archive storage is available at `/mnt/ProjectStorage` when its CIFS
  mount is present.

### 2.2 Resource boundaries

Every login user is placed in a systemd user slice. The configured T1 controls
are `MemoryHigh=300G`, `MemoryMax=400G`, `MemorySwapMax=4G`,
`TasksMax=4096`, `CPUWeight=100`, and `IOWeight=100`.

CPU is weight-shared under contention; it is not a fixed per-user core quota.
Rprofile guards report an effective core count and constrain common parallel
entry points, but the kernel cgroup remains the final boundary.

### 2.3 Runtime compatibility layer

Rprofile version 12.11 is deployed as a dispatcher plus these active
fragments:

```text
04_user_lib_bootstrap     05_thread_guard
20_cgroup_reader          30_psock_factory
35_compile_routing        40_wrapper_installer
42_install_block          45_memory_guards
50_pkg_hooks              52_mclapply_guard
55_options_guard          60_safe_setwd
70_persistent_tools       80_tools_ext
```

The active behavior visible to portable R code is summarized below.

| User code or event | System behavior | Owner |
|---|---|---|
| `parallel::detectCores()` | Returns a cgroup-aware effective core count | `05_thread_guard` |
| `parallel::makeCluster(n)` | Guarded and routed through the PSOCK factory when strict routing is active | `45_memory_guards`, `30_psock_factory` |
| `parallel::mclapply(...)` after fork-unsafe packages are loaded | Reroutes to PSOCK and replicates attached packages and user globals | `52_mclapply_guard` |
| `options(mc.cores = n)` | Clamps the value to the effective limit | `55_options_guard` |
| `setwd()` to a missing path in batch mode | Stops with a specific error | `60_safe_setwd` |
| `setwd()` to a missing path interactively | Warns and leaves the working directory unchanged | `60_safe_setwd` |
| `solve`, `dist`, `outer`, or `expand.grid` with a large projected allocation | Applies memory checks and warnings or thread reduction according to the wrapper | `45_memory_guards` |
| `library(terra)` | Sets local `/Rtmp` scratch, default `todisk=TRUE`, and a cgroup-aware memory maximum | `50_pkg_hooks` |
| Package hooks for spatial, parallel, Java, TensorFlow, Stan, Arrow, and related packages | Apply package-specific thread, memory, or scratch controls when the namespace loads | `50_pkg_hooks` |
| First R session with a valid local library root | Creates or prepends the user's local package directory | `04_user_lib_bootstrap` |
| `install.packages()` and supported package-manager install calls | Behave normally by default; can be denied only when the operator arms the install block | `42_install_block` |

The install block is **off by default** in v12.10. Documentation that says
package installation is always blocked is incorrect.

## 3. Portable R and platform helpers

Portable scripts should use base R and package APIs. The platform exposes
`biome_*` and related helper functions for internal routing, diagnostics, and
advanced opt-in use. They are attached through the runtime tool environment,
not placed only in `.GlobalEnv`.

The existence of helpers such as `biome_make_cluster()`,
`biome_worker_diagnostics()`, `biome_plot_budget()`, `biome_tmb_compile()`,
`biome_run_diagnostics()`, and `ask_ai()` does not make them a requirement for
ordinary user code. A portable script must remain usable on a standard R
installation where those functions do not exist.

If shared wrapper code optionally uses a platform helper, it must test for it
through the search path, for example:

```r
if (exists("biome_make_cluster", mode = "function")) {
  # Optional platform path
}
```

## 4. What the platform may change

Operators may change these system-owned surfaces to restore portable code:

- `/etc/R/Renviron.site`;
- `/etc/R/Rprofile.site` and `/etc/R/Rprofile_site.d/*.R`;
- cgroup policy and service resource controls;
- BLAS, OpenMP, GDAL, allocator, and package thread caps;
- NFS mount configuration and local storage mounts;
- PAM, NSS, RStudio, Nginx, telemetry, and diagnostic configuration;
- clean-VM and minimal-R test surfaces.

Changes are made in repository templates or configuration first, then deployed.
The active BLAS is `libopenblas0-serial`; `libopenblas0-pthread` is not an
acceptable workaround. Large R temporary files remain on `/Rtmp`.

## 5. What the platform must not change silently

- A researcher's `.R` script.
- Numerical inputs, algorithms, or expected return types.
- The user's persistent data or project results.
- A user's `~/.Renviron` or `~/.Rprofile` without an explicit repair action,
  backup, and operator request.

Runtime wrappers can alter resource use, parallel backend, scratch location,
or failure timing. They must not silently alter the mathematical result of a
valid call.

## 6. Diagnostic ordering

When a user script fails, the operator clears these layers in order:

| Layer | Surface |
|---|---|
| L0 | OS, NFS, fork, cgroup, kernel, and BLAS health |
| L1 | Minimal R profile with user startup files excluded |
| L2 | Full dispatcher with all deployed fragments disabled |
| L3s | Full system profile with user startup files excluded |
| L3 | Production profile including the user's startup files |
| L4 | Clean VM with no NFS, domain, or production profile |
| L5 | User script or upstream package after earlier layers are excluded |

`scripts/99_diagnose_user_script.sh` emits a verdict naming the responsible
layer. A suggestion to edit user code is admissible only after system and
configuration layers have been excluded, the clean-VM case reproduces, and a
small reproducer plus `sessionInfo()` and kernel evidence has been captured.

## 7. Fail-open and fail-closed behavior

The runtime does not have one universal failure mode:

- Fragment loading is isolated. A fragment error is logged and later fragments
  continue loading.
- Optional package hooks normally fail open.
- Local R-library bootstrap falls back to the NFS library if the local path
  cannot be created or written.
- `setwd()` to a missing path fails closed in batch mode because continuing in
  the wrong directory can corrupt results.
- The install block fails closed only when explicitly armed.
- Kernel cgroup limits fail closed at `MemoryMax` or `TasksMax`.

New fragments must document which behavior they use and why.

## 8. Operator escape hatches

These controls exist for diagnosis or incident response. They are not the
normal researcher workflow.

| Control | Active effect |
|---|---|
| `BIOME_DISABLE_FRAGMENTS="05,52"` | Skip matching fragments for one R process |
| `BIOME_DISABLE_BUNDLE=1` | Use per-fragment loading instead of the compiled bundle |
| `BIOME_DISABLE_FORK_GUARD=1` | Disable automatic fork-to-PSOCK rerouting |
| `BIOME_FORCE_FORK_GUARD=1` | Force fork-to-PSOCK rerouting |
| `BIOME_DISABLE_USER_LIB_BOOTSTRAP=1` | Disable local library bootstrap |
| `BIOME_FORCE_INSTALL_BLOCK=1` | Arm the install block for one session |
| `BIOME_DEBUG=1` | Enable verbose runtime logging |
| `BIOME_WORKER_DEBUG=1` | Enable PSOCK worker startup logs |
| `options(biome.strict_detectCores = FALSE)` | Disable the strict core-count wrapper |
| `options(biome.strict_setwd = FALSE)` | Disable the `setwd` guard |

Other strict options are fragment-specific. Operators must verify the current
fragment before relying on an option name; this document does not promise a
single global opt-out switch.

## 9. Limits of the contract

The contract does not guarantee:

- that an allocation below 400 GiB will succeed;
- that a program will use every CPU core;
- that arbitrary fork-based native code is safe;
- that a user's TrueNAS quota has free capacity;
- that a Nextcloud backend or Ollama service is available;
- that T2 reproduces T1 Rprofile behavior today;
- that T3 is deployable;
- that incorrect R code will be made correct.

**Unverified:** actual per-user TrueNAS quota values are site state and are not
stored in this repository.

## 10. Review tripwires

Reject or rework a change when it:

- tells users to rewrite portable R before the HC-13 ladder is complete;
- moves R scratch to `/tmp` or NFS;
- installs `libopenblas0-pthread`;
- presents `biome_*` calls as mandatory portable syntax;
- adds a fragment that aborts all R sessions on an optional-hook error;
- changes `RPROFILE_VERSION` without the matching changelog and tier-delta
  update;
- documents T2 or T3 behavior as active T1 behavior.

## 11. Sources

- `.ai/project.yml` HC-13 and HC-14
- `.ai/agents.md` §6.6
- `config/setup_nodes.vars.conf`
- `templates/Renviron.template`
- `templates/Rprofile_site.R.template`
- `templates/Rprofile_site.d/README.md`
- `templates/Rprofile_site.d/*.R.template`
- `scripts/99_diagnose_user_script.sh`
- `docs/reference/Rprofile_site.CHANGELOG.md`

---

*Authoritative source: [`docs/architecture/USER_CONTRACT.md`](https://github.com/gsamuele78/R-studioConf/blob/main/docs/architecture/USER_CONTRACT.md) — last verified 2026-10-06. The Markdown file in git is the source of truth.*
