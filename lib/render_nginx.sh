#!/usr/bin/env bash
# lib/render_nginx.sh — render-only producer for the T1 nginx configuration.
#
# One way to produce each nginx file (ADR-0003 §2). Both the installer
# (scripts/30_install_nginx.sh, step 6) and the in-place updater
# (scripts/update_host.sh) call render_nginx_bundle, so a fresh install and an
# update can no longer drift apart. They already had: the old
# update_nginx_templates.sh never rendered nginx_performance.conf.
#
# The function writes nothing outside OUT_DIR. OUT_DIR mirrors the absolute
# destination tree: OUT_DIR/etc/nginx/templates/nginx_ssl_params.conf is the
# file that belongs at /etc/nginx/templates/nginx_ssl_params.conf.
#
# Requires: lib/common_utils.sh already sourced (process_template, log) and the
# variables of config/install_nginx.vars.conf in the environment.
set -euo pipefail

# The five files the installer deploys, in install order (template → dest var).
# sites-available/<domain>.conf is resolved at render time.
[[ -v RENDER_NGINX_PARTIALS ]] || readonly RENDER_NGINX_PARTIALS=(
    nginx_ssl_params.conf
    nginx_ssl_certificate.conf
    nginx_performance.conf
    nginx_proxy_location.conf
)

# nginx_cert_paths — print "<cert>\t<key>" for the configured CERT_MODE.
# Same derivation as 30_install_nginx.sh step 5. Returns 1 on unknown mode.
nginx_cert_paths() {
    case "${CERT_MODE:-}" in
        SELF_SIGNED)
            printf '%s\t%s\n' "${SSL_CERT_DIR}/${DOMAIN_OR_IP}.crt" "${SSL_CERT_DIR}/${DOMAIN_OR_IP}.key" ;;
        LETS_ENCRYPT)
            printf '%s\t%s\n' "${LE_CERT_DIR}/${DOMAIN_OR_IP}/fullchain.pem" "${LE_CERT_DIR}/${DOMAIN_OR_IP}/privkey.pem" ;;
        *)
            log "ERROR" "render_nginx: unknown CERT_MODE '${CERT_MODE:-}' (SELF_SIGNED|LETS_ENCRYPT)"
            return 1 ;;
    esac
}

# nginx_rsession_timeout_seconds RSTUDIO_VARS_FILE — RStudio session timeout in
# seconds, default 7 days. Mirrors the installer: the proxy must not cut a
# session that RStudio still considers alive.
nginx_rsession_timeout_seconds() {
    local vars_file="$1" minutes=10080 extracted
    if [[ -f "${vars_file}" ]]; then
        extracted=$(grep -E '^[[:space:]]*RSESSION_TIMEOUT_MINUTES=' "${vars_file}" | cut -d= -f2- | tr -d '"'\''[:space:]' || true)
        if [[ -n "${extracted}" && "${extracted}" =~ ^[0-9]+$ ]]; then
            minutes="${extracted}"
        fi
    fi
    printf '%s\n' "$(( minutes * 60 ))"
}

# render_nginx_bundle TEMPLATE_DIR OUT_DIR RSTUDIO_VARS_FILE CERT_FULLPATH KEY_FULLPATH
render_nginx_bundle() {
    local template_dir="$1" out_dir="$2" rstudio_vars="$3" cert="$4" key="$5"
    local required v
    for required in DOMAIN_OR_IP RSTUDIO_PORT WEB_TERMINAL_PORT NEXTCLOUD_TARGET_URL \
                    LOG_DIR NGINX_DIR NGINX_TEMPLATE_DIR DHPARAM_PATH; do
        v="${!required:-}"
        if [[ -z "${v}" ]]; then
            log "ERROR" "render_nginx: required variable ${required} is empty"
            return 1
        fi
    done
    if [[ "${DOMAIN_OR_IP}" == "your_domain_or_ip" ]]; then
        log "ERROR" "render_nginx: DOMAIN_OR_IP is still the placeholder 'your_domain_or_ip' — refusing to render"
        return 1
    fi

    local timeout_s
    timeout_s="$(nginx_rsession_timeout_seconds "${rstudio_vars}")"
    local template_args=(
        "DOMAIN_OR_IP=${DOMAIN_OR_IP}" "RSTUDIO_PORT=${RSTUDIO_PORT}" "WEB_TERMINAL_PORT=${WEB_TERMINAL_PORT}"
        "NEXTCLOUD_TARGET_URL=${NEXTCLOUD_TARGET_URL}" "LOG_DIR=${LOG_DIR}" "NGINX_TEMPLATE_DIR=${NGINX_TEMPLATE_DIR}"
        "CERT_FULLPATH=${cert}" "KEY_FULLPATH=${key}" "DHPARAM_FULLPATH=${DHPARAM_PATH}"
        "TIMEOUT_STANDARD=600" "RSESSION_TIMEOUT_SECONDS=${timeout_s}"
    )

    local processed_content name dest
    mkdir -p "${out_dir}${NGINX_TEMPLATE_DIR}" "${out_dir}${NGINX_DIR}/sites-available"
    for name in "${RENDER_NGINX_PARTIALS[@]}"; do
        process_template "${template_dir}/${name}.template" "processed_content" "${template_args[@]}" || return 1
        # printf '%s\n' == the installer's historical `echo ... | tee`: byte-identical
        # output, so a host installed before this change plans 0 diff.
        printf '%s\n' "${processed_content}" > "${out_dir}${NGINX_TEMPLATE_DIR}/${name}"
    done
    dest="${NGINX_DIR}/sites-available/${DOMAIN_OR_IP}.conf"
    process_template "${template_dir}/nginx_site.conf.template" "processed_content" "${template_args[@]}" || return 1
    printf '%s\n' "${processed_content}" > "${out_dir}${dest}"

    # Pessimistic: an unreplaced %%PLACEHOLDER%% means a template gained a
    # variable this renderer does not supply. Never ship that to nginx.
    if grep -rlE '%%[A-Z_]+%%' "${out_dir}" >/dev/null 2>&1; then
        log "ERROR" "render_nginx: unreplaced placeholders in: $(grep -rlE '%%[A-Z_]+%%' "${out_dir}" | tr '\n' ' ')"
        return 1
    fi
    return 0
}
