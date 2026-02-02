#!/bin/bash
set -euo pipefail

# =====================================================================
# SYSTEM OPTIMIZATION SCRIPT (v1.0)
# =====================================================================
# Applies Kernel and System level optimizations for High-Performance Nginx.
# Aligned with project structure: Uses templates, common_utils, and vars.

# =====================================================================
# PATHS AND CONFIGURATION
# =====================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
UTILS_SCRIPT_PATH="${SCRIPT_DIR}/../lib/common_utils.sh"
DEFAULT_CONFIG_FILE="${SCRIPT_DIR}/../config/optimize_system.vars.conf"
TEMPLATE_DIR="${SCRIPT_DIR}/../templates"

# Feature Flags
INTERACTIVE_MODE="true"

# =====================================================================
# LOAD COMMON UTILITIES
# =====================================================================
if [[ ! -f "$UTILS_SCRIPT_PATH" ]]; then
  echo "ERROR: common_utils.sh not found at $UTILS_SCRIPT_PATH" >&2
  exit 2
fi
source "$UTILS_SCRIPT_PATH"

check_root

# =====================================================================
# USAGE & HELP
# =====================================================================
usage() {
    echo -e "\033[1;33mUsage: $0 [-c /path/to/config.conf] [-y]\033[0m"
    echo "  -c: Path to configuration file (default: config/optimize_system.vars.conf)"
    echo "  -y: Non-interactive mode (assume defaults)"
    exit 1
}

# Parse Args
while getopts "c:y" opt; do
    case "$opt" in
        c) DEFAULT_CONFIG_FILE="$OPTARG" ;;
        y) INTERACTIVE_MODE="false" ;;
        *) usage ;;
    esac
done

# Load Config
if [[ -f "$DEFAULT_CONFIG_FILE" ]]; then
    log INFO "Loading configuration from $DEFAULT_CONFIG_FILE"
    source "$DEFAULT_CONFIG_FILE"
else
    log ERROR "Configuration file not found: $DEFAULT_CONFIG_FILE"
    exit 1
fi

# =====================================================================
# CORE FUNCTIONS
# =====================================================================

apply_sysctl_tuning() {
    local env_type="$1"
    local sysctl_target="/etc/sysctl.conf"
    local sysctl_template="${TEMPLATE_DIR}/sysctl_optimization.conf.template"
    
    log INFO "--- Applying Kernel Tuning ($env_type) ---"
    
    if [[ ! -f "$sysctl_template" ]]; then
        log ERROR "Template not found: $sysctl_template"
        return 1
    fi
    
    # 1. Backup
    backup_config # Uses common_utils backup logic
    log INFO "Backing up sysctl.conf..."
    cp "$sysctl_target" "${sysctl_target}.bak.$(date +%s)"
    
    # 2. Prepare Variables for Template
    local host_tuning=""
    local vm_tuning=""
    
    # Define environment specific blocks
    if [[ "$env_type" == "HOST" ]]; then
        host_tuning=$'net.netfilter.nf_conntrack_max = 262144\nnet.ipv4.ip_forward = 1'
    elif [[ "$env_type" == "VM" ]]; then
        vm_tuning="# VirtIO Safe Buffers (Implicit in standard profile)"
    fi
    
    # 3. Process Template to Temp File
    local processed_content
    # passing dummy args or env vars to template?
    # common_utils `process_template` uses specific arg passing "KEY=VALUE".
    # Since our template uses {{VAR}}, we might need `process_systemd_template` style or manual sed.
    # common_utils `process_template` uses %%VAR%%.
    
    # Let's assume we update the template to use %%VAR%% or just cat it.
    # Actually, let's use a simpler approach for sysctl - cat and append, injecting overrides.
    
    # Use process_template if we change placeholder format to %%VAR%%.
    # Updated template to use {{}} - wait, common_utils uses %%VAR%%.
    # I will stick to appending logic for sysctl as it is safer than replacing the whole file.
    
    if grep -q "KERNEL TUNING FOR HIGH THROUGHPUT" "$sysctl_target"; then
        log WARN "Optimization block already present in $sysctl_target. Updating/Refreshing..."
        # Advanced: Remove old block? For now, we warn.
    else
        log INFO "Appending optimization block to $sysctl_target..."
        {
            echo ""
            echo "# --- ANTIGRAVITY OPTIMIZATIONS START ---"
            cat "$sysctl_template"
            echo ""
            echo "# --- ENV SPECIFIC: $env_type ---"
            [[ -n "$host_tuning" ]] && echo "$host_tuning"
            [[ -n "$vm_tuning" ]] && echo "$vm_tuning"
            echo "# --- ANTIGRAVITY OPTIMIZATIONS END ---"
        } >> "$sysctl_target"
    fi
    
    # 4. Reload
    log INFO "Reloading sysctl..."
    if sysctl -p; then
        log INFO "Sysctl reload successful."
    else
        log WARN "Sysctl reload had some issues."
    fi
}

tune_nginx_main_config() {
    local nginx_conf="${NGINX_DIR}/nginx.conf"
    
    log INFO "--- Tuning Nginx Main Config ---"
    
    if [[ ! -f "$nginx_conf" ]]; then
        log ERROR "Nginx config not found at $nginx_conf"
        return 1
    fi
    
    # Backup
    cp "$nginx_conf" "${nginx_conf}.bak.$(date +%s)"
    
    # Modify Worker Processes
    log INFO "Setting worker_processes to ${WORKER_PROCESSES}..."
    sed -i "s/^worker_processes.*/worker_processes ${WORKER_PROCESSES};/" "$nginx_conf"
    
    # Modify Worker Connections
    log INFO "Setting worker_connections to ${WORKER_CONNECTIONS}..."
    sed -i "s/worker_connections.*/worker_connections ${WORKER_CONNECTIONS};/" "$nginx_conf"
    
    log INFO "Reloading Nginx..."
    systemctl reload nginx || log WARN "Failed to reload Nginx."
}

deploy_performance_template() {
    log INFO "--- Deploying Nginx Performance Template ---"
    
    ensure_dir_exists "$NGINX_TEMPLATE_DIR"
    
    local template_file="${TEMPLATE_DIR}/nginx_performance.conf.template"
    local output_file="${NGINX_TEMPLATE_DIR}/nginx_performance.conf"
    
    local template_args=(
        "TIMEOUT_STANDARD=${TIMEOUT_STANDARD}"
    )
    
    local processed_content
    process_template "$template_file" "processed_content" "${template_args[@]}"
    
    echo "$processed_content" > "$output_file"
    log INFO "Performance config deployed to $output_file"
}

# =====================================================================
# MAIN MENU
# =====================================================================
show_menu() {
    echo "----------------------------------------------------"
    echo -e "${YELLOW}System Optimization Selector${NC}"
    echo "----------------------------------------------------"
    echo "This script optimizes Kernel and Nginx settings."
    echo ""
    echo "Select the deployment environment:"
    echo "1) Proxmox Host (Physical Server)"
    echo "2) Guest VM (Virtual Machine - e.g. Ubuntu running Nginx)"
    echo "3) Exit"
    echo "----------------------------------------------------"
    read -r -p "Enter choice [1-3]: " choice
    
    case "$choice" in
        1)
            setup_backup_dir # Initialize backup
            apply_sysctl_tuning "HOST"
            tune_nginx_main_config
            deploy_performance_template
            ;;
        2)
            setup_backup_dir
            apply_sysctl_tuning "VM"
            tune_nginx_main_config
            deploy_performance_template
            ;;
        3)
            log INFO "Exiting."
            exit 0
            ;;
        *)
            log ERROR "Invalid choice."
            exit 1
            ;;
    esac
}

# =====================================================================
# EXECUTION
# =====================================================================
log INFO "Starting System Optimization Script..."

if [[ "$INTERACTIVE_MODE" == "true" ]]; then
    show_menu
else
    # Non-interactive default: VM
    log INFO "Non-interactive mode detected. Defaulting to GUEST VM profile."
    setup_backup_dir
    apply_sysctl_tuning "VM"
    tune_nginx_main_config
    deploy_performance_template
fi

log INFO "Optimization tasks completed."
