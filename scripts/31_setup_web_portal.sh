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

deploy_portal() {
    log "INFO" "Deploying Web Portal..."
    ensure_dir_exists "$WEB_ROOT"
    
    # Clean existing default nginx page if it exists (index.nginx-debian.html or simple index.html)
    if [[ -f "${WEB_ROOT}/index.nginx-debian.html" ]]; then rm -f "${WEB_ROOT}/index.nginx-debian.html"; fi
    
    local current_year; current_year=$(date +%Y)
    
    log "INFO" "Processing templates..."
    local html_content
    if ! process_template "${TEMPLATE_DIR}/portal_index.html.template" html_content "CURRENT_YEAR=${current_year}"; then
        handle_error 1 "Failed to process portal_index.html.template"
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
}

configure_rstudio_subpath() {
    log "INFO" "Reconfiguring RStudio for subpath /rstudio..."
    # Set the environment variable expected by the modified 03 script
    export RSTUDIO_ROOT_PATH="/rstudio"
    
    # Call the RStudio setup script function to update rserver.conf
    # We can source it or run it. Running it fully might be too much, but let's see.
    # Ideally we'd just call the specific function, but the script structure (main menu) makes that tricky unless we source it.
    
    # Alternative: Just modify the file directly here if we want to be independent.
    # But sticking to "Modify scripts/03..." plan implies utilizing that script.
    # Let's Modify 03 first to expose a non-interactive mode or function we can call?
    # Or just use sed here for simplicity if 03 isn't easily module-loadable?
    # The plan says "Modify scripts/03... to support www-root-path".
    # So I will assume I can run `scripts/03_rstudio_configuration_setup.sh --update-conf-only` or similar if I implement it,
    # OR, since I am writing this script now, I can just modify rserver.conf directly here as a "portal integration" step.
    
    local rserver_conf="/etc/rstudio/rserver.conf"
    if [[ -f "$rserver_conf" ]]; then
        if grep -q "^www-root-path=" "$rserver_conf"; then
            run_command "sed -i 's|^www-root-path=.*$|www-root-path=/rstudio|' '$rserver_conf'"
        else
            echo "www-root-path=/rstudio" >> "$rserver_conf"
        fi
        log "INFO" "RStudio configured for path /rstudio."
        run_command "Restart RStudio" "systemctl restart rstudio-server"
    else
        log "WARN" "RStudio config not found at $rserver_conf. Is RStudio installed?"
    fi
}

main() {
    log "INFO" "--- Starting Botanical Web Portal Setup ---"
    
    deploy_portal
    configure_rstudio_subpath
    
    log "INFO" "--- Web Portal Setup Complete ---"
    log "INFO" "Ensure Nginx is reloaded with the new proxy location config (run 05 scripts or verify nginx config)."
}

main "$@"
