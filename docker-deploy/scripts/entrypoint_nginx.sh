#!/bin/bash
# entrypoint_nginx.sh
# Custom Nginx Entrypoint using project's common_utils.sh for template processing

set -e

# Define paths
SCRIPT_DIR="/scripts"
LIB_DIR="/scripts/lib"
TEMPLATE_DIR="/etc/nginx/templates"
WEB_ROOT="/usr/share/nginx/html"
NGINX_CONF_DIR="/etc/nginx"

# Source common_utils.sh
if [ -f "${LIB_DIR}/common_utils.sh" ]; then
    source "${LIB_DIR}/common_utils.sh"
    # Create a dummy LOG_FILE variable to prevent common_utils from complaining or failing on mkdir /var/log/r_env_manager if not root/protected
    # Container usually runs as root, so /var/log might work, but let's be safe.
    LOG_FILE="/var/log/nginx/entrypoint.log"
    mkdir -p "$(dirname "$LOG_FILE")"
else
    echo "ERROR: common_utils.sh not found!"
    exit 1
fi

log "INFO" "Starting Botanical Portal Nginx Entrypoint..."

# 2. System Optimization (Nginx Tuning)
log "INFO" "Applying Nginx Optimizations..."
# Default to auto/1024 if not set
WORKER_PROCESSES="${NGINX_WORKER_PROCESSES:-auto}"
WORKER_CONNECTIONS="${NGINX_WORKER_CONNECTIONS:-1024}"

# We use sed to patch nginx.conf (since our template might not have these variables)
if [ -f "/etc/nginx/nginx.conf" ]; then
    sed -i "s/^worker_processes.*/worker_processes ${WORKER_PROCESSES};/" /etc/nginx/nginx.conf
    sed -i "s/worker_connections.*/worker_connections ${WORKER_CONNECTIONS};/" /etc/nginx/nginx.conf
fi

# 3. SSL Configuration & ACME Enrollment
if [ "${LE_ENABLED}" == "true" ]; then
    log "INFO" "Let's Encrypt / ACME Enrollment Enabled."
    
    if [ -z "${LE_DOMAIN}" ] || [ -z "${LE_EMAIL}" ]; then
        log "ERROR" "LE_DOMAIN and LE_EMAIL must be set."
    else
        # Check if certificate already exists
        if [ ! -d "/etc/letsencrypt/live/${LE_DOMAIN}" ]; then
            log "INFO" "Obtaining certificate for ${LE_DOMAIN}..."
            
            CERTBOT_CMD="certbot --nginx -d ${LE_DOMAIN} --email ${LE_EMAIL} --agree-tos --non-interactive"
            
            # Internal CA Support
            if [ -n "${LE_ACME_SERVER:-}" ]; then
                log "INFO" "Using Custom ACME Server: ${LE_ACME_SERVER}"
                CERTBOT_CMD="${CERTBOT_CMD} --server ${LE_ACME_SERVER}"
            fi
            
            if $CERTBOT_CMD; then
                log "INFO" "Certificate obtained successfully."
                # Setup Auto-renewal loop (simple background process)
                (while :; do sleep 12h; certbot renew --quiet --post-hook "nginx -s reload"; done) &
            else
                log "ERROR" "Certbot failed."
            fi
        else
            log "INFO" "Certificate already exists for ${LE_DOMAIN}. Starting renewal loop."
            (while :; do sleep 12h; certbot renew --quiet --post-hook "nginx -s reload"; done) &
        fi
    fi
else
    # Fallback to Enrolled Step-CA Certificates if present
    # Logic: If we enrolled via sidecar or volume, use them.
    CERT_DIR="/etc/ssl/step"
    if [ -f "$CERT_DIR/site.crt" ] && [ -s "$CERT_DIR/site.crt" ]; then
        log "INFO" "Using Enrolled Step-CA Certificates..."
        export SSL_CERT_PATH="$CERT_DIR/site.crt"
        export SSL_KEY_PATH="$CERT_DIR/site.key"
    fi
fi


# --- Template Processing Logic ---
# The user specifically asked to use common_utils logic.
# process_template usage: process_template "template_file" "output_variable" "KEY=VAL" ...

# 1. Process Main Nginx Config
# We use envsubst for the main config because it might contain many shell vars 
# and process_template is designed for specific placeholders %%VAR%%.
# Check if template uses {{VAR}} or $VAR or %%VAR%%.
# Original project common_utils uses %%. Docker usually uses $VAR.
# Let's see what templates we have. 
# If templates/nginx.conf.template uses ${VAR}, we use envsubst.
# If templates/portal_index.html.template uses %%CURRENT_YEAR%%, we use process_template.

log "INFO" "Processing Nginx Configuration..."
if [ -f "${TEMPLATE_DIR}/nginx.conf.template" ]; then
    # We use envsubst for system configs usually
    envsubst '${NGINX_PORT} ${NGINX_HOST} ${RSTUDIO_PORT}' < "${TEMPLATE_DIR}/nginx.conf.template" > "${NGINX_CONF_DIR}/nginx.conf"
    log "INFO" "Generated nginx.conf"
fi

# 2. Process Web Portal HTML/CSS
# This mirrors logic from scripts/31_setup_web_portal.sh
current_year=$(date +%Y)

if [ -f "${TEMPLATE_DIR}/portal_index.html.template" ]; then
    log "INFO" "Processing Portal HTML Template..."
    
    # We need to read the file content to a variable? 
    # common_utils process_template expects a file path and outputs to a variable.
    
    # OUTPUT VAR
    html_content=""
    
    # Call process_template
    # Note: common_utils.sh in docker might behave differently if system tools missing? 
    # We installed bash/coreutils in Dockerfile.nginx.
    
    process_template "${TEMPLATE_DIR}/portal_index.html.template" html_content "CURRENT_YEAR=${current_year}" "DOMAIN=${HOST_DOMAIN}"
    
    echo "$html_content" > "${WEB_ROOT}/index.html"
    log "INFO" "Deployed index.html"
else
    log "WARN" "portal_index.html.template not found."
fi

if [ -f "${TEMPLATE_DIR}/portal_style.css.template" ]; then
    log "INFO" "Processing Portal CSS Template..."
    css_content=""
    process_template "${TEMPLATE_DIR}/portal_style.css.template" css_content "PRIMARY_COLOR=#2c3e50" # Example var
    echo "$css_content" > "${WEB_ROOT}/style.css"
    log "INFO" "Deployed style.css"
fi

# 3. Process Wrappers (RStudio / Terminal) if they exist
# In Docker, we might just proxy, but if using iframes, we need the wrapper HTMLs.
if [ -f "${TEMPLATE_DIR}/rstudio_wrapper.html.template" ]; then
    mkdir -p "${WEB_ROOT}/rstudio"
    cp "${TEMPLATE_DIR}/rstudio_wrapper.html.template" "${WEB_ROOT}/rstudio/index.html"
    log "INFO" "Deployed RStudio Wrapper"
fi

if [ -f "${TEMPLATE_DIR}/terminal_wrapper.html.template" ]; then
    mkdir -p "${WEB_ROOT}/terminal"
    cp "${TEMPLATE_DIR}/terminal_wrapper.html.template" "${WEB_ROOT}/terminal/index.html"
    log "INFO" "Deployed Terminal Wrapper"
fi

# 4. Check Assets
if [ -d "/usr/share/nginx/html/assets" ]; then
    # Move assets to root if needed or just leave them.
    # Logic in 31_setup_web_portal.sh copied them to webroot.
    cp -r /usr/share/nginx/html/assets/* "${WEB_ROOT}/" 2>/dev/null || true
fi


log "INFO" "Configuration complete. Starting Nginx..."
exec "$@"
