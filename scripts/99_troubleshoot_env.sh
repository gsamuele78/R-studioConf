#!/bin/bash
# 99_troubleshoot_env.sh - Environment Troubleshooting Script
# Aggregates logs, system state, and active integration tests to isolate problems.
# v1.3.0: Added --rprofile subsystem check for BIOME-CALC Rprofile v11.0 + audit v28.
# Version: 1.3.0

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

# =============================================================================
# v1.3.0: Rprofile v11.0 + audit v28 subsystem check
# =============================================================================
check_rprofile() {
    log "INFO" "=== Troubleshooting Rprofile v11.0 Subsystem ==="

    local rprofile=/etc/R/Rprofile.site
    local renviron=/etc/R/Renviron.site

    # -----------------------------------------------------------------
    # 1. Deployment presence + template substitution
    # -----------------------------------------------------------------
    echo "[Rprofile.site Deployment]"
    if [[ ! -f "$rprofile" ]]; then
        echo "❌ $rprofile NOT FOUND — Rprofile not deployed."
        return 1
    fi
    echo "✅ $rprofile present ($(stat -c '%s bytes, modified %y' "$rprofile" 2>/dev/null))"

    local placeholders
    placeholders=$(grep -cE '%%[A-Z0-9_]+%%' "$rprofile" 2>/dev/null || echo 0)
    placeholders="${placeholders//[^0-9]/}"
    if [[ "${placeholders:-0}" -gt 0 ]]; then
        echo "❌ Found ${placeholders} unsubstituted %%PLACEHOLDERS%%:"
        grep -oE '%%[A-Z0-9_]+%%' "$rprofile" | sort -u | sed 's/^/   /'
        echo "   FIX: Redeploy via 50_setup_nodes.sh"
    else
        echo "✅ No template placeholders left"
    fi
    echo ""

    # -----------------------------------------------------------------
    # 2. R syntax validity
    # -----------------------------------------------------------------
    echo "[Rprofile.site R Syntax]"
    if command -v Rscript &>/dev/null; then
        if Rscript --vanilla -e "parse(file='$rprofile')" &>/dev/null; then
            echo "✅ parse() OK"
        else
            echo "❌ R parse error — dumping details:"
            Rscript --vanilla -e "tryCatch(parse(file='$rprofile'), error = function(e) cat(conditionMessage(e),'\n'))" 2>&1 || true
            echo "   FIX: Restore from backup or redeploy"
            return 1
        fi
    else
        echo "⚠️  Rscript not found — cannot check syntax"
    fi
    echo ""

    # -----------------------------------------------------------------
    # 3. Version marker
    # -----------------------------------------------------------------
    echo "[Rprofile Version]"
    local detected_ver
    detected_ver=$(grep -oE 'v11\.[0-9]+|v10\.[0-9]+|v9\.[0-9]+' "$rprofile" | head -1)
    if [[ -n "$detected_ver" ]]; then
        echo "✅ Version marker in header: $detected_ver"
        if [[ "$detected_ver" != v11* ]]; then
            echo "⚠️  Pre-v11.0 — NFS race condition + top-level return() bug still present"
            echo "   FIX: Deploy Rprofile v11.0"
        fi
    else
        echo "⚠️  Cannot detect version marker"
    fi
    echo ""

    # -----------------------------------------------------------------
    # 4. CRITICAL TEST: top-level return() bug (v10.0 regression)
    # -----------------------------------------------------------------
    echo "[Active Test: Worker Rscript Survival (return() bug)]"
    if command -v Rscript &>/dev/null; then
        local marker
        marker=$(mktemp)
        BIOME_WORKER_MODE=1 BIOME_WORKER_THREADS=1 \
            R_PROFILE="$rprofile" \
            Rscript --no-init-file --no-save --no-restore --no-echo \
                -e "cat('ALIVE=', Sys.getpid(), sep='', file='$marker')" >/dev/null 2>&1 || true
        if [[ -s "$marker" ]]; then
            echo "✅ Worker Rscript executed body: $(cat "$marker")"
        else
            echo "❌ Worker Rscript ABORTED — v10.0 top-level return() bug PRESENT"
            echo "   SYMPTOM: parLapply/makeClusterPSOCK workers die at handshake"
            echo "   FIX: Deploy Rprofile v11.0"
        fi
        rm -f "$marker"
    fi
    echo ""

    # -----------------------------------------------------------------
    # 5. Renviron.site contract
    # -----------------------------------------------------------------
    echo "[Renviron.site Contract]"
    if [[ -f "$renviron" ]]; then
        echo "✅ $renviron present"
        local -a required=(OPENBLAS_NUM_THREADS TMPDIR TMP TEMP R_TEMPDIR FONTCONFIG_PATH BSPM_SUDO RETICULATE_PYTHON)
        local missing=()
        for v in "${required[@]}"; do
            if ! grep -qE "^${v}=" "$renviron"; then
                missing+=("$v")
            fi
        done
        if [[ ${#missing[@]} -gt 0 ]]; then
            echo "⚠️  Missing vars: ${missing[*]}"
        else
            echo "✅ All 8 required vars present"
        fi
        # TMPDIR must point to /Rtmp
        local tmpdir_val
        tmpdir_val=$(grep -E '^TMPDIR=' "$renviron" | head -1 | cut -d= -f2- | tr -d '"')
        if [[ "$tmpdir_val" != "/Rtmp" ]]; then
            echo "⚠️  TMPDIR=${tmpdir_val:-<empty>} (v11.0 expects /Rtmp)"
        fi
    else
        echo "❌ $renviron not found"
    fi
    echo ""

    # -----------------------------------------------------------------
    # 6. BLAS variant (openblas-serial only)
    # -----------------------------------------------------------------
    echo "[BLAS Variant]"
    if command -v dpkg &>/dev/null; then
        local pthread_installed serial_installed
        pthread_installed=$(dpkg -l libopenblas0-pthread 2>/dev/null | grep -c '^ii' || echo 0)
        serial_installed=$(dpkg -l libopenblas0-serial 2>/dev/null | grep -c '^ii' || echo 0)
        pthread_installed="${pthread_installed//[^0-9]/}"
        serial_installed="${serial_installed//[^0-9]/}"
        if [[ "${pthread_installed:-0}" -gt 0 ]]; then
            echo "❌ libopenblas0-pthread INSTALLED — causes SIGSEGV in rsession"
            echo "   FIX: sudo apt-get remove libopenblas0-pthread && sudo apt-get install libopenblas0-serial"
        elif [[ "${serial_installed:-0}" -gt 0 ]]; then
            echo "✅ libopenblas0-serial only (v11.0 requirement)"
        else
            echo "⚠️  Neither pthread nor serial variant installed"
        fi
    fi
    echo ""

    # -----------------------------------------------------------------
    # 7. OpenMP infrastructure
    # -----------------------------------------------------------------
    echo "[OpenMP Infrastructure]"
    if dpkg -l libgomp1 2>/dev/null | grep -q '^ii'; then
        echo "✅ libgomp1 installed"
    else
        echo "❌ libgomp1 NOT installed"
    fi
    if [[ -f /usr/local/lib/pkgconfig/openmp.pc ]]; then
        echo "✅ /usr/local/lib/pkgconfig/openmp.pc present"
    else
        echo "⚠️  openmp.pc missing — R OpenMP packages may build single-threaded"
    fi
    if command -v pkg-config &>/dev/null; then
        local omp_cflags
        omp_cflags=$(pkg-config --cflags openmp 2>/dev/null)
        if echo "$omp_cflags" | grep -q -- '-fopenmp'; then
            echo "✅ pkg-config --cflags openmp → $omp_cflags"
        else
            echo "⚠️  pkg-config --cflags openmp returned: '${omp_cflags:-<empty>}'"
        fi
    fi
    echo ""

    # -----------------------------------------------------------------
    # 8. /Rtmp filesystem
    # -----------------------------------------------------------------
    echo "[/Rtmp Filesystem (v11.0 local disk)]"
    if [[ -d /Rtmp ]]; then
        local fs_type
        fs_type=$(df -T /Rtmp 2>/dev/null | awk 'NR==2 {print $2}')
        if [[ "$fs_type" == "tmpfs" ]]; then
            echo "❌ /Rtmp is TMPFS — v11.0 requires real local disk (ext4/xfs)"
        else
            echo "✅ /Rtmp filesystem: $fs_type"
        fi
        df -h /Rtmp 2>/dev/null | sed 's/^/   /'
    else
        echo "❌ /Rtmp does not exist"
    fi
    echo ""

    # -----------------------------------------------------------------
    # 9. Guard + tools:biome_calc check (via R)
    # -----------------------------------------------------------------
    echo "[Active Test: Guards + v11.0 Tools]"
    if command -v Rscript &>/dev/null; then
        local r_test
        r_test=$(timeout 30 Rscript --vanilla -e "
            suppressMessages(try(source('$rprofile'), silent = TRUE))
            if (exists('.biome_env')) {
              if (is.function(.biome_env\$deferred_pkg_init)) try(.biome_env\$deferred_pkg_init(), silent = TRUE)
              cat(sprintf('VERSION: %s\n', .biome_env\$VERSION %||% 'unknown'))
              cat(sprintf('API_VERSION: %d\n', .biome_env\$API_VERSION %||% 0L))
              cat(sprintf('USER_TMP_ROOT: %s\n', .biome_env\$USER_TMP_ROOT %||% 'MISSING'))
            } else cat('.biome_env: MISSING\n')
            if ('tools:biome_calc' %in% search()) {
              tools <- ls(as.environment('tools:biome_calc'))
              cat(sprintf('TOOLS_COUNT: %d\n', length(tools)))
              for (req in c('biome_make_cluster','biome_future_plan','biome_worker_diagnostics','status')) {
                cat(sprintf('TOOL_%s: %s\n', req, req %in% tools))
              }
            } else cat('tools:biome_calc: NOT ATTACHED\n')
        " 2>&1)
        if [[ -n "$r_test" ]]; then
            echo "$r_test" | sed 's/^/   /'
            if echo "$r_test" | grep -q "TOOL_biome_future_plan: TRUE" && \
               echo "$r_test" | grep -q "TOOL_biome_worker_diagnostics: TRUE"; then
                echo "✅ v11.0 tools attached"
            else
                echo "⚠️  Missing v11.0 tools (biome_future_plan, biome_worker_diagnostics)"
            fi
        else
            echo "⚠️  Rscript did not produce output"
        fi
    fi
    echo ""

    # -----------------------------------------------------------------
    # 10. Per-user /Rtmp/biome_<user>/ layout
    # -----------------------------------------------------------------
    echo "[Per-User /Rtmp Layout (v11.0)]"
    if [[ -d /Rtmp ]]; then
        local biome_users
        biome_users=$(find /Rtmp -maxdepth 1 -type d -name 'biome_*' 2>/dev/null | wc -l)
        biome_users="${biome_users//[^0-9]/}"
        echo "Users with /Rtmp init: ${biome_users:-0}"

        if [[ -n "${TEST_USER:-}" ]]; then
            local tu_dir="/Rtmp/biome_${TEST_USER}"
            if [[ -d "$tu_dir" ]]; then
                echo "User $TEST_USER: $tu_dir"
                local -a expected=(nimble_compile tmb_compile stan_compile rcpp_cache cluster_logs keras_cache plot_cache)
                local missing=()
                for sub in "${expected[@]}"; do
                    [[ -d "$tu_dir/$sub" ]] || missing+=("$sub")
                done
                if [[ ${#missing[@]} -gt 0 ]]; then
                    echo "⚠️  Missing subdirs: ${missing[*]}"
                else
                    echo "✅ All 7 v11.0 subdirs present"
                fi
                # Recent cluster_logs errors for this user
                if [[ -d "$tu_dir/cluster_logs" ]]; then
                    local err_logs
                    err_logs=$(find "$tu_dir/cluster_logs" -name 'psock_*.log' -mmin -1440 2>/dev/null \
                                | xargs -r grep -l -iE 'error|SIGSEGV|unserialize' 2>/dev/null | wc -l)
                    err_logs="${err_logs//[^0-9]/}"
                    if [[ "${err_logs:-0}" -gt 0 ]]; then
                        echo "⚠️  ${err_logs} worker log(s) with errors in last 24h (for $TEST_USER)"
                    fi
                fi
            else
                echo "⚠️  $tu_dir does not exist (user never triggered Rprofile)"
            fi
        fi
    fi
    echo ""
}

collect_bundle() {
    log "INFO" "=== Generating Debug Bundle ==="
    BUNDLE_NAME="/tmp/rstudio_debug_bundle_$(date +%s).tar.gz"

    GLOBAL_TEMP_DIR=$(mktemp -d "/tmp/debug_bundle_tmp_XXXXXX") || { log "ERROR" "Failed to create temp directory"; exit 1; }

    mkdir -p "$GLOBAL_TEMP_DIR/logs" "$GLOBAL_TEMP_DIR/etc/rstudio" "$GLOBAL_TEMP_DIR/etc/nginx" "$GLOBAL_TEMP_DIR/etc/pam.d" "$GLOBAL_TEMP_DIR/etc/R"

    # Collect logs safely
    cp -r /var/log/nginx "$GLOBAL_TEMP_DIR/logs/" 2>/dev/null || true
    cp -r /var/log/rstudio "$GLOBAL_TEMP_DIR/logs/" 2>/dev/null || true
    cp /var/log/secure "$GLOBAL_TEMP_DIR/logs/" 2>/dev/null || true
    cp /var/log/auth.log "$GLOBAL_TEMP_DIR/logs/" 2>/dev/null || true
    cp /var/log/biome-log/r_biome_system.log "$GLOBAL_TEMP_DIR/logs/" 2>/dev/null || true

    # Collect custom logs using journalctl for services without direct log files
    if command -v journalctl &>/dev/null; then
        journalctl -u botanical-telemetry.service --no-pager -n 500 > "$GLOBAL_TEMP_DIR/logs/botanical-telemetry.log" 2>/dev/null || true
        journalctl -u ttyd.service --no-pager -n 500 > "$GLOBAL_TEMP_DIR/logs/ttyd.log" 2>/dev/null || true
        journalctl -u ollama.service --no-pager -n 500 > "$GLOBAL_TEMP_DIR/logs/ollama.log" 2>/dev/null || true
        journalctl -u rstudio-server --no-pager -n 500 > "$GLOBAL_TEMP_DIR/logs/rstudio-server.log" 2>/dev/null || true
    fi

    # Detailed storage output
    if command -v df &>/dev/null; then df -h -T > "$GLOBAL_TEMP_DIR/logs/df_output.txt" 2>/dev/null || true; fi
    if command -v mount &>/dev/null; then mount > "$GLOBAL_TEMP_DIR/logs/mount_output.txt" 2>/dev/null || true; fi

    # v1.3.0: collect R configs
    cp /etc/R/Rprofile.site "$GLOBAL_TEMP_DIR/etc/R/" 2>/dev/null || true
    cp /etc/R/Renviron.site "$GLOBAL_TEMP_DIR/etc/R/" 2>/dev/null || true

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
    echo "  --rprofile           Check BIOME-CALC Rprofile v11.0 subsystem (v1.3.0+)"
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
    echo "  sudo $0 --rprofile --test-user martina.livornese2"
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    if [[ $# -eq 0 ]]; then
        usage
        exit 1
    fi

    if [[ "$EUID" -ne 0 ]]; then
        log "ERROR" "This script contains active integration tests and file system inspections that MUST be run as root (sudo)."
        exit 1
    fi

    declare -A RUN_CHECK
    COLLECT_BUNDLE=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --auth) RUN_CHECK[auth]=true; shift ;;
            --nginx) RUN_CHECK[nginx]=true; shift ;;
            --rstudio) RUN_CHECK[rstudio]=true; shift ;;
            --rprofile) RUN_CHECK[rprofile]=true; shift ;;
            --ttyd) RUN_CHECK[ttyd]=true; shift ;;
            --ollama) RUN_CHECK[ollama]=true; shift ;;
            --storage) RUN_CHECK[storage]=true; shift ;;
            --telemetry) RUN_CHECK[telemetry]=true; shift ;;
            --native-opt) RUN_CHECK[native_opt]=true; shift ;;
            --all)
                RUN_CHECK[auth]=true; RUN_CHECK[nginx]=true; RUN_CHECK[rstudio]=true
                RUN_CHECK[rprofile]=true
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
    echo "║            $(date '+%Y-%m-%d %H:%M:%S')                            ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""

    if [[ "${RUN_CHECK[auth]:-false}" == true ]]; then check_auth; echo ""; fi
    if [[ "${RUN_CHECK[nginx]:-false}" == true ]]; then check_nginx; echo ""; fi
    if [[ "${RUN_CHECK[rstudio]:-false}" == true ]]; then check_rstudio; echo ""; fi
    if [[ "${RUN_CHECK[rprofile]:-false}" == true ]]; then check_rprofile; echo ""; fi
    if [[ "${RUN_CHECK[ttyd]:-false}" == true ]]; then check_ttyd; echo ""; fi
    if [[ "${RUN_CHECK[ollama]:-false}" == true ]]; then check_ollama; echo ""; fi
    if [[ "${RUN_CHECK[storage]:-false}" == true ]]; then check_storage; echo ""; fi
    if [[ "${RUN_CHECK[telemetry]:-false}" == true ]]; then check_telemetry; echo ""; fi
    if [[ "${RUN_CHECK[native_opt]:-false}" == true ]]; then check_native_opt; echo ""; fi

    if [[ "$COLLECT_BUNDLE" == true ]]; then collect_bundle; fi
}

main "$@"
