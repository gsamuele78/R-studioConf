<!-- docs/developer/README.md -->
# Developer Documentation

This directory documents the active T1 host implementation of BIOME-CALC as of 2026-10-06. T1 is `AUTHORITATIVE_CONTINUOUSLY_FIXED`; fixes start in the host code and are then ported to T2 and T3. T2 is `MIGRATION_IN_PROGRESS`. T3 is `SKELETON_NOT_READY`.

## Documents

- [Library Reference](LIBRARY_REFERENCE.md) — the public and internal functions actually defined by `lib/common_utils.sh`.
- [Scripts Reference](SCRIPTS_REFERENCE.md) — root orchestrators, numbered scripts, diagnostics, fixes, and operator tools under `scripts/`.
- [Configuration Reference](CONFIGURATION_REFERENCE.md) — committed configuration files, site-local overlays, variables, and canonical version sources.
- [Templates Reference](TEMPLATES_REFERENCE.md) — active templates, deployment destinations, the modular `Rprofile_site.d/` chain, and legacy files.
- [Consumer Repository Workflow](git_submodule_workflow.md) — the current relationship with `Infra-Iam-PKI`; this repository has no Git submodules.

For full generated inventories, also use:

- [`../reference/SCRIPT_CATALOG.md`](../reference/SCRIPT_CATALOG.md)
- [`../reference/CONFIGURATION_MAP.md`](../reference/CONFIGURATION_MAP.md)
- [`../reference/TEMPLATE_GALLERY.md`](../reference/TEMPLATE_GALLERY.md)

## Authoritative flow

```text
init.sh -> r_env_manager.sh -> scripts/NN_*.sh
                         \-> scripts/99_*.sh and maintenance tools
```

`r_env_manager.sh` is version 2.0.0 in its source header. Its active paths are:

- lock: `/var/run/r_env_manager.sh.lock`
- PID: `/var/run/r_env_manager.sh.pid`
- log: `/var/log/biome-log/core/r_env_manager.sh.log`
- state: `/var/lib/r_env_manager/r_env_state`
- package inventory, when present: `/var/lib/r_env_manager/installed_packages.state`
- configuration: `config/r_env_manager.conf`

The active R runtime is deployed by `scripts/50_setup_nodes.sh`. `config/setup_nodes.vars.conf` sets `RPROFILE_VERSION="12.11"`; large R temporary data belongs on the local 400 GB ext4 mount at `/Rtmp`; OpenBLAS must use the serial implementation, never `libopenblas0-pthread`.

## Change rules

1. Fix T1 first. Port behavior forward to T2 and then T3, or record a deliberate tier delta in `.ai/project.yml`.
2. Every shell script must start with a shebang and `set -euo pipefail`, source `lib/common_utils.sh` when it is a numbered script, and preserve the shared logging/error contracts.
3. Use the functions that exist. The template helper is `process_template`, not `__process_template`; systemd templates use the separate `process_systemd_template` implementation.
4. Keep scripts idempotent. Treat failed ownership or permission setup as fatal where required by HC-10.
5. Put site-specific AD topology, mail settings, addresses, and PII in gitignored `config/site/` files created from committed `*.example` files. See [`../../config/SITE_OVERRIDE.md`](../../config/SITE_OVERRIDE.md).
6. Use `jq` for JSON changes. Do not edit JSON with `sed` or `awk`.
7. Never pass passwords in command-line arguments or silently modify researcher-owned `.R` scripts.
8. A change to `RPROFILE_VERSION` must include the matching `docs/reference/Rprofile_site.CHANGELOG.md` entry and required cross-document updates in the same commit (HC-14).
9. Do not activate `src/biome_core_rust`; it is dormant. Do not touch `Infra-Iam-PKI.backup`.
10. Do not use the Vagrant/libvirt sandbox for validation; it is known broken.

## Validation

Use the repository gates that correspond to the changed surface. `make audit`, shell syntax checks, and the CI jobs are code-backed checks; the production host remains the required runtime validation surface while the sandbox is broken.

Unverified: this documentation audit did not execute deployment scripts on a production host, so service health, mounted storage, AD reachability, and live credentials were not tested.
