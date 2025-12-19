#!/bin/bash
# 10_telemetry_setup.sh - Setup Telemetry & Metrics (Node Exporter + Custom API)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
UTILS_SCRIPT_PATH="${SCRIPT_DIR}/../lib/common_utils.sh"
TELEMETRY_API_SCRIPT="${SCRIPT_DIR}/telemetry/telemetry_api.py"

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
    
    # Install Python/Pip (System-wide or venv? System-wide for simplicity in this sysadmin context)
    run_command "Install Python pip" "apt-get install -y python3-pip"
    
    # Install Python libs
    log "INFO" "Installing Python libraries for Telemetry API..."
    run_command "Install FastAPI/Uvicorn/PrometheusClient" "pip3 install fastapi uvicorn psutil prometheus_client"
}

setup_service() {
    log "INFO" "Configuring Botanical Telemetry Service..."
    
    local service_file="/etc/systemd/system/botanical-telemetry.service"
    
    cat <<EOF > "$service_file"
[Unit]
Description=Botanical Big Data Telemetry API
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$(dirname "$TELEMETRY_API_SCRIPT")
ExecStart=/usr/bin/python3 $TELEMETRY_API_SCRIPT
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

    run_command "Reload systemd" "systemctl daemon-reload"
    run_command "Enable Telemetry Service" "systemctl enable botanical-telemetry.service"
    run_command "Start Telemetry Service" "systemctl restart botanical-telemetry.service"
    
    # Ensure node exporter is running
    run_command "Enable Node Exporter" "systemctl enable prometheus-node-exporter"
    run_command "Start Node Exporter" "systemctl start prometheus-node-exporter"
    
    log "INFO" "Telemetry services started."
}

main() {
    log "INFO" "--- Starting Telemetry Setup ---"
    install_prerequisites
    setup_service
    log "INFO" "--- Telemetry Setup Complete ---"
    log "INFO" "Metrics available locally at:"
    log "INFO" "  - System: http://localhost:9100/metrics"
    log "INFO" "  - Custom: http://localhost:8000/metrics"
    log "INFO" "Run Nginx setup (05) to expose them securely under /monitoring/"
}

main "$@"
