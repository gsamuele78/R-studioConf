#!/bin/bash
# 40_install_telemetry.sh - Setup Telemetry & Metrics (Node Exporter + Custom FastAPI)
#
# Fix: Ubuntu 24.04 / PEP 668 — pip3 refuses system-wide installs.
# Solution: dedicated venv at TELEMETRY_VENV, systemd service uses venv Python.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
UTILS_SCRIPT_PATH="${SCRIPT_DIR}/../lib/common_utils.sh"
TELEMETRY_API_SCRIPT="${SCRIPT_DIR}/telemetry/telemetry_api.py"

# Venv for the telemetry service (isolated from the geo/R venv in /opt/r-geospatial)
TELEMETRY_VENV="/opt/botanical-telemetry"
TELEMETRY_PYTHON="${TELEMETRY_VENV}/bin/python3"
TELEMETRY_PIP="${TELEMETRY_VENV}/bin/pip"

if [[ ! -f "$UTILS_SCRIPT_PATH" ]]; then
    echo "Error: common_utils.sh not found at $UTILS_SCRIPT_PATH" >&2
    exit 1
fi
source "$UTILS_SCRIPT_PATH"

install_prerequisites() {
    log "INFO" "Installing telemetry prerequisites..."
    run_command "Update package lists" "apt-get update"

    # Install Node Exporter
    if ! command -v prometheus-node-exporter &>/dev/null; then
        run_command "Install Node Exporter" "apt-get install -y prometheus-node-exporter"
    else
        log "INFO" "Node Exporter already installed."
    fi

    # Ensure python3-venv and python3-full are available (needed for venv creation)
    run_command "Install python3-venv" "apt-get install -y python3-venv python3-full"

    # ── Create / update the telemetry venv ──
    # Ubuntu 24.04 uses PEP 668 ("externally managed") so global pip3 installs are blocked.
    # We use an isolated venv instead — cleaner, no --break-system-packages hacks.
    if [[ ! -f "${TELEMETRY_PYTHON}" ]]; then
        log "INFO" "Creating telemetry venv at ${TELEMETRY_VENV}..."
        if ! python3 -m venv "${TELEMETRY_VENV}"; then
            log "ERROR" "Failed to create venv at ${TELEMETRY_VENV}"
            return 1
        fi
    else
        log "INFO" "Telemetry venv already exists at ${TELEMETRY_VENV}, updating packages."
    fi

    # Upgrade pip inside venv first (avoids resolver warnings)
    run_command "Upgrade pip (venv)" "${TELEMETRY_PIP} install --quiet --upgrade pip"

    # Install Python libs into the venv
    log "INFO" "Installing Python libraries into telemetry venv..."
    run_command "Install FastAPI/Uvicorn/psutil/prometheus_client" \
        "${TELEMETRY_PIP} install --quiet fastapi uvicorn psutil prometheus_client"
}

setup_service() {
    log "INFO" "Configuring Botanical Telemetry Service..."

    local service_file="/etc/systemd/system/botanical-telemetry.service"
    local api_dir
    api_dir="$(dirname "${TELEMETRY_API_SCRIPT}")"

    cat > "${service_file}" <<EOF
[Unit]
Description=Botanical Big Data Telemetry API
After=network.target
Wants=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${api_dir}
# Use the venv Python — not /usr/bin/python3 (which lacks the required packages)
ExecStart=${TELEMETRY_PYTHON} ${TELEMETRY_API_SCRIPT}
Restart=on-failure
RestartSec=10
# Pass venv to subprocesses just in case
Environment="PATH=${TELEMETRY_VENV}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
Environment="VIRTUAL_ENV=${TELEMETRY_VENV}"

[Install]
WantedBy=multi-user.target
EOF

    run_command "Reload systemd" "systemctl daemon-reload"
    run_command "Enable Telemetry Service" "systemctl enable botanical-telemetry.service"
    run_command "Start Telemetry Service" "systemctl restart botanical-telemetry.service"

    # Wait a moment and then check it actually came up
    sleep 2
    if systemctl is-active --quiet botanical-telemetry.service; then
        log "INFO" "botanical-telemetry.service is RUNNING on port 8000."
    else
        log "WARN" "botanical-telemetry.service failed to start. Check: journalctl -u botanical-telemetry -n 30"
    fi

    # Ensure node exporter is running
    run_command "Enable Node Exporter" "systemctl enable prometheus-node-exporter"
    run_command "Start Node Exporter" "systemctl start prometheus-node-exporter"

    log "INFO" "Telemetry services started."
}

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

main() {
    log "INFO" "--- Starting Telemetry Setup ---"
    install_prerequisites
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
