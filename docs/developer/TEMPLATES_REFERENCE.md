# Templates Reference: Dynamic Configuration Engine

The `templates/` directory is central to the idempotency and security model of the BIOME portal. Instead of manipulating configuration files via raw `echo`, `sed`, or `cat <<EOF` in the main deployment scripts, the system relies on a unified templating engine.

## 1. The Template Engine (`__process_template`)

Located in `lib/common_utils.sh`, the `__process_template` function performs safe, deterministic string substitution on `.template` files.

### Security Benefits over `envsubst`

While `envsubst` is common, it blindly evaluates any string matching `$VAR` or `${VAR}`. If user input or an unpredictable file path contains a bash variable syntax, `envsubst` corrupts it.

Our engine explicitly accepts a list of variable names as arguments:

```bash
__process_template "nginx.conf.template" "nginx.conf" "NGINX_PORT" "SSL_CERT"
```

It dynamically constructs a surgical `sed` regex strictly for the placeholder syntax `%%VAR_NAME%%`:
`s|%%NGINX_PORT%%|443|g`

By using the pipe character `|` as the `sed` delimiter, it flawlessly injects paths containing forward slashes `/` across web and system configuration files.

---

## 2. Core Templates Dictionary

Templates are divided by their target subsystem.

### 2.1 Web & Gateway (`nginx_proxy_location.conf.template`)

* **Purpose**: The central routing logic for Nginx.
* **Injects**:
  * `%%DOMAIN_NAME%%` for virtual host binding.
  * Timeout properties (`proxy_read_timeout`) derived directly from RStudio's session configurations.
  * Path mapping configurations for RStudio (`/rstudio-inner/`), Nextcloud (`/files-inner/`), and TTYD (`/terminal-inner/`).
* **Sysadmin Detail**: Features the massive JSON RPC buffer inflations (`proxy_buffer_size`) necessary to parse nested datatables sent by the statistical backend without triggering a `502 Bad Gateway`.

### 2.2 Orchestration Automation

Templates that compile into automated cronjobs or event-driven hook scripts.

#### `unibo_archive_manager.sh.template`

* **Purpose**: Nightly cleanup. Analyzes AD groupings and Active Directory metadata to transfer orphaned or concluding project directories from `/nfs/home` to the CIFS CIFS storage `ProjectStorage` tier.
* **Injects**: Active Directory group prefixes, Target mount points, CSV manifest paths.
* **Security Detail**: Before migrating a user, uses isolated `su -s /bin/bash` with a dotfile `.biome_access_check` to prove Posix write capability by the AD identity, bypassing root permission masking errors.

#### `cleanup_r_orphans.sh.template`

* **Purpose**: The OOM/Zombie hunter. Kills R/Java processes consuming CPU that lack a valid parent (like `rsession`).
* **Injects**: Maximum allowed execution hours via CPU Time (`%%MAX_CPU_HOURS%%`), administrative sender emails (`%%SENDER_EMAIL%%`), and SMTP endpoints.
* **Security Detail**: Executes a safe kill ladder: `SIGTERM` -> Grace Wait -> `SIGKILL`, ensuring buffers (like NetCDF files) have time to sync to NFS before terminal thread destruction.

### 2.3 User Preferences & UI

#### `rstudio_user_login_script.sh.template`

* **Purpose**: Bootstraps individual AD users when they enter the portal for the first time.
* **Mechanism**: Since AD groups manage access but not necessarily UI preferences, this script is sourced at login. It utilizes `jq` to non-destructively merge corporate standards (Theme, Auto-save behaviors, R paths) into the user's `~/.config/rstudio/rstudio-prefs.json`.
* **Injects**: Default Python paths (`%%DEFAULT_PYTHON_PATH_LOGIN_SCRIPT%%`) and Global root prefixes.

#### `portal_index.html.template` (Inside `assets/`)

* **Purpose**: The static HTML modal gateway.
* **Mechanism**: Nginx serves the final HTML. The build script injects dynamic routing identifiers (e.g., distinguishing between a Master Node deployment vs. an Edge Node deployment) into the window DOM to direct API fetch calls to the appropriate Dockerized subsystem.

### 2.4 Subsystems & API

#### `telemetry_api.service.template`

* **Purpose**: Converts the FastAPI Python application into a resilient, background `systemd` target.
* **Injects**: Thread counts, uvicorn execution paths, and virtual environment bindings.
* **Security Detail**: Implements `MemoryMax=%%RAM_LIMIT%%` and `RestartSec` to guarantee the hypervisor never crashes if a poorly nested JSON payload OOMs the telemetry worker pool.
