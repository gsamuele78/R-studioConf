<!-- docs/developer/LIBRARY_REFERENCE.md -->
# Library Reference: `lib/common_utils.sh`

This reference lists the functions actually defined by `lib/common_utils.sh` as of 2026-10-06. The source identifies itself as Universal Compatibility Mod 1.4.

## Sourcing contract

Numbered T1 scripts should source this library near the top instead of reimplementing shared logging, dependency checks, backups, or template processing. The library initializes:

- colors: `GREEN`, `RED`, `YELLOW`, `CYAN`, `NC`
- `LOG_FILE`, defaulting to `/var/log/biome-log/core/common_utils.log` when the caller has not set it
- `BACKUP_DIR_BASE=/var/backups/r_env_manager/config_backups_<YYYYMMDD>`
- `CURRENT_BACKUP_DIR`, initially empty

Callers commonly export `MAIN_LOG_FILE`, `MAX_RETRIES`, `TIMEOUT`, and `INTERACTIVE`. Defaults used by `run_command` are three attempts and 1,800 seconds.

## Function inventory

### Preconditions and package-manager setup

| Function | Interface and behavior |
|---|---|
| `check_root` | Exits when `EUID` is not zero. Uses `log` when available. |
| `check_dependencies dep...` | Returns non-zero and logs all missing commands. It does not install them. |
| `check_bash_version [major]` | Requires Bash major version 4 by default. |
| `setup_noninteractive_mode` | Exports apt/debconf/needrestart variables, configures man-db suppression, and writes `/etc/dpkg/dpkg.cfg.d/01_nodoc` when needed. Idempotent through `NONINTERACTIVE_CONFIGURED`. |
| `check_apt_health` | Runs `dpkg --configure -a`, attempts `apt-get -f install`, removes unlocked stale apt locks, and warns at 95% disk use. |

### Logging and command execution

| Function | Interface and behavior |
|---|---|
| `log [LEVEL] message...` | Levels are `INFO`, `WARN`, `ERROR`, `FATAL`, and `DEBUG`. Writes timestamped lines through `tee` to `LOG_FILE` and also to `MAIN_LOG_FILE` when different. |
| `handle_error [exit_code] [message]` | Logs an error; it does not exit by itself. |
| `run_command [description] command` | Public wrapper. Preserves the caller's `pipefail` setting and delegates to `__run_command_impl`. |
| `__run_command_impl ...` | Internal execution engine; do not call directly. Retries with a fixed five-second delay. Apt commands receive bounded timeouts and noninteractive options. Other commands run through `timeout` and `bash -c`; output is streamed to the active log. Composite apt commands separated by `&&` are processed sequentially. |

`run_command` does not accept positional retry or timeout arguments. Set `MAX_RETRIES` and `TIMEOUT` in the caller. Set `INTERACTIVE=true` only for commands that require terminal input.

### Site-local configuration

| Function | Interface and behavior |
|---|---|
| `resolve_site_config name base_dir` | Prints `base_dir/site/name` when present; otherwise warns on stderr and prints `base_dir/name.example`. Intended for command substitution. |
| `assert_site_configured label value` | Exits when the value is empty or contains `__FILL_ME__`. |
| `patch_deployed_mail_overrides target` | Requires six mail/contact variables, backs up the target, regenerates those assignments atomically, and restores owner/mode. Returns non-zero on missing data or failed backup/write/ownership restoration. |

The six patched keys are `SMTP_HOST`, `SENDER_EMAIL`, `MAIL_DOMAIN`, `MAIL_DOMAINS_USER`, `SMTP_DNS_SERVERS`, and `BIOME_CONTACT`.

### Backup and restore

| Function | Interface and behavior |
|---|---|
| `setup_backup_dir` | Creates one timestamped run directory under `BACKUP_DIR_BASE`; exits if creation fails. |
| `_backup_item source destination_parent` | Internal helper. Copies existing paths with `cp -aL`; missing sources are skipped. |
| `backup_config` | Requires `setup_backup_dir` first. Saves known Nginx, RStudio, R, TLS, SSSD, Kerberos, PAM, and local script configuration paths. |
| `_restore_item backup_source live_target` | Internal helper that replaces a target directory or copies a file/directory from a backup. |
| `restore_config` | Selects the lexicographically newest `run_*` backup, shows a bounded target sample, supports `DRY_RUN=true`, requires confirmation otherwise, restores files to `/`, and restarts installed `sssd`, `rstudio-server`, and `nginx` services only after at least one successful restore. |

The functional `restore_config` implementation and its failure propagation were introduced by commit `5543f36`.

### Files and templates

| Function | Interface and behavior |
|---|---|
| `ensure_dir_exists path` | Creates a missing directory with `mkdir -p` through `run_command`. It does not set owner or mode. |
| `ensure_file_exists path` | Creates the parent directory and an empty file when absent. |
| `add_line_if_not_present line file` | Appends an exact line only when `grep -qFx` does not find it. |
| `process_template template output_variable NAME=value...` | Reads the template and replaces explicit `%%NAME%%` placeholders. The rendered text is assigned to the named shell variable; this function does not write the destination file. |
| `process_systemd_template template_path service_or_path` | Replaces `{{NAME}}` tokens from caller variables and writes either the absolute destination or `/etc/systemd/system/<service_or_path>`, then sets `root:root` and mode `0644`. |
| `prompt_for_value prompt variable_name` | Interactive prompt retaining the current value when input is empty. |

The two template functions are separate implementations with different placeholder syntaxes. Their consolidation remains an open audit item.

### Orphan-cleanup email helpers

| Function | Interface and behavior |
|---|---|
| `resolve_admin_recipients input` | Accepts `file:///path`, a CSV address list, or one address; file mode ignores comments and blank lines and emits CSV. |
| `resolve_user_email username default_domain` | Checks `${BIOME_CONF}/conf/user_email_map.txt` for a whitespace-separated override, then returns `username@default_domain`. |

The deployed orphan subsystem also ships `templates/orphan_cleanup_helpers.sh.template`, whose `resolve_user_email` adds `MAIL_DOMAINS_USER` multi-domain behavior. The duplication is real and remains an open consolidation item.

## Functions not present

The following names appeared in older documentation but are not defined in `lib/common_utils.sh`: `log_message`, `log_info`, `log_warn`, `log_error`, `log_success`, `backup_file`, `ensure_dir`, `__process_template`, `check_is_orphan`, and `get_user_email`.

Some scripts define local functions with some of those names. They are not library APIs.

Unverified: function behavior was reviewed statically and against repository tests/history; this audit did not execute privileged backup, restore, apt, or service-restart paths on a live host.
