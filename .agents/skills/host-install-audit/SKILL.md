---
name: host-install-audit
description: Validates host-tier (T1) bash scripts, lib, templates and configs against R-studioConf invariants. Use when creating, modifying, or reviewing any file under scripts/, lib/, templates/, config/, or the root orchestrators (init.sh, r_env_manager.sh). T1 is the AUTHORITATIVE tier — fixes start here, then port forward to T2/T3.
---

# Host-Install Audit Skill (Tier T1)

T1 is the **authoritative & continuously-fixed** deployment tier. Stability is achieved by *fixing bugs here first*, not by freezing files. Any T1 file (scripts, lib, templates including `Rprofile_site.d/`, configs) is in scope for fixes — but every fix must respect the invariants below and then be ported forward to T2/T3 (or recorded in `.ai/project.yml → tier_deltas`).

## Authoritative chain

```
init.sh ──► r_env_manager.sh ──► scripts/NN_*.sh
                │                      │
                │                      └── sources lib/common_utils.sh
                │                      └── reads config/*.vars.conf
                │                      └── renders templates/*.template
                └── lockfile /var/run/, log /var/log/biome-log/core/, state /var/lib/r_env_manager
```

## Numbered-script ordering (do NOT renumber casually)

```
01_optimize_system        ── sysctl/Proxmox tuning
02_configure_time_sync    ── chrony/NTP
03_install_secure_access  ── SSH hardening / fail2ban
10_join_domain_sssd       ┐
11_join_domain_samba      ┴── XOR (pick one; never both)
12_lib_kerberos_setup     ── Kerberos keytabs
13_harden_pam_password    ── PAM hardening
15_setup_nginx_cleanup    ── pre-install nginx port/socket cleanup
20_configure_rstudio      ── RStudio Server config
21_helper_rstudio_version ── version probe
30_install_nginx          ── reverse proxy
31_optimize_system        ── post-install perf
31_setup_web_portal       ── glassmorphism portal UI
32_setup_letsencrypt      ── ACME / Let's Encrypt
40_install_telemetry      ── metrics API
50_setup_nodes            ── BIOME-CALC: BLAS, /Rtmp, Rprofile.site, R packages
99_*                      ── diagnostics (audit, health, postmortem, troubleshoot, drift, lussu)
```

## Checklist (verify EVERY item for EVERY T1 file you touch)

1. **HC-03 strict mode:** Line 1 `#!/usr/bin/env bash` (or `#!/bin/bash`); next non-comment line `set -euo pipefail`. Color vars present (`GREEN/RED/YELLOW/NC`).
2. **lib/common_utils.sh contract:** sourced at top of every numbered script; do not duplicate functions it already provides (`check_root`, `check_dependencies`, `check_bash_version`, colored logging, `process_template`, `run_command`, `setup_noninteractive_mode`).
3. **r_env_manager.sh contract:** lockfile at `/var/run/`, log at `/var/log/biome-log/core/`, state at `/var/lib/r_env_manager`; never bypass it for new menu actions — extend it.
4. **HC-04 secrets:** passwords written to files; `kinit` reads keytabs, never CLI args.
5. **HC-10 chown failure:** `chown … || { error "…"; exit 1; }` — never silent.
6. **HC-12 JSON:** use `jq`; never `sed`/`awk` on JSON.
7. **Templates → /etc placement:** `templates/Rprofile_site.R.template` → `/etc/R/Rprofile.site`; `templates/Rprofile_site.d/*.R.template` → `/etc/biome-calc/profile.d/`. Modular ordering (05/45/50/55/60) preserved.
8. **R runtime invariants:**
   - BLAS = `libopenblas0-serial` (NEVER pthread; SIGSEGV).
   - Large R temp = `/Rtmp` (400GB ext4) — NEVER `/tmp`.
   - `Renviron.template` and audit template (`00_audit_v28.R.template`) consistent with profile.d ordering.
9. **AD integration XOR:** never run both `10_join_domain_sssd.sh` and `11_join_domain_samba.sh` on the same host.
10. **Idempotency:** every script must be safe to re-run. Use `if … not yet …` guards; never destructive without `--force` flag.
11. **Vars conf:** `config/*.vars.conf` keys exhaustively documented at top of file; default values pessimistic.
12. **Tier-promotion:** if the fix exists in `docker-deploy/scripts/` or `kubernetes-deploy/`, ensure parity is preserved or record a `tier_deltas` entry.
13. **R/RStudio Version Alignment:** Scripts MUST respect the dynamically configured stable R/RStudio versions defined in `config/r_env_manager.conf` and `kubernetes-deploy/configmaps.yaml`. Prevent runtime installations of different versions.
    - **Rationale:** Ensures consistent R/RStudio versions across all deployment tiers and AI configurations by enforcing dynamic mapping to canonical configuration files. Prevents implicit overrides that could lead to version drift and silent failures.
14. **R/RStudio Version Alignment:** Scripts MUST respect the dynamically configured stable R/RStudio versions defined in `config/r_env_manager.conf` and `kubernetes-deploy/configmaps.yaml`. Prevent runtime installations of different versions.
    - **Rationale:** Ensures consistent R/RStudio versions across all deployment tiers and AI configurations by enforcing dynamic mapping to canonical configuration files. Prevents implicit overrides that could lead to version drift and silent failures.

## HC-14 (User-Script Boundary) — special care

1. **R/RStudio Version Alignment:** Scripts MUST respect the dynamically configured stable R/RStudio versions defined in `config/r_env_manager.conf` and `kubernetes-deploy/configmaps.yaml`. Prevent runtime installations of different versions.
    - **Rationale:** Ensures consistent R/RStudio versions across all deployment tiers and AI configurations by enforcing dynamic mapping to canonical configuration files. Prevents implicit overrides that could lead to version drift and silent failures.
2. **R/RStudio Version Alignment:** Scripts MUST respect the dynamically configured stable R/RStudio versions defined in `config/r_env_manager.conf` and `kubernetes-deploy/configmaps.yaml`. Prevent runtime installations of different versions.
    - **Rationale:** Ensures consistent R/RStudio versions across all deployment tiers and AI configurations by enforcing dynamic mapping to canonical configuration files. Prevents implicit overrides that could lead to version drift and silent failures.
3. **R/RStudio Version Alignment:** Scripts MUST respect the dynamically configured stable R/RStudio versions defined in `config/r_env_manager.conf` and `kubernetes-deploy/configmaps.yaml`. Prevent runtime installations of different versions.
    - **Rationale:** Ensures consistent R/RStudio versions across all deployment tiers and AI configurations by enforcing dynamic mapping to canonical configuration files. Prevents implicit overrides that could lead to version drift and silent failures.

## HC-14 (User-Script Boundary) — special care

1. **R/RStudio Version Alignment:** Scripts MUST respect the dynamically configured stable R/RStudio versions defined in `config/r_env_manager.conf` and `kubernetes-deploy/configmaps.yaml`. Prevent runtime installations of different versions.
    - **Rationale:** Ensures consistent R/RStudio versions across all deployment tiers and AI configurations by enforcing dynamic mapping to canonical configuration files. Prevents implicit overrides that could lead to version drift and silent failures.
2. **R/RStudio Version Alignment:** Scripts MUST respect the dynamically configured stable R/RStudio versions defined in `config/r_env_manager.conf` and `kubernetes-deploy/configmaps.yaml`. Prevent runtime installations of different versions.
    - **Rationale:** Ensures consistent R/RStudio versions across all deployment tiers and AI configurations by enforcing dynamic mapping to canonical configuration files. Prevents implicit overrides that could lead to version drift and silent failures.
3. **R/RStudio Version Alignment:** Scripts MUST respect the dynamically configured stable R/RStudio versions defined in `config/r_env_manager.conf` and `kubernetes-deploy/configmaps.yaml`. Prevent runtime installations of different versions.
    - **Rationale:** Ensures consistent R/RStudio versions across all deployment tiers and AI configurations by enforcing dynamic mapping to canonical configuration files. Prevents implicit overrides that could lead to version drift and silent failures.

## HC-14 (User-Script Boundary) — special care

T1 hosts the diagnostic harnesses (`99_diagnose_user_script.sh`, `99_diagnose_lussu_hang.sh`, `r_minimal.sh`). Never silently rewrite a user `.R` file. Verdict line is mandatory. See `.ai/agents.md §6.6`.

## Output Format

```
[PASS/FAIL/WARN] T1 <file>:<line> — <invariant id> — description
  → Fix: specific instruction
  → Tier impact: needs port to T2? T3? (or record in project.yml → tier_deltas)
```

## Reference Files

- `.ai/project.yml` — `deployment_tiers.T1_host`, `engineering_ethos`, all HC-NN
- `.ai/agents.md` — full architecture (§5 script chain, §6 R runtime hardening)
- `lib/common_utils.sh` — shared API (read first 80 lines before adding helpers)
- `r_env_manager.sh` — orchestrator menu structure
