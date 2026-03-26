#!/bin/bash
# 99_troubleshoot_env.sh - Environment Troubleshooting Script
# Aggregates logs, system state, and active integration tests to isolate problems.
# Version: 1.2.0

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
UTILS_SCRIPT_PATH="${SCRIPT_DIR}/../lib/common_utils.sh"

# Source common utilities
if [[ ! -f "$UTILS_SCRIPT_PATH" ]]; then
  echo "ERROR: common_utils.sh not found at $UTILS_SCRIPT_PATH" >&2
  exit 2
fi
# shellcheck source=../lib/common_utils.sh disable=SC1091
source "$UTILS_SCRIPT_PATH"

TEST_USER=""
GLOBAL_TEMP_DIR=""

# =============================================================================
# PESSIMISTIC ENGINEERING CONTROLS
# =============================================================================

cleanup() {
    local rc=$?
    if [[ -n "${GLOBAL_TEMP_DIR:-}" && -d "$GLOBAL_TEMP_DIR" ]]; then
        rm -rf "$GLOBAL_TEMP_DIR"
    fi
    exit $rc
}
trap cleanup EXIT ERR INT TERM

# =============================================================================
# TROUBLESHOOTING FUNCTIONS
# =============================================================================

check_auth() {
    log "INFO" "=== Troubleshooting Auth Subsystem ==="
    
    echo "[SSSD Status]"
    systemctl status sssd --no-pager | head -n 10 || echo "SSSD not running or failed."
    echo ""
    
    echo "[Winbind Status]"
    systemctl status winbind --no-pager | head -n 10 || echo "Winbind not running or failed."
    echo ""
    
    echo "[Realm List]"
    if command -v realm &>/dev/null; then
        realm list || echo "realm list failed."
    else
        echo "realm command not found."
    fi
    echo ""
    
    echo "[Kerberos Keytab]"
    if [[ -f /etc/krb5.keytab ]]; then
        klist -k /etc/krb5.keytab 2>/dev/null || echo "Failed to read /etc/krb5.keytab."
    else
        echo "No kerberos keytab found at /etc/krb5.keytab."
    fi
    echo ""
    
    if [[ -n "${TEST_USER:-}" ]]; then
        echo "[Active Test: getent passwd for $TEST_USER]"
        getent passwd "$TEST_USER" || echo "⚠️ User $TEST_USER not found via getent."
        echo ""
        
        echo "[Active Test: id for $TEST_USER]"
        id "$TEST_USER" || echo "⚠️ User $TEST_USER not found via id."
        echo ""
        
        echo "[Active Test: PAM integration with pamtester]"
        if command -v pamtester &>/dev/null; then
            echo "Running pamtester for 'rstudio' module..."
            echo "You may be prompted for $TEST_USER's password."
            pamtester rstudio "$TEST_USER" authenticate || echo "❌ pamtester rstudio failed."
            
            echo "Running pamtester for 'nginx' module..."
            pamtester nginx "$TEST_USER" authenticate || echo "❌ pamtester nginx failed."
        else
            echo "⚠️ pamtester is not installed. Run: sudo apt-get install -y pamtester"
            echo "Alternatively, testing with su:"
            if su -s /bin/bash "$TEST_USER" -c 'echo "✅ Auth successful via su"'; then
                :
            else
                echo "❌ Auth failed via su."
            fi
        fi
        echo ""
    else
        echo "💡 Hint: Pass --test-user <username> to run active PAM and Active Directory tests."
        echo ""
    fi
    
    echo "[Recent Secure/Auth log errors]"
    if [[ -f /var/log/secure ]]; then
        tail -n 500 /var/log/secure | grep -iE 'pam|sssd|nginx|fail|error|denied' | tail -n 20 || echo "No recent errors found."
    elif [[ -f /var/log/auth.log ]]; then
        tail -n 500 /var/log/auth.log | grep -iE 'pam|sssd|nginx|fail|error|denied' | tail -n 20 || echo "No recent errors found."
    else
        echo "No secure or auth log found."
    fi
}

check_nginx() {
    log "INFO" "=== Troubleshooting Nginx Subsystem ==="
    
    echo "[Nginx Config Test]"
    nginx -t 2>&1 || echo "Nginx config test failed (or missing privileges)."
    echo ""
    
    echo "[Nginx Status]"
    systemctl status nginx --no-pager | head -n 10 || echo "Nginx not running."
    echo ""
    
    echo "[PAM Auth Config for Nginx]"
    ls -la /etc/pam.d/nginx 2>/dev/null || echo "/etc/pam.d/nginx missing!"
    cat /etc/pam.d/nginx 2>/dev/null || true
    echo ""
    
    echo "[Active Test: Local HTTP connectivity]"
    if curl -sIk http://127.0.0.1 2>/dev/null | head -n 1 | grep -q 'HTTP'; then
         echo "✅ Nginx responding to local HTTP requests."
    else
         echo "❌ Nginx NOT responding to local HTTP requests."
    fi
    echo ""

    echo "[Recent Nginx Error Logs]"
    if [[ -f /var/log/nginx/error.log ]]; then
        tail -n 30 /var/log/nginx/error.log || echo "Could not read nginx error log."
    else
        echo "Nginx error log not found."
    fi
}

check_rstudio() {
    log "INFO" "=== Troubleshooting RStudio Subsystem ==="
    
    echo "[RStudio-server Status]"
    systemctl status rstudio-server --no-pager | head -n 10 || echo "RStudio-server not running."
    echo ""
    
    echo "[RStudio Verify Installation]"
    if command -v rstudio-server &>/dev/null; then
        rstudio-server verify-installation 2>&1 || echo "rstudio-server verify-installation reported errors."
    else
        echo "rstudio-server command not found."
    fi
    echo ""
    
    echo "[Active Test: Local RStudio Server connectivity]"
    if curl -sIk http://127.0.0.1:8787 2>/dev/null | head -n 1 | grep -q 'HTTP'; then
        echo "✅ RStudio responding locally on port 8787."
    else
        echo "❌ RStudio NOT responding locally on port 8787. Check if service is dead or bound to wrong interface."
    fi
    echo ""

    echo "[Active R Sessions]"
    if command -v rstudio-server &>/dev/null; then
        rstudio-server active-sessions 2>/dev/null || echo "Could not list active sessions (requires root)."
    fi
    echo ""
    
    echo "[RStudio Configuration (rserver.conf)]"
    cat /etc/rstudio/rserver.conf 2>/dev/null || echo "/etc/rstudio/rserver.conf not found or permission denied."
    echo ""
    
    echo "[Recent RStudio rserver.log]"
    if [[ -f /var/log/rstudio/rstudio-server/rserver.log ]]; then
        tail -n 30 /var/log/rstudio/rstudio-server/rserver.log || echo "Could not read rserver.log."
    elif [[ -n "$(journalctl -u rstudio-server -n 1 2>/dev/null)" ]]; then
        echo "Reading from journalctl:"
        journalctl -u rstudio-server --no-pager -n 30 || true
    else
        echo "RStudio logs not found."
    fi
}

check_ttyd() {
    log "INFO" "=== Troubleshooting TTYD Subsystem ==="
    echo "[TTYD Service Status]"
    systemctl status ttyd.service --no-pager | head -n 10 || echo "TTYD not running or failed."
    echo ""
    echo "[TTYD Listening Ports]"
    ss -tulpn 2>/dev/null | grep ttyd || echo "No ttyd ports found listening (or requires root)."
    echo ""
    echo "[Active Test: wrapper script]"
    if [[ -x /usr/local/bin/ttyd_login_wrapper.sh ]]; then
        echo "✅ /usr/local/bin/ttyd_login_wrapper.sh is executable."
    else
        echo "❌ /usr/local/bin/ttyd_login_wrapper.sh is missing or not executable."
    fi
    echo ""
}

check_ollama() {
    log "INFO" "=== Troubleshooting Ollama Subsystem ==="
    echo "[Ollama Service Status]"
    systemctl status ollama.service --no-pager | head -n 10 || echo "Ollama not running or failed."
    echo ""
    echo "[Ollama Models]"
    if command -v ollama &>/dev/null; then
        ollama list 2>/dev/null || echo "Could not list Ollama models."
    else
        echo "Ollama command not found."
    fi
    echo ""
    echo "[Active Test: Ollama API HTTP Check]"
    if curl -sf http://127.0.0.1:11434/api/tags > /dev/null; then
        echo "✅ Ollama API reachable."
    else
        echo "❌ Ollama API unreachable."
    fi
    echo ""
}

check_storage() {
    log "INFO" "=== Troubleshooting Storage (NFS/CIFS) ==="
    echo "[Mounted NFS/CIFS Shares]"
    mount | grep -iE 'nfs|cifs' || echo "No NFS or CIFS shares mounted."
    echo ""
    echo "[Disk Usage for NFS/CIFS]"
    df -h -T 2>/dev/null | awk 'NR==1 || /nfs/ || /cifs/' || echo "Could not retrieve disk usage for network shares."
    echo ""
    
    echo "[Active Test: Network Share Write Access]"
    if [[ -n "${TEST_USER:-}" ]]; then
        USER_HOME=$(getent passwd "$TEST_USER" | cut -d: -f6 || true)
        if [[ -n "$USER_HOME" && -d "$USER_HOME" ]]; then
            TEST_FILE="$USER_HOME/.biome_write_test_$$"
            echo "Testing write access to $USER_HOME as user $TEST_USER..."
            if su -s /bin/bash "$TEST_USER" -c "touch $TEST_FILE && rm $TEST_FILE" 2>/dev/null; then
                echo "✅ Write test SUCCESSFUL for $TEST_USER in $USER_HOME."
            else
                echo "❌ Write test FAILED for $TEST_USER in $USER_HOME. Check NFS permissions, root_squash, or AD mount creds."
            fi
        else
            echo "⚠️ Could not perform write test: User home directory ($USER_HOME) does not exist or user not found."
        fi
    else
        echo "💡 Hint: Pass --test-user <username> to actively test file writing in their networked home directory."
    fi
    echo ""
}

check_telemetry() {
    log "INFO" "=== Troubleshooting Telemetry Subsystem ==="
    echo "[Botanical Telemetry Service Status]"
    systemctl status botanical-telemetry.service --no-pager | head -n 10 || echo "Botanical Telemetry not running."
    echo ""
    echo "[Node Exporter Service Status]"
    systemctl status prometheus-node-exporter.service --no-pager | head -n 10 || echo "Node Exporter not running."
    echo ""
    echo "[Active Test: Telemetry API HTTP Check]"
    if curl -sf http://127.0.0.1:8000/api/v1/health > /dev/null; then
         echo "✅ Telemetry API Reachable."
    else
         echo "❌ Telemetry API Unreachable."
    fi
    echo ""
    echo "[Active Test: Node Exporter Metrics Check]"
    if curl -sf http://127.0.0.1:9100/metrics > /dev/null; then
         echo "✅ Node Exporter Reachable."
    else
         echo "❌ Node Exporter Unreachable."
    fi
    echo ""
}

check_native_opt() {
    log "INFO" "=== Troubleshooting Native Rprofile Optimization ==="
    echo "[Native Module Status]"
    local so_path="/opt/rstudio-tools/biome_core.so"
    if [[ -f "$so_path" ]]; then
        echo "✅ Optimized module exists: $so_path"
        ls -la "$so_path"
    else
        echo "❌ Optimized module missing: $so_path"
    fi
    echo ""

    echo "[Active Test: Module Load Latency (microbenchmark)]"
    if [[ -f "$so_path" ]]; then
        if command -v Rscript &>/dev/null; then
            echo "Running latency test via Rscript..."
            local mb_res
            mb_res=$(Rscript --vanilla -e "
              suppressMessages({
                 if (!requireNamespace('microbenchmark', quietly=TRUE)) {
                   cat('microbenchmark missing\n')
                   q('no', status=1)
                 }
                 tryCatch(dyn.load('$so_path'), error=function(e) { cat('dyn.load failed\n'); q('no', status=1) })
                 mb <- microbenchmark::microbenchmark(
                   users_ffi = .C('biome_get_active_users', out=0L),
                   ram_ffi = .C('biome_get_system_ram_gb', out=0.0),
                   tmp_ffi = .C('biome_get_tmp_use_pct', out=0.0),
                   times = 50
                 )
                 print(mb, unit='ms')
               })
            " 2>&1) || true
            if echo "$mb_res" | grep -q "users_ffi"; then
                echo "$mb_res"
                echo "✅ Native module executed correctly."
            else
                echo "❌ Failed to benchmark: $mb_res"
            fi
        else
            echo "❌ Rscript not found."
        fi
    else
        echo "⚠️ Skipping test as module is missing."
    fi
    echo ""
}

collect_bundle() {
    log "INFO" "=== Generating Debug Bundle ==="
    BUNDLE_NAME="/tmp/rstudio_debug_bundle_$(date +%s).tar.gz"
    
    # Pessimistic: assign to global temp dir for trap cleanup
    GLOBAL_TEMP_DIR=$(mktemp -d "/tmp/debug_bundle_tmp_XXXXXX") || { log "ERROR" "Failed to create temp directory"; exit 1; }
    
    mkdir -p "$GLOBAL_TEMP_DIR/logs" "$GLOBAL_TEMP_DIR/etc/rstudio" "$GLOBAL_TEMP_DIR/etc/nginx" "$GLOBAL_TEMP_DIR/etc/pam.d"
    
    # Collect logs safely
    cp -r /var/log/nginx "$GLOBAL_TEMP_DIR/logs/" 2>/dev/null || true
    cp -r /var/log/rstudio "$GLOBAL_TEMP_DIR/logs/" 2>/dev/null || true
    cp /var/log/secure "$GLOBAL_TEMP_DIR/logs/" 2>/dev/null || true
    cp /var/log/auth.log "$GLOBAL_TEMP_DIR/logs/" 2>/dev/null || true
    
    # Collect custom logs using journalctl for services without direct log files
    if command -v journalctl &>/dev/null; then
        journalctl -u botanical-telemetry.service --no-pager -n 500 > "$GLOBAL_TEMP_DIR/logs/botanical-telemetry.log" 2>/dev/null || true
        journalctl -u ttyd.service --no-pager -n 500 > "$GLOBAL_TEMP_DIR/logs/ttyd.log" 2>/dev/null || true
        journalctl -u ollama.service --no-pager -n 500 > "$GLOBAL_TEMP_DIR/logs/ollama.log" 2>/dev/null || true
    fi
    
    # Detailed storage output
    if command -v df &>/dev/null; then df -h -T > "$GLOBAL_TEMP_DIR/logs/df_output.txt" 2>/dev/null || true; fi
    if command -v mount &>/dev/null; then mount > "$GLOBAL_TEMP_DIR/logs/mount_output.txt" 2>/dev/null || true; fi
    
    # Collect configs safely
    cp -r /etc/rstudio/* "$GLOBAL_TEMP_DIR/etc/rstudio/" 2>/dev/null || true
    cp -r /etc/nginx/conf.d "$GLOBAL_TEMP_DIR/etc/nginx/" 2>/dev/null || true
    cp -r /etc/nginx/sites-available "$GLOBAL_TEMP_DIR/etc/nginx/" 2>/dev/null || true
    cp /etc/nginx/nginx.conf "$GLOBAL_TEMP_DIR/etc/nginx/" 2>/dev/null || true
    cp /etc/pam.d/nginx /etc/pam.d/rstudio /etc/pam.d/sshd "$GLOBAL_TEMP_DIR/etc/pam.d/" 2>/dev/null || true
    
    # Redact potential secrets from bundle
    find "$GLOBAL_TEMP_DIR" -type f -exec sed -i -E 's/(\w*(password|secret)\w*\s*[:=]\s*).*$/\1[REDACTED]/gi' {} + 2>/dev/null || true
    
    if command -v tar &>/dev/null; then
        tar -czf "$BUNDLE_NAME" -C "$GLOBAL_TEMP_DIR" .
        log "OK" "Debug bundle created at: $BUNDLE_NAME"
    else
        log "ERROR" "tar command not found, cannot archive bundle."
    fi
}

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo "Aggregates logs, configs, and active tests to troubleshoot the RStudio environment."
    echo ""
    echo "Options:"
    echo "  --auth               Check AD, SSSD, Winbind, and PAM Auth logs"
    echo "  --nginx              Check Nginx status, config, and error logs"
    echo "  --rstudio            Check RStudio-Server status, sessions, and logs"
    echo "  --ttyd               Check ttyd service and ports"
    echo "  --ollama             Check Ollama service and models"
    echo "  --storage            Check NFS and CIFS mounts"
    echo "  --telemetry          Check Botanical Telemetry and Node Exporter"
    echo "  --native-opt         Check Native Rust Optimization Module"
    echo "  --all                Run all subsystem checks"
    echo "  --test-user <user>   Run active integration tests (getent, pamtester, storage write) using this username"
    echo "  --collect            Generate a debug bundle tarball of sanitized configs and logs"
    echo "  -h, --help           Display this help message"
    echo ""
    echo "Examples:"
    echo "  sudo $0 --auth --test-user pippo.pluto"
    echo "  sudo $0 --all --test-user pippo.pluto"
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    if [[ $# -eq 0 ]]; then
        usage
        exit 1
    fi
    
    # Pessimistic PRD Rule: Hard enforcement of root execution for accurate troubleshooting
    if [[ "$EUID" -ne 0 ]]; then
        log "ERROR" "This script contains active integration tests and file system inspections that MUST be run as root (sudo)."
        exit 1
    fi

    # Parse arguments
    declare -A RUN_CHECK
    COLLECT_BUNDLE=false
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --auth) RUN_CHECK[auth]=true; shift ;;
            --nginx) RUN_CHECK[nginx]=true; shift ;;
            --rstudio) RUN_CHECK[rstudio]=true; shift ;;
            --ttyd) RUN_CHECK[ttyd]=true; shift ;;
            --ollama) RUN_CHECK[ollama]=true; shift ;;
            --storage) RUN_CHECK[storage]=true; shift ;;
            --telemetry) RUN_CHECK[telemetry]=true; shift ;;
            --native-opt) RUN_CHECK[native_opt]=true; shift ;;
            --all)
                RUN_CHECK[auth]=true; RUN_CHECK[nginx]=true; RUN_CHECK[rstudio]=true
                RUN_CHECK[ttyd]=true; RUN_CHECK[ollama]=true; RUN_CHECK[storage]=true
                RUN_CHECK[telemetry]=true; RUN_CHECK[native_opt]=true
                shift ;;
            --test-user)
                if [[ -n "${2:-}" && ! "$2" == --* ]]; then
                    TEST_USER="$2"
                    shift 2
                else
                    echo "ERROR: --test-user requires a username."
                    exit 1
                fi
                ;;
            --collect) COLLECT_BUNDLE=true; shift ;;
            -h|--help) usage; exit 0 ;;
            *)
                echo "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done

    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║            ENVIRONMENT TROUBLESHOOTING TOOL                ║"
    echo "║            $(date '+%Y-%m-%d %H:%M:%S')                           ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""

    if [[ "${RUN_CHECK[auth]:-false}" == true ]]; then check_auth; echo ""; fi
    if [[ "${RUN_CHECK[nginx]:-false}" == true ]]; then check_nginx; echo ""; fi
    if [[ "${RUN_CHECK[rstudio]:-false}" == true ]]; then check_rstudio; echo ""; fi
    if [[ "${RUN_CHECK[ttyd]:-false}" == true ]]; then check_ttyd; echo ""; fi
    if [[ "${RUN_CHECK[ollama]:-false}" == true ]]; then check_ollama; echo ""; fi
    if [[ "${RUN_CHECK[storage]:-false}" == true ]]; then check_storage; echo ""; fi
    if [[ "${RUN_CHECK[telemetry]:-false}" == true ]]; then check_telemetry; echo ""; fi
    if [[ "${RUN_CHECK[native_opt]:-false}" == true ]]; then check_native_opt; echo ""; fi
    
    if [[ "$COLLECT_BUNDLE" == true ]]; then collect_bundle; fi
}

main "$@"
