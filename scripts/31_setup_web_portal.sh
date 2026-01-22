#!/bin/bash
# 09_web_portal_setup.sh - Setup Botanical Big Data Calculus Web Portal
# Deploys the web portal to /var/www/html and configures Nginx/RStudio integration.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
UTILS_SCRIPT_PATH="${SCRIPT_DIR}/../lib/common_utils.sh"
TEMPLATE_DIR="${SCRIPT_DIR}/../templates"
ASSETS_DIR="${SCRIPT_DIR}/../assets"
WEB_ROOT="/var/www/html"

if [[ ! -f "$UTILS_SCRIPT_PATH" ]]; then
    echo "Error: common_utils.sh not found at $UTILS_SCRIPT_PATH" >&2
    exit 1
fi
source "$UTILS_SCRIPT_PATH"

LOG_FILE="/var/log/botanical/portal_setup.log"

setup_logging() {
    mkdir -p "$(dirname "$LOG_FILE")"
    exec > >(tee -a "$LOG_FILE") 2>&1
    log "INFO" "--- Setup Started: $(date) ---"
}

uninstall_portal() {
    log "WARN" "Starting Portal Uninstallation..."
    
    # 1. Remove files
    log "INFO" "Removing portal files..."
    rm -f "${WEB_ROOT}/index.html" "${WEB_ROOT}/style.css" "${WEB_ROOT}/logo.png" "${WEB_ROOT}/background.png"
    

    log "INFO" "Uninstallation complete. Note: Nginx proxy config remains active (serving 404/403 on root)."
    log "INFO" "To restore Nginx to default, verify /etc/nginx/sites-enabled configuration."
}

deploy_portal() {
    local template_name="$1" # e.g., portal_index.html.template or portal_index_simple.html.template
    if [[ -z "$template_name" ]]; then
        template_name="portal_index.html.template"
    fi

    log "INFO" "Deploying Web Portal using template: $template_name..."
    ensure_dir_exists "$WEB_ROOT"
    
    # Clean existing default nginx page if it exists (index.nginx-debian.html or simple index.html)
    # Only remove if we are deploying, to avoid conflicts.
    if [[ -f "${WEB_ROOT}/index.nginx-debian.html" ]]; then rm -f "${WEB_ROOT}/index.nginx-debian.html"; fi
    
    local current_year; current_year=$(date +%Y)
    
    log "INFO" "Processing templates..."
    local html_content
    if ! process_template "${TEMPLATE_DIR}/${template_name}" html_content "CURRENT_YEAR=${current_year}"; then
        handle_error 1 "Failed to process ${template_name}"
        return 1
    fi
    echo "$html_content" > "${WEB_ROOT}/index.html"
    
    local css_content
    if ! process_template "${TEMPLATE_DIR}/portal_style.css.template" css_content; then
         handle_error 1 "Failed to process portal_style.css.template"
         return 1
    fi
    echo "$css_content" > "${WEB_ROOT}/style.css"
    
    log "INFO" "Deploying Assets..."
    if [[ -f "${ASSETS_DIR}/logo.png" ]]; then
        cp "${ASSETS_DIR}/logo.png" "${WEB_ROOT}/logo.png"
    else
        log "WARN" "Logo asset not found at ${ASSETS_DIR}/logo.png"
    fi
    
    if [[ -f "${ASSETS_DIR}/background.png" ]]; then
        cp "${ASSETS_DIR}/background.png" "${WEB_ROOT}/background.png"
    else
        log "WARN" "Background asset not found at ${ASSETS_DIR}/background.png"
    fi
    
    run_command "Set permissions for web root" "chown -R www-data:www-data ${WEB_ROOT} && chmod -R 755 ${WEB_ROOT}"
    
    log "INFO" "Portal deployed successfully to ${WEB_ROOT}."

    log "INFO" "Deploying Application Wrappers (Iframe Architecture)..."
    
    # Terminal Wrapper
    if [[ -f "${TEMPLATE_DIR}/terminal_wrapper.html.template" ]]; then
        ensure_dir_exists "${WEB_ROOT}/terminal"
        cp "${TEMPLATE_DIR}/terminal_wrapper.html.template" "${WEB_ROOT}/terminal/index.html"
        log "INFO" "Deployed Terminal Wrapper."
    else
        log "WARN" "Terminal wrapper template not found."
    fi

    # RStudio Wrapper
    if [[ -f "${TEMPLATE_DIR}/rstudio_wrapper.html.template" ]]; then
        ensure_dir_exists "${WEB_ROOT}/rstudio"
        cp "${TEMPLATE_DIR}/rstudio_wrapper.html.template" "${WEB_ROOT}/rstudio/index.html"
        log "INFO" "Deployed RStudio Wrapper."
    else
        log "WARN" "RStudio wrapper template not found."
    fi

    # Nextcloud Wrapper
    if [[ -f "${TEMPLATE_DIR}/nextcloud_wrapper.html.template" ]]; then
        ensure_dir_exists "${WEB_ROOT}/files"
        cp "${TEMPLATE_DIR}/nextcloud_wrapper.html.template" "${WEB_ROOT}/files/index.html"
        log "INFO" "Deployed Nextcloud Wrapper."
    else
        log "WARN" "Nextcloud wrapper template not found."
    fi

    # Set permissions for all wrappers
    run_command "Set permissions for web root" "chown -R www-data:www-data ${WEB_ROOT} && chmod -R 755 ${WEB_ROOT}"
}


show_help() {
    echo "Usage: $0 [--uninstall]"
    echo "  --uninstall   Remove the portal files (HTML/CSS/Images)."
    echo "  (No arguments) Deploys the web portal files to $WEB_ROOT."
}

show_menu() {
    echo ""
    printf "\n=== Botanical Web Portal Setup ===\n"
    printf "1) Deploy Secure Web Portal (Front-end Auth Lock)\n"
    printf "2) Deploy Simple Web Portal (Direct Links, No Lock)\n"
    printf "3) Uninstall Web Portal\n"
    printf "4) Exit\n"
    read -r -p "Choice: " choice
    
    case "$choice" in
        1)
            log "INFO" "--- Starting Secure Web Portal Setup ---"
            deploy_portal "portal_index.html.template"
            log "INFO" "--- Web Portal Setup Complete ---"
            ;;
        2)
            log "INFO" "--- Starting Simple Web Portal Setup ---"
            deploy_portal "portal_index_simple.html.template"
            log "INFO" "--- Web Portal Setup Complete ---"
            ;;
        3)
            uninstall_portal
            ;;
        4)
            log "INFO" "Exiting."
            exit 0
            ;;
        *)
            echo "Invalid option."
            show_menu
            ;;
    esac
    
    if [[ "$choice" == "1" || "$choice" == "2" ]]; then
        log "INFO" "Logs saved to: $LOG_FILE"
        log "INFO" "Ensure Nginx is reloaded (run scripts/30_install_nginx.sh or 'systemctl restart nginx')."
        log "INFO" "NOTE: Static Portal configured."
    fi
}

main() {
    setup_logging
    
    if [[ "$1" == "--uninstall" ]]; then
        uninstall_portal
        exit 0
    elif [[ "$1" == "--help" || "$1" == "-h" ]]; then
        show_help
        exit 0
    else
        show_menu
    fi
}

main "$@"
