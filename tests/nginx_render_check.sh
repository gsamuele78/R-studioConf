#!/usr/bin/env bash
# tests/nginx_render_check.sh — render the nginx templates and run `nginx -t`.
#
# WHY: the portal's nginx config is assembled from templates/nginx_site.conf.template
# plus four included partials (ssl_certificate, ssl_params, performance,
# proxy_location). A syntax slip there only surfaces on deploy, when
# scripts/30_install_nginx.sh / update_nginx_templates.sh render + reload — i.e.
# in production. This test renders the same templates with stub values, supplies a
# throwaway self-signed cert/key/dhparam, and runs `nginx -t` so a broken proxy /
# ssl / map directive is caught at PR time instead.
#
# Best-effort by design: it stubs upstreams (proxy_pass to 127.0.0.1, never
# connects) and substitutes placeholders with context-valid values — it asserts
# nginx CONFIG SYNTAX, not runtime reachability.
#
# Exit: 0 nginx -t OK | 1 nginx -t failed | 2 invocation error (no nginx/openssl).
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly TPL_DIR="${REPO_ROOT}/templates"

if [[ -t 1 ]]; then
    C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_RST=$'\e[0m'
else
    C_RED= C_GREEN= C_RST=
fi

command -v nginx   >/dev/null 2>&1 || { echo "ERROR: nginx not found (run inside an nginx image)." >&2; exit 2; }
command -v openssl >/dev/null 2>&1 || { echo "ERROR: openssl not found (needed for the stub cert)." >&2; exit 2; }

readonly WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
readonly RENDER="${WORK}/render"
readonly LOGS="${WORK}/logs"
mkdir -p "${RENDER}" "${LOGS}"

# --- throwaway TLS material (nginx -t actually loads these) -------------------
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -keyout "${WORK}/stub.key" -out "${WORK}/stub.crt" \
    -subj "/CN=localhost" >/dev/null 2>&1
openssl dhparam -out "${WORK}/dhparam.pem" 1024 >/dev/null 2>&1

# --- placeholder → context-valid stub map ------------------------------------
# (paths/ports/URLs must be VALID in their nginx directive, so not a blind `1`.)
render() {
    sed -E \
        -e "s|%%DOMAIN_OR_IP%%|localhost|g" \
        -e "s|%%LOG_DIR%%|${LOGS}|g" \
        -e "s|%%NGINX_TEMPLATE_DIR%%|${RENDER}|g" \
        -e "s|%%CERT_FULLPATH%%|${WORK}/stub.crt|g" \
        -e "s|%%KEY_FULLPATH%%|${WORK}/stub.key|g" \
        -e "s|%%DHPARAM_FULLPATH%%|${WORK}/dhparam.pem|g" \
        -e "s|%%RSTUDIO_PORT%%|8787|g" \
        -e "s|%%WEB_TERMINAL_PORT%%|7681|g" \
        -e "s|%%RSESSION_TIMEOUT_SECONDS%%|3600|g" \
        -e "s|%%TIMEOUT_STANDARD%%|60|g" \
        -e "s|%%NEXTCLOUD_TARGET_URL%%|http://127.0.0.1:8080|g" \
        "$1"
}

# Partials are included as nginx_<name>.conf (no .template) from %%NGINX_TEMPLATE_DIR%%.
for part in ssl_certificate ssl_params performance proxy_location; do
    render "${TPL_DIR}/nginx_${part}.conf.template" > "${RENDER}/nginx_${part}.conf"
done
render "${TPL_DIR}/nginx_site.conf.template" > "${RENDER}/nginx_site.conf"

leftover="$(grep -rhoE '%%[A-Z0-9_]+%%' "${RENDER}" | sort -u || true)"
[[ -n "${leftover}" ]] && echo "${C_RED}WARN${C_RST} unmapped placeholder(s) remain: ${leftover//$'\n'/ }"

# --- minimal main config that includes the rendered site at http scope -------
cat > "${WORK}/nginx.conf" <<EOF
worker_processes 1;
pid ${WORK}/nginx.pid;
error_log ${LOGS}/global-error.log;
events { worker_connections 64; }
http {
    include      /etc/nginx/mime.types;
    default_type application/octet-stream;
    include      ${RENDER}/nginx_site.conf;
}
EOF

echo "Running: nginx -t -c ${WORK}/nginx.conf"
if nginx -t -c "${WORK}/nginx.conf" -p "${WORK}" 2>&1; then
    echo "${C_GREEN}PASS${C_RST} — rendered nginx config is syntactically valid."
else
    echo "${C_RED}FAIL${C_RST} — nginx -t rejected the rendered config (see above)."
    exit 1
fi
