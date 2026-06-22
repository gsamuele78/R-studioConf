# Library Reference: `common_utils.sh`

The `lib/common_utils.sh` file is the architectural backbone of the entire deployment suite. It is a Bash library sourced by almost every script in the repository. It enforces safety, logging, idempotency, and robust error handling.

## 1. Core Philosophy

The library is designed with a **Defensive Sysadmin approach**:

- **Visibility**: Everything is logged with timestamps and severity levels.
- **Resilience**: Network calls or package manager locks (`dpkg`) are wrapped in retry loops with exponential backoff and hard timeouts.
- **Safety**: Interactive prompts are aggressively suppressed to prevent deployment hangs.

---

## 2. Global Variables

When sourced, the library exposes several critical global variables to the calling context:

- `DEFAULT_LOG_FILE`: The fallback log file if the caller doesn't specify one.
- `DEFAULT_MAX_RETRIES` (Default: 3): Standard retry limit for failing commands.
- `DEFAULT_TIMEOUT` (Default: 120s): Standard execution timeout.
- `VERBOSE` (Default: false): Triggers high-verbosity output in `run_command`.

---

## 3. Function Dictionary

### 3.1 Logging Subsystem

The logging functions ensure consistent, parsable output to both `stdout` and the designated log file.

#### `log_message()`, `log_info()`, `log_warn()`, `log_error()`, `log_success()`

* **Signature**: `log_level "Message String"`
- **Behavior**: Prepends an ISO-8601 timestamp and severity tag (`[INFO]`, `[ERROR]`, etc.). `log_error` outputs to `stderr`.
- **Note**: Colors are automatically stripped when writing to the plaintext log file to maintain clean `.log` syntax.

---

### 3.2 The Execution Engine: `run_command()`

This is the most critical function in the repository. **Raw execution of system commands is strongly discouraged; use this wrapper instead.**

- **Signature**: `run_command "Display Name" "command string" [max_retries] [timeout]`
- **Example**: `run_command "Install htop" "apt-get install -y htop" 3 60`
- **Features**:
  1. **Subshell Execution**: The command runs in `bash -c` to isolate its environment.
  2. **Timeout Enforcement**: The command is executed via `timeout ${TIMEOUT}s bash -c ...`. This prevents zombie APT processes from holding locks forever if a repository hangs.
  3. **Pipeline Preservation**: Critically, the execution routes standard input (`< /dev/null`) to prevent commands (like `ssh` or certain `apt` prompts) from swallowing the caller's `while read` loops.
  4. **Output Capture**: Output is captured to a temporary file. On success, it's silently logged. On failure, the exact error output is dumped to the screen to aid debugging.
  5. **Dpkg Sanitization**: If the command contains `apt`, `apt-get`, or `dpkg`, the function automatically injects extreme non-interactive flags (e.g., `-o Dpkg::Options::="--force-confdef"`) into the subshell environment.
  6. **Exit-code fidelity & `pipefail` safety** (T1 audit §1): a failed command — including any part of a composite `apt-get update && apt-get install …` — propagates its real non-zero exit code to the caller (it is never masked as success). `run_command` is a thin wrapper that **saves and restores the caller's `pipefail` option**, so the internal `pipefail` toggling it needs to read `PIPESTATUS` of `cmd | tee` never leaks into the sourcing script. The implementation lives in `__run_command_impl`; call `run_command` (the wrapper), never the impl directly.

---

### 3.3 System Hardening & Setup

#### `setup_noninteractive_mode()`

* **Purpose**: Prepares the OS environment for automated provisioning.
- **Mechanism**:
  - Exports `DEBIAN_FRONTEND=noninteractive`.
  - Disables `man-db` auto-updates (which take minutes during `apt` installs) by modifying apt configuration or safely moving the `update-mandb` script.
  - Masks `systemd-journald` if necessary during heavy I/O to prevent logging bottlenecks.

---

### 3.4 Idempotency & Backup Tools

#### `backup_file()`

* **Signature**: `backup_file "/path/to/file"`
- **Behavior**: Safely copies a configuration file to `/var/backups/script_name/files/...` with a precise timestamp. It ensures that destructive script runs can always be rolled back manually.

#### `ensure_dir()`

* **Signature**: `ensure_dir "/path/to/dir" "owner:group" "perms"`
- **Behavior**: Atomically creates a directory, sets ownership, and enforces UNIX permissions (`chmod`). Returns silent success if the directory is already perfectly configured.

#### `restore_config()`

* **Signature**: `restore_config` (no args; honors `DRY_RUN`)
- **Behavior** (T1 audit §1): rolls back the most recent config backup. Selects the newest `${BACKUP_DIR_BASE}/run_<YYYYMMDD_HHMMSS>` directory (lexicographic == chronological by the zero-padded name — deliberately not mtime), lists a bounded sample of targets, and — after an interactive confirm (or a no-write summary under `DRY_RUN=true`) — restores each file to its `/`-rooted path via `_restore_item`, streaming `find` so memory stays flat. Restarts `sssd`/`rstudio-server`/`nginx` **only if ≥1 file was restored**. Returns non-zero on "no backup found" or "nothing restored". (Previously this function was a no-op that reported success — see CHANGELOG.)

---

### 3.5 The Template Engine: `__process_template()`

This function powers the injection of variables into Nginx configs, systemd units, and R scripts.

- **Signature**: `__process_template "source.template" "destination.conf" "VAR1" "VAR2"...`
- **Mechanism**:
  - Reads a source file.
  - Generates a dynamic `sed` script based on the passed variable names.
  - Replaces `%%VAR_NAME%%` placeholders in the text with the actual evaluated value of `$VAR_NAME` from the bash environment.
  - Uses alternate `sed` delimiters (`|` instead of `/`) to safely support injecting file paths (e.g., `/var/www/html`).
- **Security**: Much safer than `envsubst` because it only replaces explicitly requested variables, ignoring bash semantics inside the template (preventing accidental evaluation of user-supplied `$STRINGS`).

---

### 3.6 Specialized Utilities

#### `check_is_orphan()`

* **Purpose**: Used by the `cleanup_r_orphans.sh.template` script.
- **Mechanism**: Performs a deep ancestry check (`pstree` or sequential PPID lookups) up to `MAX_PARENT_DEPTH` to determine if an R process descends from a legitimate interactive session (rsession, tmux, sshd, VSCode) or if it has been detached to PID 1 (init) and is acting as a zombie.

#### `get_user_email()`

* **Purpose**: Resolves an AD username to a canonical email address.
- **Mechanism**: Checks local override maps (`user_email_map.txt`), parses `getent passwd` gecos fields, and falls back to deterministic construction logic (`username@domain.com`).
