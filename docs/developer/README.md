# BIOME Calculus Portal - Developer Reference

This directory contains the internal, highly technical documentation intended for System Administrators, DevOps Engineers, and Developers maintaining the R-Studio/BIOME portal infrastructure.

Unlike the operational guides in the parent `docs/` directory, these documents provide a deep dive into the **source code, architectural decisions, script lifecycle, and configuration variables** that power the orchestration engine.

## Documentation Structure

The Developer Reference is divided into four main pillars:

### 1. [Library Reference](LIBRARY_REFERENCE.md)

Detailed documentation of `lib/common_utils.sh`, the core Bash framework powering the entire deployment system. This includes function signatures, error handling mechanisms, and sysadmin safety nets (e.g., non-interactive modes, pipeline preservation).

### 2. [Scripts Reference](SCRIPTS_REFERENCE.md)

A breakdown of the deployment orchestration (`scripts/*.sh`). This covers the numeric execution order, the idempotency model, and the exact roles of each script from domain joining to telemetry setup.

### 3. [Configuration Reference](CONFIGURATION_REFERENCE.md)

An exhaustive dictionary of all variables injested from the `config/` directory (e.g., `setup_nodes.vars.conf`, `r_env_manager.conf`). It explains what each variable controls and their operational constraints.

### 4. [Templates Reference](TEMPLATES_REFERENCE.md)

Documentation of the templating engine. Explains how the `__process_template` function injects environmental variables into Systemd units, Nginx configs, Bash cronjobs, and JSON preferences without breaking syntax.

---

## Core Engineering Principles

If you are modifying this codebase, you must adhere to the following principles established by the senior sysadmin architects:

1. **Idempotency**: Every script (`scripts/*.sh`) must be safe to run multiple times without corrupting the state or duplicating configuration blocks.
2. **Defensive Bash**: All orchestration must use `run_command` from `common_utils.sh` to guarantee timeouts, logging, and retry logic. Never use raw `apt-get` or `systemctl` in the main flow.
3. **No Interactive Prompts**: The entire suite is designed for "zero-touch" deployment. All `apt`/`dpkg` calls must strictly export `DEBIAN_FRONTEND=noninteractive`.
4. **Secure Execution (No `eval`)**: Dynamic payloads for R or Bash must be constructed using isolated, randomized `mktemp` files and Heredoc injection (`<<EOF`). String interpolation into `eval()` is strictly forbidden to prevent RCE.
5. **Least Privilege**: Services (Nginx, TTYD, Backends) run with minimal permissions. Scripts interacting with user homes must preserve enterprise POSIX and NFSv4 ACLs (using structured `su -c` or `chown` rather than destructive recursive `chmod`).
