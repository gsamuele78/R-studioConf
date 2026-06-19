#!/bin/bash
# scripts/40_install_telemetry.sh
# 40_install_telemetry.sh — Setup Telemetry & Metrics (Node Exporter + Custom FastAPI)
#
# Design notes
# ------------
# • Payload (telemetry_api.py) is installed into ${BIOME_CONF}/telemetry/
#   (default /etc/biome-calc/telemetry/) — matches project convention
#   (/etc/biome-calc/{conf,script,telemetry}) used by orphan cleanup, audit, etc.
#   Rationale: the systemd unit runs as root; it must NOT ExecStart code that
#   lives under a human user's $HOME (/home/administrator/...). That couples
#   root-owned services to an interactive account and breaks ProtectHome
#   hardening.
#
# • Python runtime is an isolated venv at /opt/botanical-telemetry (Ubuntu 24.04
#   PEP 668 blocks system-wide pip installs; venv is cleaner than
#   --break-system-packages).
#
# • Follows project HARD RULES:
#     - set -euo pipefail
#     - exit 1 on chown/permission/install failures (rule #10)
#     - no passwords as CLI args, no JSON via sed/awk (N/A here)
set -euo pipefail

# ── Colour vars (per project script standard) ──
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
UTILS_SCRIPT_PATH="${SCRIPT_DIR}/../lib/common_utils.sh"

# ── Source payload (from the git checkout) ──
TELEMETRY_API_SRC="${SCRIPT_DIR}/telemetry/telemetry_api.py"

# ── Canonical install layout (matches /etc/biome-calc/{conf,script}) ──
BIOME_CONF="${BIOME_CONF:-/etc/biome-calc}"
TELEMETRY_INSTALL_DIR="${BIOME_CONF}/telemetry"
TELEMETRY_API_INSTALLED="${TELEMETRY_INSTALL_DIR}/telemetry_api.py"

# ── Runtime venv (unchanged; already outside /home) ──
TELEMETRY_VENV="/opt/botanical-telemetry"
TELEMETRY_PYTHON="${TELEMETRY_VENV}/bin/python3"
TELEMETRY_PIP="${TELEMETRY_VENV}/bin/pip"

if [[ ! -f "$UTILS_SCRIPT_PATH" ]]; then
    echo -e "${RED}Error: common_utils.sh not found at $UTILS_SCRIPT_PATH${NC}" >&2
    exit 1
fi
# shellcheck source=../lib/common_utils.sh disable=SC1091
source "$UTILS_SCRIPT_PATH"

# ---------------------------------------------------------------------------
install_prerequisites() {
    log "INFO" "Installing telemetry prerequisites..."
    run_command "Update package lists" "apt-get update"

    # Node Exporter (host metrics on :9100)
    if ! command -v prometheus-node-exporter &>/dev/null; then
        run_command "Install Node Exporter" "apt-get install -y prometheus-node-exporter"
    else
        log "INFO" "Node Exporter already installed."
    fi

    # venv tooling
    run_command "Install python3-venv" "apt-get install -y python3-venv python3-full"

    # ── Create / update the telemetry venv ──
    if [[ ! -f "${TELEMETRY_PYTHON}" ]]; then
        log "INFO" "Creating telemetry venv at ${TELEMETRY_VENV}..."
        if ! python3 -m venv "${TELEMETRY_VENV}"; then
            log "ERROR" "Failed to create venv at ${TELEMETRY_VENV}"
            exit 1
        fi
    else
        log "INFO" "Telemetry venv already exists at ${TELEMETRY_VENV}, updating packages."
    fi

    run_command "Upgrade pip (venv)" "${TELEMETRY_PIP} install --quiet --upgrade pip"

    log "INFO" "Installing Python libraries into telemetry venv..."
    run_command "Install FastAPI/Uvicorn/psutil/prometheus_client/dnspython" \
        "${TELEMETRY_PIP} install --quiet fastapi uvicorn psutil prometheus_client dnspython"
}

# ---------------------------------------------------------------------------
# Deploy telemetry_api.py from the git checkout into ${BIOME_CONF}/telemetry/
# so systemd never ExecStarts code living in a human user's HOME.
deploy_payload() {
    log "INFO" "Deploying telemetry payload to ${TELEMETRY_INSTALL_DIR}..."

    if [[ ! -f "${TELEMETRY_API_SRC}" ]]; then
        log "ERROR" "Source payload missing: ${TELEMETRY_API_SRC}"
        exit 1
    fi

    # HARD RULE #10: exit 1 on permission/install failures.
    if ! install -d -m 0755 -o root -g root "${TELEMETRY_INSTALL_DIR}"; then
        log "ERROR" "Failed to create ${TELEMETRY_INSTALL_DIR}"
        exit 1
    fi

    if ! install -m 0644 -o root -g root \
            "${TELEMETRY_API_SRC}" "${TELEMETRY_API_INSTALLED}"; then
        log "ERROR" "Failed to install payload to ${TELEMETRY_API_INSTALLED}"
        exit 1
    fi

    log "INFO" "Payload installed: ${TELEMETRY_API_INSTALLED}"
}

# ---------------------------------------------------------------------------
setup_service() {
    log "INFO" "Configuring Botanical Telemetry Service..."

    local service_file="/etc/systemd/system/botanical-telemetry.service"

    cat > "${service_file}" <<EOF
[Unit]
Description=Botanical Big Data Telemetry API
Documentation=https://github.com/gsamuele78/R-studioConf
After=network.target
Wants=network.target

[Service]
Type=simple
# root required: psutil.net_connections() needs CAP_NET_ADMIN to read full TCP state table.
User=root
WorkingDirectory=${TELEMETRY_INSTALL_DIR}

# Use the venv Python — not /usr/bin/python3 (lacks required packages)
ExecStart=${TELEMETRY_PYTHON} ${TELEMETRY_API_INSTALLED}

# ── Restart policy ──
Restart=on-failure
RestartSec=3

# ── Shutdown tuning (fixes slow restarts: default is 90 s) ──
TimeoutStopSec=10
KillMode=mixed

# ── Environment ──
Environment="PATH=${TELEMETRY_VENV}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
Environment="VIRTUAL_ENV=${TELEMETRY_VENV}"
Environment="BIOME_CONF=${BIOME_CONF}"

# ── Security hardening ──
# ProtectHome=yes is now safe because the payload lives in /etc/biome-calc,
# NOT in /home/<admin>/configServices/... (previous footgun).
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ReadWritePaths=/tmp /var/log
ProtectHome=yes

[Install]
WantedBy=multi-user.target
EOF

    run_command "Reload systemd" "systemctl daemon-reload"
    run_command "Enable Telemetry Service" "systemctl enable botanical-telemetry.service"
    run_command "Start Telemetry Service" "systemctl restart botanical-telemetry.service"

    sleep 2
    if systemctl is-active --quiet botanical-telemetry.service; then
        log "INFO" "botanical-telemetry.service is RUNNING on port 8000."
    else
        log "WARN" "botanical-telemetry.service failed to start. Check: journalctl -u botanical-telemetry -n 30"
    fi

    run_command "Enable Node Exporter" "systemctl enable prometheus-node-exporter"
    run_command "Start Node Exporter"  "systemctl start prometheus-node-exporter"

    log "INFO" "Telemetry services started."
}

# ---------------------------------------------------------------------------
verify_api() {
    log "INFO" "Verifying telemetry API..."
    local attempts=0
    while [[ $attempts -lt 5 ]]; do
        if curl -sf http://127.0.0.1:8000/api/v1/health >/dev/null 2>&1; then
            log "INFO" "  /api/v1/health → OK"
            break
        fi
        ((attempts++))
        sleep 1
    done
    if [[ $attempts -ge 5 ]]; then
        log "WARN" "  /api/v1/health not responding — check journalctl -u botanical-telemetry -n 30"
    fi
    if curl -sf http://127.0.0.1:9100/metrics >/dev/null 2>&1; then
        log "INFO" "  Node Exporter (:9100/metrics) → OK"
    else
        log "WARN" "  Node Exporter not responding on :9100"
    fi
}

# ---------------------------------------------------------------------------
main() {
    log "INFO" "--- Starting Telemetry Setup ---"
    log "INFO" "  Install dir: ${TELEMETRY_INSTALL_DIR}"
    log "INFO" "  Venv:        ${TELEMETRY_VENV}"
    install_prerequisites
    deploy_payload
    setup_service
    verify_api
    log "INFO" "--- Telemetry Setup Complete ---"
    log "INFO" "Endpoints:"
    log "INFO" "  Custom API:    http://localhost:8000/api/v1/status   (public via Nginx /api/)"
    log "INFO" "  System:        http://localhost:9100/metrics          (LAN-only via Nginx /monitoring/node/)"
    log "INFO" "  Prometheus:    http://localhost:8000/metrics          (LAN-only via Nginx /monitoring/)"
    log "INFO" "Run 31_setup_web_portal.sh to expose the dashboard on the portal."
}

main "$@"
