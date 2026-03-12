# Claude Agent Instructions — Infra-IAM-PKI

> **Purpose:** Optimized context file for Claude (Anthropic) when working on this codebase.
> **Usage:** Include this file in your Claude Project Knowledge or paste at conversation start.
> **Prerequisite:** Read `agents.md` first — this file supplements, not replaces, the universal context.

---

## Claude-Specific Behavioral Directives

### Thinking & Reasoning

Claude excels at step-by-step reasoning. For this project, ALWAYS use chain-of-thought before producing any code:

1. **Identify the subsystem** (PKI / IAM / OOD / Scripts / Sandbox / K8s).
2. **List the invariants** from `agents.md` Section 4 that apply.
3. **Check the anti-patterns** from Section 5 — actively scan your output for violations.
4. **Verify the boot sequence** — understand which containers depend on which.
5. **Only then** produce the code/config.

### Response Format Preferences

- **Shell scripts:** Always output the complete file with shebang and `set -euo pipefail`. Never produce partial snippets without context about where they go.
- **Docker Compose:** Output full service blocks, not fragments. Include the `deploy`, `healthcheck`, `logging`, `labels`, and `depends_on` sections — they are mandatory, not optional.
- **When editing existing files:** Show the exact `old → new` diff. Reference the file path from repo root.
- **Documentation:** Use Markdown with GitHub-compatible admonitions (`> [!WARNING]`).

### Tool Usage

When using Claude's computer/file tools:
- Read the target file BEFORE editing it.
- Use `str_replace` for surgical edits, not full file rewrites.
- Validate compose files with `docker compose config` after editing.
- For shell scripts, check with `bash -n script.sh` (syntax check).

---

## Structured Context Block

Use this XML-structured context when working with Claude API or Claude Projects:

```xml
<project_context>
  <name>Infra-IAM-PKI</name>
  <version>2.0.0</version>
  <owner>JFS — IT Officer, BiGeA, Università di Bologna</owner>
  
  <architecture>
    <paradigm>Pessimistic System Engineering</paradigm>
    <deployment>Multi-host Docker Compose (production) + Vagrant/libvirt sandbox</deployment>
    <future>RKE2 Kubernetes migration path exists in kubernetes-deploy/</future>
  </architecture>
  
  <components>
    <component name="infra-pki" role="Certificate Authority">
      <tech>step-ca 0.29.0 + PostgreSQL 15 + Caddy L4</tech>
      <network>pki-net (isolated Docker bridge)</network>
      <ports>9000 (CA API via Caddy), 80 (public certs/fingerprint)</ports>
    </component>
    <component name="infra-iam" role="Identity Provider">
      <tech>Keycloak 26.0.7 + PostgreSQL 15 + Caddy L7</tech>
      <network>iam-net (isolated Docker bridge)</network>
      <ports>80/443 (Caddy → Keycloak)</ports>
      <integrations>Active Directory LDAPS, Internal PKI for TLS</integrations>
    </component>
    <component name="infra-ood" role="HPC Portal">
      <tech>Open OnDemand 4.1 (Ubuntu Noble 24.04) + Apache mod_auth_openidc</tech>
      <network>ood-net (isolated Docker bridge)</network>
      <ports>80 (Apache → PUN → RStudio containers)</ports>
      <integrations>Keycloak OIDC, Internal PKI for trust</integrations>
    </component>
  </components>
  
  <hard_constraints>
    <constraint id="HC-01">Every container MUST have deploy.resources.limits (memory + cpus)</constraint>
    <constraint id="HC-02">BIND MOUNTS only — zero named Docker volumes</constraint>
    <constraint id="HC-03">Scripts MUST use set -euo pipefail</constraint>
    <constraint id="HC-04">Passwords written to files only — never CLI args</constraint>
    <constraint id="HC-05">PostgreSQL ports NEVER exposed to host</constraint>
    <constraint id="HC-06">No runtime package installation — bake in Dockerfile</constraint>
    <constraint id="HC-07">Pin all image versions — no :latest</constraint>
    <constraint id="HC-08">.env files NEVER committed to git</constraint>
    <constraint id="HC-09">docker-socket-proxy for container restart — never mount docker.sock directly</constraint>
    <constraint id="HC-10">Deploy scripts exit 1 if chown fails</constraint>
    <constraint id="HC-11">No external CDN calls in UI themes — airgap compatible</constraint>
    <constraint id="HC-12">URL-encode PG credentials via jq in patch_ca_config.sh</constraint>
  </hard_constraints>
  
  <image_versions>
    <image name="step-ca" version="0.29.0" />
    <image name="step-cli" version="0.29.0" />
    <image name="postgres" version="15-alpine" />
    <image name="keycloak" version="26.0.7" registry="quay.io/keycloak" />
    <image name="caddy" version="2.9.1-alpine" />
    <image name="watchtower" version="1.7.1" registry="containrrr" />
    <image name="docker-socket-proxy" version="edge" registry="tecnativa" />
    <image name="ondemand" version="4.1.0" source="apt.osc.edu (deb, not Docker Hub)" />
  </image_versions>
  
  <known_bugs>
    <bug id="P0" component="infra-iam">Keycloak JAVA_OPTS Xmx4096m exceeds container limit 2048M → OOM</bug>
    <bug id="P1" component="infra-iam">renewer restarts Keycloak on every 24h cycle, not only on actual renewal</bug>
    <bug id="P1" component="infra-iam">.env mounted into init container leaks all secrets</bug>
    <bug id="P2" component="infra-pki">fingerprint path inconsistency between writer and deploy script</bug>
  </known_bugs>
</project_context>
```

---

## Task-Specific Prompt Templates

### Template 1: Modifying a Docker Compose Service

```
I need to modify the {service_name} service in {stack}/docker-compose.yml.

Change requested: {description}

Before you write any code:
1. Confirm you've identified all invariants from agents.md Section 4 that apply.
2. List any containers that depend on this service (check depends_on chains).
3. Verify the change doesn't break the boot sequence (agents.md Section 6).
4. Show the exact diff (old → new) for the compose file.
5. If the change affects .env, show the new/modified variables.
6. If the change affects scripts, show those changes too.
```

### Template 2: Writing a New Script

```
Create a new script: scripts/{path}/{name}.sh

Purpose: {description}

Requirements:
- Follow the coding standards in agents.md Section 8.1
- Use the same color scheme (GREEN/RED/BLUE/YELLOW/NC) as existing scripts
- Include input validation and meaningful error messages
- Add --help flag support
- If destructive, require explicit confirmation
- Test against the sandbox environment (192.168.56.x topology)
```

### Template 3: Debugging a Container Issue

```
Container {name} is {symptom}.

Stack: {pki|iam|ood}
Environment: {production|sandbox}

Before suggesting fixes:
1. Check agents.md Section 9 for the relevant .env variables
2. Review the boot sequence in Section 6 for dependency ordering
3. Check the known issues in Section 7 — this might be documented
4. Consider both the container's own logs AND its dependency chain
5. Propose diagnostic commands first, then fixes
```

### Template 4: Security Audit Review

```
Review the following file for security issues against the project's Pessimistic System Engineering constraints:

{file_content}

Check against ALL constraints in agents.md Section 4, with special attention to:
- Secret handling (no CLI args, no env leaks)
- Resource limits presence
- Network exposure
- Permission escalation vectors
- Immutability violations (runtime package installs)
- Trust chain integrity (fingerprint verification)
```

---

## Claude-Specific Pitfall Awareness

Claude sometimes makes these mistakes on this specific codebase:

### 1. Suggesting `docker secrets` (Swarm-mode feature)
This project uses standalone Docker Compose, NOT Docker Swarm. `docker secrets` don't work here. Use file-based secrets with bind mounts.

### 2. Recommending `environment_file` over `env_file`
Both work but the project consistently uses `env_file:` syntax. Don't introduce `environment_file:`.

### 3. Over-engineering with Docker multi-stage builds
The Dockerfiles here are intentionally simple (single-stage). step-cli and step-ca images are used directly. Only Caddy has a multi-stage build (builder pattern for the L4 plugin).

### 4. Adding `version: "3.x"` to compose files
Compose v2 doesn't need the `version` key. The project omits it intentionally.

### 5. Using `docker-compose` (hyphenated) instead of `docker compose` (space)
The project targets Docker Compose v2 plugin syntax (`docker compose`), not the legacy standalone binary.

### 6. Suggesting Traefik or Nginx instead of Caddy
Caddy is the chosen reverse proxy for both L4 (PKI) and L7 (IAM). Do not suggest replacing it unless explicitly asked.

### 7. Recommending `init: true` in compose
The project uses explicit init containers instead of Docker's `init:` flag. The init containers do more than PID 1 reaping — they handle permissions, cert fetching, and directory creation.

### 8. Forgetting the Docker bridge CIDR in ALLOWED_IPS
When health checks or deploy scripts run from the host, they route through the Docker bridge gateway. If `172.18.0.0/16` (or equivalent) is not in `ALLOWED_IPS`, Caddy L4 blocks the connection silently.

### 9. Editing a script without checking its callers
Scripts have hidden coupling. See `agents.md` Section 7.1 for the dependency graph. For example, modifying the output format of `generate_token.sh` will break `configure_iam_pki.sh` which parses its output file with `grep + cut`.

### 10. Treating the sandbox as a simplified mock
The sandbox uses the **real production compose** for PKI and builds OOD from the **real Dockerfile.ood**. Only IAM has a dedicated sandbox compose. Changes to production compose files directly affect sandbox behavior. See `agents.md` Section 8.3 for the exact differences.

---

## Scripts-Specific Guidance for Claude

When working on scripts, Claude must follow these rules:

### Script Modification Protocol

1. **Before editing:** Read the script AND check `agents.md` Section 7.2-7.5 to understand what calls it and what it calls.
2. **Input/output contract:** Never change what a script reads or produces without updating all callers/consumers.
3. **Config reading pattern:** The project uses `grep "^VAR=" .env | cut -d= -f2- | tr -d '"'` — never `source .env` in production (unsafe with special chars). Maintain this pattern.
4. **Path resolution:** Always use `SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"` and build relative paths from there. Never use `pwd` or hardcoded absolute paths.
5. **Interactive vs non-interactive:** Scripts that run inside containers (init_step_ca.sh, patch_ca_config.sh, fetch_pki_root.sh, renew_certificate.sh) must NEVER use `read -p` or any interactive input. Scripts run by operators (deploy_*.sh, configure_*.sh, reset_*.sh) CAN be interactive.

### Sandbox-Specific Guidance for Claude

When working on sandbox files:

1. **Never modify the Vagrantfile** without understanding all three VM provisioners. They share a common Docker install block but have host-specific logic.
2. **The rsync excludes matter:** `.git/`, `sandbox/.vagrant/`, `step_data/`, `db_data/`, `logs/` are excluded from rsync. If you add a new data directory, it probably needs to be in this exclude list too.
3. **Sandbox compose files live in `sandbox/`**, not alongside production compose. Don't confuse `infra-iam/docker-compose.yml` (production) with `sandbox/iam-sandbox.yml` (sandbox).
4. **The fingerprint retry loop** in the Vagrantfile is critical. If you change how/where PKI serves the fingerprint, you break the IAM and OOD VM provisioning.
5. **`full_sandbox_launcher.sh` is broken** (TD-09). Don't reference it or try to fix it unless explicitly asked.

---

## Artifact Guidelines

When creating artifacts (React components, HTML, diagrams) for this project:

- **Architecture diagrams:** Use Mermaid syntax (the docs already use it)
- **Status dashboards:** React artifacts with the Unibo Red palette (`#C80E0F`, `#9A0B0B`, `#2C3E50`)
- **Config generators:** HTML forms that produce `.env` file content for download
- **Never hardcode secrets** in any artifact — use placeholder values

---

## Memory Anchors

Key facts Claude should retain across conversation turns:

- **step-ca version: 0.29.0** (not 0.25.2 — that's the outdated K8s manifest)
- **Keycloak version: 26.0.7** (not 23.0 — that's the outdated K8s manifest)
- **OOD source: Ubuntu Noble 24.04 deb from apt.osc.edu** (NOT Docker Hub `osc/ondemand` — that image doesn't exist)
- **Caddy L4 = TCP proxy for PKI (port 9000)** / **Caddy L7 = HTTP reverse proxy for IAM**
- **Sandbox IPs:** PKI=192.168.56.10, IAM=192.168.56.20, OOD=192.168.56.30
- **The custom Keycloak theme is FreeMarker (.ftl)** — not Thymeleaf, not JSP
- **Active Directory LDAPS endpoint:** port 636, cert chain fetched by `fetch_ad_cert.sh`
- **Fingerprint is served at HTTP :80 `/fingerprint/root_ca.fingerprint`** — NOT HTTPS
- **The `configurator` container is intentionally ephemeral** — it exits after provisioner setup. Exit code 0 = success.

---

*End of Claude-specific instructions. Always cross-reference with agents.md for the complete picture.*
