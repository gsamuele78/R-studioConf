# RStudio Server OSS: Session Isolation & Multi-Node Limitations

**Document Version:** 1.0
**Date:** 2026-06-04
**Audience:** System Administrators, Power Users
**Status:** Documented Limitation — No Fix Planned

---

## Executive Summary

RStudio Server Open Source (OSS) **does not support multiple simultaneous R sessions for the same user**. This is a fundamental architectural limitation of the open-source version, not a configuration issue or bug. When a user attempts to open a second RStudio session (from a different browser, tab, or node), the first session is disconnected.

This document explains:

1. Why this limitation exists
2. What was investigated to work around it
3. What the multi-node architecture is actually designed for
4. What alternatives exist

---

## 1. The Limitation

### 1.1 Observed Behavior

When a user logs into RStudio Server OSS on `biome-calc01`, then attempts to log in again on `biome-calc02` with the same credentials, one of two things happens:

- **The first session is disconnected** with the message: *"This browser was disconnected from the R session because another browser connected (only one browser at a time may be connected to an RStudio session)."*
- **Both sessions appear to share the same R environment**, because RStudio OSS reuses the existing `rsession` process rather than spawning a new one.

### 1.2 Root Cause

RStudio Server OSS is designed to manage **one rsession process per user**. The `rserver` daemon tracks active sessions by user identity (UID). When a new connection arrives for a user who already has an active session:

1. `rserver` detects the existing `rsession` process for that UID.
2. It terminates the old browser connection.
3. It binds the new browser connection to the existing `rsession` process.

This is **by design** in the open-source version. The commercial **Posit Workbench** (formerly RStudio Server Professional) supports multiple concurrent sessions per user via the `server-multiple-sessions=1` configuration option, which does not exist in OSS.

### 1.3 Official Documentation

From the RStudio Server Pro Administrator's Guide (v0.99.902):

> *"RStudio Server Professional enables users to have multiple concurrent R sessions on a single server or load balanced cluster of servers (**the open-source version of RStudio Server supports only a single session at a time**)."*

Source: [RStudio Server Pro Admin Guide, §5.3 Multiple R Sessions](https://s3.amazonaws.com/rstudio-server/rstudio-server-pro-0.99.902-admin-guide.pdf)

---

## 2. Investigation History

### 2.1 What Was Tested

| Approach | Method | Result |
|----------|--------|--------|
| **rsession-profile XDG injection** | Export `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `XDG_STATE_HOME`, `XDG_CACHE_HOME` in `/etc/rstudio/rsession-profile` | **Failed** — R session did not pick up variables; RStudio continued writing to `~/.config/rstudio` and `~/.local/share/rstudio` |
| **Login script XDG injection** | Export node-scoped XDG variables in `/etc/profile.d/00_rstudio_user_logins.sh` | **Failed** — Variables visible in shell `env` but `Sys.getenv()` inside R returned empty strings; RStudio state remained in shared paths |
| **rsession.conf configuration** | Searched for `session-default-working-dir`, `session-default-new-project-dir`, and other state-directory options | **No relevant options found** — `rsession.conf` controls session behavior (timeouts, save actions) but not state directory paths |
| **rserver.conf configuration** | Searched for `server-shared-storage-path` and other path options | **Not applicable** — `server-shared-storage-path` is for shared project storage in Pro, not session state isolation |

### 2.2 Why XDG Environment Variables Don't Work

RStudio Server OSS launches `rsession` processes in a way that does **not** inherit environment variables from shell profile scripts (`/etc/profile.d/`, `~/.bash_profile`, etc.) for the purpose of determining its state directories. The state paths (`~/.config/rstudio`, `~/.local/share/rstudio`) appear to be **hardcoded** or determined by the RStudio C++ codebase at compile time, not by runtime environment variables.

This is consistent with reports from other RStudio Server OSS deployments (see [Posit Community thread](https://forum.posit.co/t/on-linux-how-to-configure-rstudio-server-to-set-the-location-of-local-and-other-user-related-directories/107960)).

### 2.3 Test Artifacts

The test template used during investigation is preserved at:

- `templates/rstudio_user_login_script.sh.template.test`

This file should be removed after documentation is complete.

---

## 3. What the Multi-Node Architecture IS Designed For

### 3.1 Correct Use Case: Multi-User Scalability

The BIOME-CALC cluster has multiple compute nodes (`biome-calc01`, `biome-calc02`, …) to distribute **different users** across available hardware:

```
User A → biome-calc01 (RStudio session)
User B → biome-calc02 (RStudio session)
User C → biome-calc01 (RStudio session)
```

Each user gets one active RStudio session on one node. The load balancer (Nginx portal) distributes users across nodes based on availability.

### 3.2 Correct Use Case: Shared NAS for Data Accessibility

The NFS-mounted home directories (`/nfs/home/<user>`) ensure that:

- A user's files, scripts, and data are accessible from **any node** they connect to.
- Users don't need to copy or reload large datasets when switching nodes (e.g., after a node reboot or maintenance).
- R package libraries (`~/R/x86_64-pc-linux-gnu-library/`) are consistent across nodes.

### 3.3 What the Architecture Does NOT Support

- ❌ One user with two simultaneous RStudio sessions on two different nodes.
- ❌ One user with two simultaneous RStudio sessions on the same node (different browser tabs).
- ❌ "Session roaming" — moving an active session from one node to another without disconnecting.

---

## 4. Alternatives and Workarounds

### 4.1 For Users Who Need Multiple R Environments

| Approach | Description | Trade-offs |
|----------|-------------|------------|
| **RStudio Background Jobs** | Use the Jobs pane in RStudio to run scripts in background R sessions | Limited to script execution, not interactive |
| **`biome_make_cluster()`** | Parallelize within a single R session using multiple cores | Same R process, shared memory space |
| **TTYD Terminal + `tmux`** | Open a terminal via the portal, use `tmux` to manage multiple R sessions via `Rscript` | No RStudio IDE features (syntax highlighting, environment pane) |
| **RStudio Desktop (local)** | Install RStudio Desktop on your laptop for a second environment | Requires local R installation; data must be transferred |
| **Posit Workbench (commercial)** | Upgrade to the commercial version for native multi-session support | Requires licensing; not currently planned |

### 4.2 For Administrators

If multi-session-per-user becomes a hard requirement, the options are:

1. **Upgrade to Posit Workbench** — the commercial version supports `server-multiple-sessions=1` and per-session state isolation natively.
2. **Container-based isolation** — run separate RStudio Server OSS instances in containers (Docker/Singularity) with unique `/tmp` and state directories per instance. This is complex and not currently implemented.
3. **Alternative IDEs** — evaluate whether Positron (Posit's next-generation IDE) or VS Code with R extensions supports the required multi-session workflow.

---

## 5. References

- [RStudio Server Pro Administrator's Guide — Multiple R Sessions](https://s3.amazonaws.com/rstudio-server/rstudio-server-pro-0.99.902-admin-guide.pdf)
- [Posit Community: Configuring XDG_DATA_HOME for RStudio Server](https://forum.posit.co/t/on-linux-how-to-configure-rstudio-server-to-set-the-location-of-local-and-other-user-related-directories/107960)
- [Open OnDemand: Multiple RStudio Server Sessions](https://discourse.openondemand.org/t/is-it-possible-to-have-multiple-rstudio-server-sessions-on-the-same-server/526)
- [OSC/bc_osc_rstudio_server: Issue #1 — Unable to run multiple sessions](https://github.com/OSC/bc_osc_rstudio_server/issues/1)
- [Stack Overflow: Multiple simultaneous sessions of RStudio in Linux](https://stackoverflow.com/questions/56444182/multiple-simultaneous-sessions-of-r-studio-in-linux-environment)

---

## 6. Changelog

| Date | Version | Change |
|------|---------|--------|
| 2026-06-04 | 1.0 | Initial document: documented limitation, investigation history, architecture clarification |
