#!/bin/bash
# nginx_setup.sh - Nginx Configuration Script (for RStudio Proxy)

UTILS_SCRIPT_PATH="$(dirname "$0")/common_utils.sh"
if [[ ! -f "$UTILS_SCRIPT_PATH" ]]; then
    echo "Error: common_utils.sh not found at $UTILS_SCRIPT_PATH" >&2
    exit 1
fi
# shellcheck source=common_utils.sh
source "$UTILS_SCRIPT_PATH"

# --- CONFIGURATION VARIABLES ---
NGINX_CONF_PATH="/etc/nginx/nginx.conf"
NGINX_SITES_AVAILABLE_DIR="/etc/nginx/sites-available"
NGINX_DEFAULT_SITE_FILE="$NGINX_SITES_AVAILABLE_DIR/default"
NGINX_SNIPPETS_DIR="/etc/nginx/snippets"
NGINX_SSL_SNIPPET_SELF_SIGNED="$NGINX_SNIPPETS_DIR/self-signed.conf"
NGINX_SSL_PARAMS_SNIPPET="$NGINX_SNIPPETS_DIR/ssl-params.conf"
SSL_PRIVATE_DIR="/etc/ssl/private"
SSL_CERTS_DIR="/etc/ssl/certs"
SELF_SIGNED_KEY_PATH="$SSL_PRIVATE_DIR/nginx-selfsigned.key"
SELF_SIGNED_CERT_PATH="$SSL_CERTS_DIR/nginx-selfsigned.crt"
DHPARAM_PATH="/etc/nginx/dhparam.pem"
DHPARAM_BITS="2048"
RSTUDIO_PROXY_TARGET_HOST="127.0.0.1"
RSTUDIO_PROXY_TARGET_PORT="8787"
SSL_CERT_COUNTRY="XX"; SSL_CERT_STATE="State"; SSL_CERT_LOCALITY="City"
SSL_CERT_ORG="Organization"; SSL_CERT_OU="Unit"
WEBROOT_FOR_CERTBOT="/var/www/html" # Default webroot for Certbot challenges
# --- END CONFIGURATION VARIABLES ---

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
}

configure_nginx_websocket_map() {
    log "Configuring Nginx WebSocket map in $NGINX_CONF_PATH..."
    ensure_file_exists "$NGINX_CONF_PATH" || return 1
    if grep -q "map \$http_upgrade \$connection_upgrade" "$NGINX_CONF_PATH"; then
        log "WebSocket map already configured in $NGINX_CONF_PATH."; return 0; fi
    log "Adding WebSocket map to $NGINX_CONF_PATH..."
    local tmp_conf; tmp_conf=$(mktemp) || { log "Failed to create temp file for nginx.conf edit"; return 1; }
    # SC2016: Expressions in single quotes are not expanded. This is intended here for awk.
    awk 'BEGIN { added = 0 } !added && /^[ \t]*http[ \t]*{/ { print $0; print ""; print "    map $http_upgrade $connection_upgrade {"; print "        default upgrade;"; print "        \"\"      close;"; print "    }"; print ""; added = 1; next } { print $0 }' "$NGINX_CONF_PATH" > "$tmp_conf"
    if [[ ! -s "$tmp_conf" ]]; then log "Error: awk processing of $NGINX_CONF_PATH failed."; rm -f "$tmp_conf"; return 1; fi
    run_command "cp \"$NGINX_CONF_PATH\" \"${NGINX_CONF_PATH}.bak_ws_$(date +%Y%m%d_%H%M%S)\""
    run_command "mv \"$tmp_conf\" \"$NGINX_CONF_PATH\""
    log "WebSocket map added to $NGINX_CONF_PATH."
}

_generate_nginx_rstudio_proxy_location_block() {
    cat <<EOF_PROXY_LOCATION
    location / {
        proxy_pass http://$RSTUDIO_PROXY_TARGET_HOST:$RSTUDIO_PROXY_TARGET_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade; # Corrected from \$connection_upgrade;
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_redirect http://$RSTUDIO_PROXY_TARGET_HOST:$RSTUDIO_PROXY_TARGET_PORT/ \$scheme://\$host/;
        proxy_read_timeout 20d;
        proxy_buffering off;
    }
EOF_PROXY_LOCATION
}

configure_nginx_self_signed_proxy() {
    log "Configuring Nginx with self-signed SSL for RStudio proxy..."
    ensure_nginx_installed_running || return 1
    configure_nginx_websocket_map || return 1
    ensure_dir_exists "$NGINX_SNIPPETS_DIR" || return 1
    ensure_dir_exists "$SSL_PRIVATE_DIR" || return 1
    ensure_dir_exists "$SSL_CERTS_DIR" || return 1

    if [[ ! -f "$SELF_SIGNED_CERT_PATH" ]] || [[ ! -f "$SELF_SIGNED_KEY_PATH" ]]; then
        local cn_hostname; cn_hostname=$(hostname -f 2>/dev/null || hostname)
        log "Generating self-signed certificate for CN=$cn_hostname..."
        local subj_line="/C=$SSL_CERT_COUNTRY/ST=$SSL_CERT_STATE/L=$SSL_CERT_LOCALITY/O=$SSL_CERT_ORG/OU=$SSL_CERT_OU/CN=${cn_hostname}"
        run_command "openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
            -keyout \"$SELF_SIGNED_KEY_PATH\" -out \"$SELF_SIGNED_CERT_PATH\" \
            -subj \"$subj_line\"" || return 1
    else log "Self-signed certificate exists: $SELF_SIGNED_CERT_PATH"; fi

    if [[ ! -f "$DHPARAM_PATH" ]]; then
        log "Generating DH parameters ($DHPARAM_BITS bit)...";
        run_command "openssl dhparam -out \"$DHPARAM_PATH\" $DHPARAM_BITS" || return 1
    else log "DH parameters file exists: $DHPARAM_PATH"; fi

    cat <<EOF_SSL_SNIPPET > "$NGINX_SSL_SNIPPET_SELF_SIGNED"
ssl_certificate $SELF_SIGNED_CERT_PATH;
ssl_certificate_key $SELF_SIGNED_KEY_PATH;
ssl_dhparam $DHPARAM_PATH;
EOF_SSL_SNIPPET

    cat <<EOF_SSL_PARAMS > "$NGINX_SSL_PARAMS_SNIPPET"
ssl_protocols TLSv1.2 TLSv1.3;
ssl_prefer_server_ciphers on;
ssl_ciphers 'ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256';
ssl_ecdh_curve X25519:secp384r1; # Modern curves first
ssl_session_timeout '10m';
ssl_session_cache shared:SSL:10m;
ssl_session_tickets off;
add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
add_header X-Content-Type-Options nosniff always;
add_header X-Frame-Options DENY always;
add_header X-XSS-Protection "1; mode=block" always;
EOF_SSL_PARAMS
    log "Nginx SSL snippets created."

    ensure_dir_exists "$NGINX_SITES_AVAILABLE_DIR" || return 1
    local proxy_location_config; proxy_location_config=$(_generate_nginx_rstudio_proxy_location_block)
    cat <<EOF_NGINX_DEFAULT_SITE > "$NGINX_DEFAULT_SITE_FILE"
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl http2 default_server;
    listen [::]:443 ssl http2 default_server;
    server_name _;
    include $NGINX_SSL_SNIPPET_SELF_SIGNED;
    include $NGINX_SSL_PARAMS_SNIPPET;
    access_log /var/log/nginx/rstudio_access.log;
    error_log /var/log/nginx/rstudio_error.log warn;
${proxy_location_config}
}
EOF_NGINX_DEFAULT_SITE
    log "Nginx site configured for RStudio proxy (self-signed SSL) at $NGINX_DEFAULT_SITE_FILE."
    if ! run_command "nginx -t"; then log "Nginx config test failed."; return 1; fi
    run_command "systemctl reload nginx"; log "Nginx reloaded."
}

configure_nginx_letsencrypt_proxy() {
    log "Configuring Nginx with Let's Encrypt SSL for RStudio proxy..."
    ensure_nginx_installed_running || return 1
    configure_nginx_websocket_map || return 1
    if ! command -v certbot &>/dev/null; then
        log "Certbot not found. Installing Certbot and Nginx plugin..."
        run_command "apt-get update -y && apt-get install -y certbot python3-certbot-nginx" || return 1
    fi

    local fqdn; read -r -p "Enter your FQDN (e.g., rstudio.example.com): " fqdn
    if [[ -z "$fqdn" ]]; then log "FQDN cannot be empty."; return 1; fi
    local email; read -r -p "Enter your email for Let's Encrypt (e.g., admin@example.com): " email
    if [[ -z "$email" ]]; then log "Email cannot be empty."; return 1; fi

    ensure_dir_exists "$NGINX_SITES_AVAILABLE_DIR" || return 1
    # local proxy_location_config; proxy_location_config=$(_generate_nginx_rstudio_proxy_location_block) # Certbot will create its own server block
    
    # Basic HTTP server block for Certbot's initial challenge. Certbot will then create/modify HTTPS block.
    cat <<EOF_NGINX_CERTBOT_HTTP_SITE > "$NGINX_DEFAULT_SITE_FILE"
server {
    listen 80; # Certbot needs port 80 for HTTP-01. For default_server, add it if this is the only site.
    listen [::]:80;
    server_name $fqdn;
    root $WEBROOT_FOR_CERTBOT; # Certbot will place challenge files here

    location /.well-known/acme-challenge/ {
        allow all;
    }
    # Optional: redirect to HTTPS after cert is obtained (Certbot can also do this)
    # location / {
    #    return 301 https://\$host\$request_uri;
    # }
}
EOF_NGINX_CERTBOT_HTTP_SITE
    ensure_dir_exists "$WEBROOT_FOR_CERTBOT" # Create webroot if it doesn't exist
    log "Initial Nginx HTTP site for $fqdn created at $NGINX_DEFAULT_SITE_FILE. Testing and reloading Nginx..."
    if ! run_command "nginx -t"; then log "Initial Nginx config for Certbot failed test."; return 1; fi
    run_command "systemctl reload nginx"

    log "Requesting Let's Encrypt certificate for $fqdn..."
    local certbot_cmd="certbot --nginx -d \"$fqdn\" --non-interactive --agree-tos --email \"$email\" --redirect --hsts --uir --staple-ocsp"
    if ! run_command "$certbot_cmd"; then
        log "Certbot failed. CMD: $certbot_cmd"; return 1; fi
    
    # Certbot should have modified the Nginx config (NGINX_DEFAULT_SITE_FILE or a new one for the FQDN).
    # Now, ensure our RStudio proxy settings are within the SSL server block Certbot configured.
    log "Certbot successful. Attempting to add/ensure RStudio proxy location in SSL server block for $fqdn."
    local nginx_conf_file_for_fqdn # Certbot might create a new file or modify default
    nginx_conf_file_for_fqdn=$(grep -rl "server_name ${fqdn};" /etc/nginx/sites-enabled/ /etc/nginx/sites-available/ | head -n 1)
    if [[ -z "$nginx_conf_file_for_fqdn" ]]; then nginx_conf_file_for_fqdn="$NGINX_DEFAULT_SITE_FILE"; fi

    if ! grep -q "proxy_pass http://$RSTUDIO_PROXY_TARGET_HOST:$RSTUDIO_PROXY_TARGET_PORT" "$nginx_conf_file_for_fqdn"; then
        log "RStudio proxy_pass directive not found in $nginx_conf_file_for_fqdn. Attempting to add it."
        local proxy_block_content; proxy_block_content=$(_generate_nginx_rstudio_proxy_location_block)
        # This sed attempts to add the proxy block inside the first 'server {' block that has SSL directives.
        # It's a heuristic and might need adjustment for very complex Nginx configs.
        if ! sed -i "/server[[:space:]]*{[^}]*ssl_certificate[[:space:]]*\/etc\/letsencrypt\/live\/${fqdn}\//,/}/ s|}|${proxy_block_content}\n}|" "$nginx_conf_file_for_fqdn"; then
            log "Warning: Failed to automatically add RStudio proxy block to $nginx_conf_file_for_fqdn. Manual configuration might be needed."
        else
            log "RStudio proxy block added to $nginx_conf_file_for_fqdn."
        fi
    else
        log "RStudio proxy_pass seems to be already configured in $nginx_conf_file_for_fqdn."
    fi

    log "Testing final Nginx configuration..."; if ! run_command "nginx -t"; then log "Nginx config test failed after Certbot."; return 1; fi
    run_command "systemctl reload nginx"; log "Nginx reloaded with Let's Encrypt SSL for $fqdn."
}

uninstall_nginx_configs() {
    log "Uninstalling Nginx configurations..."; backup_config
    if systemctl is-active --quiet nginx; then run_command "systemctl stop nginx"; fi
    if systemctl is-enabled --quiet nginx; then run_command "systemctl disable nginx"; fi
    read -r -p "Remove Nginx package (apt remove --purge nginx nginx-common)? (y/n): " confirm_pkg
    if [[ "$confirm_pkg" == "y" || "$confirm_pkg" == "Y" ]]; then
        if dpkg -l | grep -q 'nginx'; then run_command "apt-get remove --purge -y nginx nginx-common nginx-core"
        else log "Nginx package not found."; fi
    else log "Skipping Nginx package removal."; fi
    log "Removing Nginx configuration files/snippets added by this script..."
    run_command "rm -f $NGINX_DEFAULT_SITE_FILE $NGINX_SITES_AVAILABLE_DIR/default.rpmsave $NGINX_SITES_AVAILABLE_DIR/default.bak"
    if [[ -L "/etc/nginx/sites-enabled/default" ]] && [[ "$(readlink /etc/nginx/sites-enabled/default)" == "$NGINX_DEFAULT_SITE_FILE" ]]; then
        run_command "rm -f /etc/nginx/sites-enabled/default"; fi
    run_command "rm -f $NGINX_SSL_SNIPPET_SELF_SIGNED $NGINX_SSL_PARAMS_SNIPPET"
    run_command "rm -f $SELF_SIGNED_KEY_PATH $SELF_SIGNED_CERT_PATH $DHPARAM_PATH"
    local nginx_conf_ws_bak; nginx_conf_ws_bak=$(ls -t "${NGINX_CONF_PATH}.bak_ws_"* 2>/dev/null | head -1)
    if [[ -f "$nginx_conf_ws_bak" ]]; then log "Found WebSocket backup $nginx_conf_ws_bak. Manual restore/edit of $NGINX_CONF_PATH might be needed to remove map block."; fi
    log "Nginx configs uninstalled. Let's Encrypt certs in /etc/letsencrypt NOT removed (managed by Certbot)."
}

main_nginx_menu() {
    while true; do
        printf "\n===== Nginx Configuration Menu (RStudio Proxy) =====\n"
        printf " (Ensure RStudio is running on %s:%s before Nginx setup)\n" "$RSTUDIO_PROXY_TARGET_HOST" "$RSTUDIO_PROXY_TARGET_PORT"
        printf "1. Configure Nginx with Self-Signed SSL for RStudio\n"
        printf "2. Configure Nginx with Let's Encrypt SSL for RStudio\n"
        printf "----------------------------------------------------\n"
        printf "3. Uninstall Nginx Configurations (optional package removal)\n"
        printf "4. Restore All Configurations from Last Backup\n"
        printf "5. Exit\n"
        printf "========================================================\n"
        read -r -p "Enter choice: " choice

        if [[ "$choice" == "1" || "$choice" == "2" ]]; then
            # Check if RStudio is listening. netstat can be slow. `ss` is faster if available.
            local rstudio_listening_cmd="netstat -tuln"
            if command -v ss &>/dev/null; then rstudio_listening_cmd="ss -tuln"; fi
            if ! $rstudio_listening_cmd | grep -q ":${RSTUDIO_PROXY_TARGET_PORT}[[:space:]].*LISTEN"; then
                log "Warning: RStudio Server does not appear to be listening on $RSTUDIO_PROXY_TARGET_HOST:$RSTUDIO_PROXY_TARGET_PORT."
                read -r -p "Nginx proxy setup might fail. Continue? (y/n): " confirm_proceed
                if [[ "$confirm_proceed" != "y" && "$confirm_proceed" != "Y" ]]; then continue; fi
            fi
        fi
        case $choice in
            1) backup_config && configure_nginx_self_signed_proxy ;;
            2) backup_config && configure_nginx_letsencrypt_proxy ;;
            3) uninstall_nginx_configs ;;
            4) restore_config ;;
            5) log "Exiting Nginx Setup."; break ;;
            *) printf "Invalid choice. Please try again.\n" ;;
        esac
        [[ "$choice" != "5" ]] && read -r -p "Press Enter to continue..."
    done
}
log "=== Nginx Setup Script Started ==="
setup_backup_dir # Initialize backup dir
main_nginx_menu
log "=== Nginx Setup Script Finished ==="
