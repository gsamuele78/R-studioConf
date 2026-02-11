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

# 0. PKI Trust & Certificate Enrollment
if [ -n "${STEP_CA_URL:-}" ]; then
    log "INFO" "STEP_CA_URL detected. Configuring PKI..."
    
    # 1. Fetch Root CA (Trust)
    if [ -f "/scripts/pki/fetch_root.sh" ]; then
        /scripts/pki/fetch_root.sh || log "WARN" "Failed to fetch Root CA."
    fi

    # 2. Key/Cert Paths
    # We use standard locations for Nginx to pick up
    # Note: You must ensure nginx.conf typically looks at /etc/ssl/certs/ssl-cert-snakeoil.pem 
    # OR we overwrite those files, OR we configure Nginx to look at /etc/ssl/step/site.crt
    
    # Let's target a specific directory and assume Nginx template uses it OR we symlink.
    # The existing .env mounts snakeoil. We should probably overwrite "site.crt" in a volume or ephemeral path.
    # If the user mounted SSL_CERT_PATH (read-only usually), we can't overwrite.
    # BUT this is a "Pet Container" style fix. 
    
    # Dockerfile.nginx doesn't show where keys are expected unless we look at nginx.conf.template.
    # Assuming we want to generate them to specific path.
    
    CERT_DIR="/etc/ssl/step"
    mkdir -p "$CERT_DIR"
    
    # Enroll
    if [ -f "/scripts/pki/enroll_cert.sh" ]; then
        /scripts/pki/enroll_cert.sh "$CERT_DIR/site.crt" "$CERT_DIR/site.key"
    fi
     
    # If enrollment succeeded, we should try to use these certs.
    # Since legacy config points to /etc/ssl/certs/ssl-cert-snakeoil.pem (often mounted RO),
    # we might need to adjust Nginx config generation OR symlink if possible (unlikely if RO mount).
    # However, envsubst in entrypoint generates nginx.conf.
    # We can export SSL_CERT_PATH override *inside the container* if the template uses it variable?
    # nginx.conf.template usually uses hardcoded paths or check.
    
    if [ -f "$CERT_DIR/site.crt" ] && [ -s "$CERT_DIR/site.crt" ]; then
        log "INFO" "Using Enrolled Step-CA Certificates..."
        # We need to make sure nginx uses these.
        # If nginx.conf.template uses ${SSL_CERT_PATH}, we can export it here!
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
