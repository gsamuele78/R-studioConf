#!/bin/bash
# nginx_setup.sh - Nginx Configuration Script (for RStudio Proxy)
# This script automates Nginx installation and configuration to act as an
# SSL-terminating reverse proxy for RStudio Server.
# It supports self-signed certificates and Let's Encrypt.

# Determine the directory where this script resides
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# Define paths relative to SCRIPT_DIR
UTILS_SCRIPT_PATH="${SCRIPT_DIR}/common_utils.sh"
CONF_VARS_FILE="${SCRIPT_DIR}/conf/nginx_setup.vars.conf"
TEMPLATE_DIR="${SCRIPT_DIR}/templates" # Used by _get_template_content

# Source common utilities
if [[ ! -f "$UTILS_SCRIPT_PATH" ]]; then
    printf "Error: common_utils.sh not found at %s\n" "$UTILS_SCRIPT_PATH" >&2
    exit 1
fi
# shellcheck source=common_utils.sh
source "$UTILS_SCRIPT_PATH"

# Source configuration variables if file exists
if [[ -f "$CONF_VARS_FILE" ]]; then
    log "Sourcing Nginx configuration variables from $CONF_VARS_FILE"
    # shellcheck source=conf/nginx_setup.vars.conf
CONF_VARS_FILE="${SCRIPT_DIR}/../config/nginx_setup.vars.conf"
TEMPLATE_DIR="${SCRIPT_DIR}/../templates" # Used by _get_template_content
    log "Warning: Nginx configuration file $CONF_VARS_FILE not found. Using script internal defaults."
    # Define crucial defaults here from nginx_setup.vars.conf
    NGINX_CONF_PATH="/etc/nginx/nginx.conf"
    NGINX_SITES_AVAILABLE_DIR="/etc/nginx/sites-available"
    NGINX_SITES_ENABLED_DIR="/etc/nginx/sites-enabled"
    NGINX_RSTUDIO_SITE_FILE_NAME="default"
    NGINX_SNIPPETS_DIR="/etc/nginx/snippets"
    NGINX_SSL_SNIPPET_SELF_SIGNED_NAME="self-signed-rstudio.conf" # Make more specific
    NGINX_SSL_PARAMS_SNIPPET_NAME="ssl-params-rstudio.conf"     # Make more specific
    SSL_PRIVATE_DIR="/etc/ssl/private"
    SSL_CERTS_DIR="/etc/ssl/certs"
    SELF_SIGNED_KEY_FILENAME="nginx-rstudio-selfsigned.key"
    SELF_SIGNED_CERT_FILENAME="nginx-rstudio-selfsigned.crt"
    DHPARAM_FILENAME="dhparam-rstudio.pem"
    DHPARAM_BITS="2048"
    RSTUDIO_PROXY_TARGET_HOST="127.0.0.1"
    RSTUDIO_PROXY_TARGET_PORT="8787"
    SSL_CERT_COUNTRY="XX"; SSL_CERT_STATE="State"; SSL_CERT_LOCALITY="City"
    SSL_CERT_ORG="MyOrganization"; SSL_CERT_OU="RStudio Unit"
    WEBROOT_FOR_CERTBOT="/var/www/html"
fi

# --- Derived Paths (based on sourced config vars) ---
# Full path for the Nginx site config file for RStudio
NGINX_RSTUDIO_SITE_FULL_PATH="${NGINX_SITES_AVAILABLE_DIR}/${NGINX_RSTUDIO_SITE_FILE_NAME}"
# Full paths for generated SSL snippets
NGINX_SSL_SNIPPET_SELF_SIGNED_FULLPATH="${NGINX_SNIPPETS_DIR}/${NGINX_SSL_SNIPPET_SELF_SIGNED_NAME}"
NGINX_SSL_PARAMS_SNIPPET_FULLPATH="${NGINX_SNIPPETS_DIR}/${NGINX_SSL_PARAMS_SNIPPET_NAME}"
# Full paths for self-signed certificate components
SELF_SIGNED_KEY_FULLPATH="${SSL_PRIVATE_DIR}/${SELF_SIGNED_KEY_FILENAME}"
SELF_SIGNED_CERT_FULLPATH="${SSL_CERTS_DIR}/${SELF_SIGNED_CERT_FILENAME}"
# Place DHParam near nginx.conf or in snippets dir. Using /etc/nginx for simplicity.
DHPARAM_FULLPATH="${NGINX_CONF_PATH%/*}/${DHPARAM_FILENAME}"


# --- Nginx Specific Functions ---

# Ensures Nginx package is installed and service is enabled and running.
ensure_nginx_installed_running() {
    log "Ensuring Nginx is installed and running..."
    if ! command -v nginx &>/dev/null; then
        log "Nginx not found. Installing Nginx..."
        run_command "apt-get update -y && apt-get install -y nginx" || return 1
    fi
    if ! systemctl is-enabled --quiet nginx; then
        log "Nginx service not enabled. Enabling..."
        run_command "systemctl enable nginx" || return 1
    fi
    if ! systemctl is-active --quiet nginx; then
        log "Nginx service not active. Starting..."
        run_command "systemctl start nginx" || return 1
    fi
    log "Nginx is installed, service enabled and active."
    return 0 # Explicit success
}

# Configures the WebSocket map block in the main nginx.conf file.
configure_nginx_websocket_map() {
    log "Configuring Nginx WebSocket map in ${NGINX_CONF_PATH}"
    ensure_file_exists "${NGINX_CONF_PATH}" || return 1

    # Check if the map block is already present
    if grep -q "map \$http_upgrade \$connection_upgrade" "${NGINX_CONF_PATH}"; then
        log "WebSocket map already configured in ${NGINX_CONF_PATH}."
        return 0
    fi

    log "Adding WebSocket map to ${NGINX_CONF_PATH}..."
    local tmp_conf
    tmp_conf=$(mktemp) || { log "ERROR: Failed to create temp file for nginx.conf edit"; return 1; }
    
    # Use awk to insert the map block inside the http {} block, typically near the top.
    # SC2016: awk script uses $0, $http_upgrade, etc. which are awk variables, not shell.
    awk '
    BEGIN { added = 0 }
    # Match the line starting with "http" followed by optional whitespace and "{"
    !added && /^[[:space:]]*http[[:space:]]*\{/ {
        print $0  # Print the "http {" line itself
        # Print the map block after "http {"
        print ""
        print "    map $http_upgrade $connection_upgrade {"
        print "        default upgrade;"
        print "        \"\"      close;" # Double quotes need to be escaped for awk string
        print "    }"
        print ""
        added = 1 # Set flag to ensure it's added only once
        next      # Move to next line of input
    }
    { print $0 } # Print all other lines
    ' "${NGINX_CONF_PATH}" > "$tmp_conf"

    if [[ ! -s "$tmp_conf" ]]; then # Check if awk produced any output
        log "ERROR: awk processing of ${NGINX_CONF_PATH} failed, temp file is empty."
        rm -f "$tmp_conf"
        return 1
    fi

    run_command "cp \"${NGINX_CONF_PATH}\" \"${NGINX_CONF_PATH}.bak_ws_$(date +%Y%m%d_%H%M%S)\""
    run_command "mv \"$tmp_conf\" \"${NGINX_CONF_PATH}\"" # Apply changes
    log "WebSocket map added to ${NGINX_CONF_PATH}."
}

# Configures Nginx with a self-signed SSL certificate for RStudio proxy.
configure_nginx_self_signed_proxy() {
    log "Configuring Nginx with self-signed SSL for RStudio proxy..."
    ensure_nginx_installed_running || return 1
    configure_nginx_websocket_map || return 1 # Ensure WebSocket support is in nginx.conf

    # Ensure necessary directories exist
    ensure_dir_exists "${NGINX_SNIPPETS_DIR}" || return 1
    ensure_dir_exists "${SSL_PRIVATE_DIR}" || return 1
    ensure_dir_exists "${SSL_CERTS_DIR}" || return 1
    ensure_dir_exists "$(dirname "${DHPARAM_FULLPATH}")" || return 1


    # Generate self-signed certificate if it doesn't exist
    if [[ ! -f "$SELF_SIGNED_CERT_FULLPATH" ]] || [[ ! -f "$SELF_SIGNED_KEY_FULLPATH" ]]; then
        local cn_hostname; cn_hostname=$(hostname -f 2>/dev/null || hostname) # Get FQDN or hostname
        log "Generating self-signed certificate for CN=$cn_hostname..."
        # Construct subject line from config variables
        local subj_line="/C=${SSL_CERT_COUNTRY}/ST=${SSL_CERT_STATE}/L=${SSL_CERT_LOCALITY}/O=${SSL_CERT_ORG}/OU=${SSL_CERT_OU}/CN=${cn_hostname}"
        run_command "openssl req -x509 -nodes -days 3650 -newkey rsa:${DHPARAM_BITS} \
            -keyout \"${SELF_SIGNED_KEY_FULLPATH}\" -out \"${SELF_SIGNED_CERT_FULLPATH}\" \
            -subj \"${subj_line}\"" || return 1
    else
        log "Self-signed certificate already exists: ${SELF_SIGNED_CERT_FULLPATH}"
    fi

    # Generate Diffie-Hellman parameters if they don't exist
    if [[ ! -f "$DHPARAM_FULLPATH" ]]; then
        log "Generating DH parameters (${DHPARAM_BITS} bit), this may take a while..."
        # DHPARAM_BITS should be a number, so no need to quote for the command.
        run_command "openssl dhparam -out \"${DHPARAM_FULLPATH}\" ${DHPARAM_BITS}" || return 1
    else
        log "DH parameters file already exists: ${DHPARAM_FULLPATH}"
    fi

    # Create self-signed SSL snippet from template
    local self_signed_snippet_template_content
    self_signed_snippet_template_content=$(_get_template_content "nginx_self_signed_snippet.conf.template") || return 1
    local final_self_signed_snippet_conf
    final_self_signed_snippet_conf=$(apply_replacements "$self_signed_snippet_template_content" \
        "%%SELF_SIGNED_CERT_FULLPATH%%" "$SELF_SIGNED_CERT_FULLPATH" \
        "%%SELF_SIGNED_KEY_FULLPATH%%" "$SELF_SIGNED_KEY_FULLPATH" \
        "%%DHPARAM_FULLPATH%%" "$DHPARAM_FULLPATH" \
    )
    printf "%s" "$final_self_signed_snippet_conf" > "$NGINX_SSL_SNIPPET_SELF_SIGNED_FULLPATH" || { log "Failed to write $NGINX_SSL_SNIPPET_SELF_SIGNED_FULLPATH"; return 1; }
    
    # Create SSL parameters snippet from template
    local ssl_params_template_content
    ssl_params_template_content=$(_get_template_content "nginx_ssl_params.conf.template") || return 1
    # No placeholders in ssl_params_template for now, just copy content
    printf "%s" "$ssl_params_template_content" > "$NGINX_SSL_PARAMS_SNIPPET_FULLPATH" || { log "Failed to write $NGINX_SSL_PARAMS_SNIPPET_FULLPATH"; return 1; }
    log "Nginx SSL snippets created: $NGINX_SSL_SNIPPET_SELF_SIGNED_FULLPATH and $NGINX_SSL_PARAMS_SNIPPET_FULLPATH"

    # Create Nginx site configuration for self-signed proxy from template
    ensure_dir_exists "${NGINX_SITES_AVAILABLE_DIR}" || return 1
    local site_template_content
    site_template_content=$(_get_template_content "nginx_self_signed_site.conf.template") || return 1
    
    local proxy_location_template_content
    proxy_location_template_content=$(_get_template_content "nginx_proxy_location.conf.template") || return 1
    local final_proxy_location_block
    final_proxy_location_block=$(apply_replacements "$proxy_location_template_content" \
        "%%RSTUDIO_PROXY_TARGET_HOST%%" "${RSTUDIO_PROXY_TARGET_HOST}" \
        "%%RSTUDIO_PROXY_TARGET_PORT%%" "${RSTUDIO_PROXY_TARGET_PORT}" \
    )

    local final_site_conf
    final_site_conf=$(apply_replacements "$site_template_content" \
        "%%NGINX_SERVER_NAME%%" "_" \
        "%%NGINX_SSL_SNIPPET_SELF_SIGNED_FULLPATH%%" "$NGINX_SSL_SNIPPET_SELF_SIGNED_FULLPATH" \
        "%%NGINX_SSL_PARAMS_SNIPPET_FULLPATH%%" "$NGINX_SSL_PARAMS_SNIPPET_FULLPATH" \
        "%%NGINX_PROXY_LOCATION_BLOCK%%" "$final_proxy_location_block" \
    )
    printf "%s" "$final_site_conf" > "$NGINX_RSTUDIO_SITE_FULL_PATH" || { log "Failed to write $NGINX_RSTUDIO_SITE_FULL_PATH"; return 1; }
    
    # Ensure site is enabled if not using "default"
    if [[ "$NGINX_RSTUDIO_SITE_FILE_NAME" != "default" ]]; then
        local enabled_link="${NGINX_SITES_ENABLED_DIR}/${NGINX_RSTUDIO_SITE_FILE_NAME}"
        if [[ ! -L "$enabled_link" ]] || [[ "$(readlink "$enabled_link")" != "$NGINX_RSTUDIO_SITE_FULL_PATH" ]]; then
            run_command "ln -sf \"$NGINX_RSTUDIO_SITE_FULL_PATH\" \"$enabled_link\""
        fi
    fi
    
    log "Nginx site configured for RStudio proxy (self-signed SSL) at $NGINX_RSTUDIO_SITE_FULL_PATH."
    if ! run_command "nginx -t"; then log "Nginx config test failed."; return 1; fi
    run_command "systemctl reload nginx"; log "Nginx reloaded with new configuration."
}

# Configures Nginx with Let's Encrypt SSL certificate for RStudio proxy.
configure_nginx_letsencrypt_proxy() {
    log "Configuring Nginx with Let's Encrypt SSL for RStudio proxy..."
    ensure_nginx_installed_running || return 1
    configure_nginx_websocket_map || return 1

    if ! command -v certbot &>/dev/null; then
        log "Certbot not found. Installing Certbot and Nginx plugin..."
        run_command "apt-get update -y && apt-get install -y certbot python3-certbot-nginx" || return 1
    fi

    local fqdn email
    read -r -p "Enter your Fully Qualified Domain Name (FQDN) (e.g., rstudio.example.com): " fqdn
    if [[ -z "$fqdn" ]]; then log "ERROR: FQDN cannot be empty."; return 1; fi
    read -r -p "Enter your email address for Let's Encrypt registration (e.g., admin@example.com): " email
    if [[ -z "$email" ]]; then log "ERROR: Email address cannot be empty."; return 1; fi

    ensure_dir_exists "${NGINX_SITES_AVAILABLE_DIR}" || return 1
    ensure_dir_exists "${WEBROOT_FOR_CERTBOT}" || return 1 # For HTTP-01 challenge
    
    # Create initial HTTP site config for Certbot from template
    local http_site_template_content
    http_site_template_content=$(_get_template_content "nginx_letsencrypt_http_site.conf.template") || return 1
    local final_http_site_conf
    final_http_site_conf=$(apply_replacements "$http_site_template_content" \
        "%%FQDN%%" "$fqdn" \
        "%%WEBROOT_FOR_CERTBOT%%" "${WEBROOT_FOR_CERTBOT}" \
    )
    
    # Certbot works best if it modifies a file specific to the FQDN, or 'default' if that's the target.
    local target_le_conf_path="${NGINX_SITES_AVAILABLE_DIR}/${fqdn}.conf" # Prefer FQDN specific file
    if [[ "${NGINX_RSTUDIO_SITE_FILE_NAME}" == "default" ]]; then
        target_le_conf_path="${NGINX_RSTUDIO_SITE_FULL_PATH}" # Use the configured default file
    fi

    printf "%s" "$final_http_site_conf" > "$target_le_conf_path" || { log "Failed to write HTTP site config for Certbot to $target_le_conf_path"; return 1; }
    
    # Ensure site is enabled
    local enabled_link="${NGINX_SITES_ENABLED_DIR}/$(basename "$target_le_conf_path")"
    if [[ ! -L "$enabled_link" ]] || [[ "$(readlink "$enabled_link")" != "$target_le_conf_path" ]]; then
         run_command "ln -sf \"$target_le_conf_path\" \"$enabled_link\""
    fi

    log "Initial Nginx HTTP site for $fqdn created/updated at $target_le_conf_path. Testing and reloading Nginx..."
    if ! run_command "nginx -t"; then log "Initial Nginx config for Certbot failed test."; return 1; fi
    run_command "systemctl reload nginx"

    log "Requesting Let's Encrypt certificate for $fqdn..."
    # Using --nginx plugin. Certbot will attempt to find the correct server block for $fqdn.
    # --cert-name "$fqdn" helps manage renewals if multiple certs exist.
    local certbot_cmd="certbot --nginx -d \"$fqdn\" --non-interactive --agree-tos --email \"$email\" --redirect --hsts --uir --staple-ocsp --cert-name \"$fqdn\""
    if ! run_command "$certbot_cmd"; then
        log "Certbot failed. Command was: $certbot_cmd"
        log "Check /var/log/letsencrypt/letsencrypt.log. Ensure DNS for $fqdn is correct and ports 80/443 are open."
        return 1
    fi
    
    log "Certbot successful. Ensuring RStudio proxy location and SSL params in SSL server block for $fqdn."
    # Certbot should have modified target_le_conf_path.
    # Now, ensure our RStudio proxy settings are within the SSL server block Certbot configured.
    if ! grep -q "proxy_pass http://${RSTUDIO_PROXY_TARGET_HOST}:${RSTUDIO_PROXY_TARGET_PORT}" "$target_le_conf_path"; then
        log "RStudio proxy_pass directive not found in $target_le_conf_path after Certbot. Attempting to add it."
        local proxy_location_template_content
        proxy_location_template_content=$(_get_template_content "nginx_proxy_location.conf.template") || return 1
        local final_proxy_location_block
        final_proxy_location_block=$(apply_replacements "$proxy_location_template_content" \
            "%%RSTUDIO_PROXY_TARGET_HOST%%" "${RSTUDIO_PROXY_TARGET_HOST}" \
            "%%RSTUDIO_PROXY_TARGET_PORT%%" "${RSTUDIO_PROXY_TARGET_PORT}" \
        )
        # Add inside the server block modified/created by certbot (usually the one with ssl_certificate /etc/letsencrypt/live/$fqdn/)
        # This sed is a heuristic. It looks for the end of the server block that contains the certbot SSL cert line.
        if ! sed -i "/server[[:space:]]*{[^}]*ssl_certificate[[:space:]]*\/etc\/letsencrypt\/live\/${fqdn}\//,/^}/ s|^\([[:space:]]*\)}|${final_proxy_location_block}\n\1}|" "$target_le_conf_path"; then
            log "Warning: Failed to automatically add RStudio proxy block to $target_le_conf_path. Manual configuration might be needed."
        else
            log "RStudio proxy block likely added to $target_le_conf_path."
        fi
    fi
    # Ensure our strong SSL parameters snippet is included
    if ! grep -q "${NGINX_SSL_PARAMS_SNIPPET_NAME}" "$target_le_conf_path" && [[ -f "$NGINX_SSL_PARAMS_SNIPPET_FULLPATH" ]]; then
        log "Ensuring strong SSL parameters snippet is included in Certbot's configuration for $fqdn..."
        # Add it after the ssl_certificate_key line.
        run_command "sed -i '/ssl_certificate_key[[:space:]]*\/etc\/letsencrypt\/live\/${fqdn}\//a \    include ${NGINX_SSL_PARAMS_SNIPPET_FULLPATH};' \"$target_le_conf_path\""
    fi

    log "Testing final Nginx configuration..."; if ! run_command "nginx -t"; then log "Nginx config test failed after Certbot modifications."; return 1; fi
    run_command "systemctl reload nginx"; log "Nginx reloaded with Let's Encrypt SSL for $fqdn. Auto-renewal should be active."
}

# Uninstalls Nginx configurations made by this script.
uninstall_nginx_configs() {
    log "Uninstalling Nginx configurations..."; backup_config # Backup before uninstalling

    if systemctl is-active --quiet nginx; then run_command "systemctl stop nginx"; fi
    if systemctl is-enabled --quiet nginx; then run_command "systemctl disable nginx"; fi

    local confirm_pkg
    read -r -p "Remove Nginx package (apt remove --purge nginx nginx-common)? (y/n): " confirm_pkg
    if [[ "$confirm_pkg" == "y" || "$confirm_pkg" == "Y" ]]; then
        if dpkg -l | grep -q 'nginx'; then # Check if package is installed
            run_command "apt-get remove --purge -y nginx nginx-common nginx-core"
        else log "Nginx package not found, skipping removal."; fi
    else log "Skipping Nginx package removal."; fi

    log "Removing Nginx configuration files/snippets added or modified by this script..."
    run_command "rm -f ${NGINX_RSTUDIO_SITE_FULL_PATH}"
    # Also remove FQDN-specific file if created by Let's Encrypt part
    # This is a bit heuristic, assumes FQDN was entered for LE
    # A more robust way would be to track files created.
    # For now, if NGINX_RSTUDIO_SITE_FILE_NAME was "default", this is covered.
    # If it was custom, and LE used another FQDN.conf, that FQDN.conf might remain.
    # The LE uninstall part should ideally remove the cert with certbot delete.
    
    # Remove symlink if it points to our managed file
    local enabled_site_link_path="${NGINX_SITES_ENABLED_DIR}/${NGINX_RSTUDIO_SITE_FILE_NAME}"
    if [[ -L "$enabled_site_link_path" ]] && [[ "$(readlink "$enabled_site_link_path")" == "$NGINX_RSTUDIO_SITE_FULL_PATH" ]]; then
        run_command "rm -f \"$enabled_site_link_path\""
    fi
    # Remove FQDN specific symlink if created by LE part
    # This requires knowing the FQDN. For simplicity, this is left to manual cleanup or better tracking.

    run_command "rm -f $NGINX_SSL_SNIPPET_SELF_SIGNED_FULLPATH $NGINX_SSL_PARAMS_SNIPPET_FULLPATH"
    run_command "rm -f $SELF_SIGNED_KEY_FULLPATH $SELF_SIGNED_CERT_FULLPATH $DHPARAM_FULLPATH"
    
    # Revert nginx.conf WebSocket map (best effort: restore backup or manual edit)
    local nginx_conf_ws_bak; nginx_conf_ws_bak=$(ls -t "${NGINX_CONF_PATH}.bak_ws_"* 2>/dev/null | head -1)
    if [[ -f "$nginx_conf_ws_bak" ]]; then
        log "Found WebSocket backup $nginx_conf_ws_bak."
        read -r -p "Restore $NGINX_CONF_PATH from this backup to remove WebSocket map? (y/n): " confirm_restore_ws
        if [[ "$confirm_restore_ws" == "y" || "$confirm_restore_ws" == "Y" ]]; then
            run_command "cp \"$nginx_conf_ws_bak\" \"$NGINX_CONF_PATH\"" && log "$NGINX_CONF_PATH restored from WebSocket backup."
        else
            log "Manual edit of $NGINX_CONF_PATH might be needed to remove WebSocket map block."
        fi
    else
        log "No specific WebSocket map backup found. Manual edit of $NGINX_CONF_PATH might be needed."
    fi
    log "Nginx configurations uninstalled. Let's Encrypt certificates in /etc/letsencrypt are NOT automatically removed (use 'certbot delete' for that)."
}

# Main menu for Nginx setup operations.
main_nginx_menu() {
    while true; do
        printf "\n===== Nginx Configuration Menu (RStudio Proxy) =====\n"
        printf " (Ensure RStudio is running on %s:%s before Nginx setup)\n" "${RSTUDIO_PROXY_TARGET_HOST}" "${RSTUDIO_PROXY_TARGET_PORT}"
        printf "1. Configure Nginx with Self-Signed SSL for RStudio\n"
        printf "2. Configure Nginx with Let's Encrypt SSL for RStudio\n"
        printf -- "----------------------------------------------------\n"
        printf "3. Uninstall Nginx Configurations (optional package removal)\n"
        printf "4. Restore All Configurations from Last Backup\n"
        printf "5. Exit\n"
        printf "========================================================\n"
        read -r -p "Enter choice: " choice

        if [[ "$choice" == "1" || "$choice" == "2" ]]; then
            local rstudio_listening_cmd="netstat -tuln" # Fallback
            if command -v ss &>/dev/null; then rstudio_listening_cmd="ss -tuln"; fi # Prefer ss if available
            # Check if RStudio is listening on the configured port
            if ! $rstudio_listening_cmd | grep -q ":${RSTUDIO_PROXY_TARGET_PORT}[[:space:]].*LISTEN"; then
                log "Warning: RStudio Server does not appear to be listening on ${RSTUDIO_PROXY_TARGET_HOST}:${RSTUDIO_PROXY_TARGET_PORT}."
                local confirm_proceed
                read -r -p "Nginx proxy setup might fail or not work as expected. Continue? (y/n): " confirm_proceed
                if [[ "$confirm_proceed" != "y" && "$confirm_proceed" != "Y" ]]; then
                    continue # Go back to menu
                fi
            fi
        fi
        
        case $choice in
            1) backup_config && configure_nginx_self_signed_proxy ;;
            2) backup_config && configure_nginx_letsencrypt_proxy ;;
            3) uninstall_nginx_configs ;; # backup_config is called within this function
            4) restore_config ;;
            5) log "Exiting Nginx Setup."; break ;;
            *) printf "Invalid choice. Please try again.\n" ;;
        esac
        if [[ "$choice" != "5" ]]; then
            read -r -p "Press Enter to continue..."
        fi
    done
}

# --- Script Entry Point ---
log "=== Nginx Setup Script Started ==="
# SCRIPT_DIR is defined at the top, available for common_utils.sh backup
setup_backup_dir # Initialize a unique backup directory for this script session
main_nginx_menu
log "=== Nginx Setup Script Finished ==="
