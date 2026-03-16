#!/bin/bash
#
# system_report.sh - A script to generate a comprehensive, detailed, and
#                    human-readable system hardware report.
#

# === Configuration & Setup ===
set -euo pipefail
IFS=$'\n\t'

# --- Initial Checks & User Handling ---
# We get the original user now, before any `sudo` changes might affect these variables.
ORIGINAL_USER=${SUDO_USER:-$(whoami)}
if [[ $EUID -ne 0 ]]; then
    echo "⚠️ This script should be run as root for the most accurate information."
    echo "   Many hardware details will be missing or inaccurate without sudo."
    sleep 2
fi

# --- Output Files ---
# We create a temporary directory to store the reports.
REPORT_DIR=$(mktemp -d)
REPORT_TEXT="${REPORT_DIR}/system_report.txt"
REPORT_HTML="${REPORT_DIR}/system_report.html"
REPORT_PDF="${REPORT_DIR}/system_report.pdf"

# --- Functions ---

# Prints a formatted section header.
print_section() {
    echo -e "\n### $1 ###\n" >> "$REPORT_TEXT"
}

# A function to check if a command exists.
command_exists() {
    command -v "$1" &>/dev/null
}

# A function for top-level key-value pair printing.
print_kv() {
    printf "%-30s: %s\n" "$1" "$2" >> "$REPORT_TEXT"
}

# A function for indented, sub-item key-value pair printing.
print_sub_kv() {
    printf "  %-28s: %s\n" "$1" "$2" >> "$REPORT_TEXT"
}


# === Report Generation ===

# --- Header ---
TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")
{
    echo "========================================"
    echo "       System Hardware Report"
    echo "========================================"
    echo "Generated on: $TIMESTAMP"
    echo "Report saved in: ${REPORT_DIR}"
} > "$REPORT_TEXT"

# --- System Info ---
print_section "SYSTEM INFORMATION"
print_kv "Hostname" "$(hostname)"
if command_exists lsb_release; then
    print_kv "OS" "$(lsb_release -d | cut -d':' -f2 | xargs)"
else
    OS_NAME=$(awk -F= '/^PRETTY_NAME=/ {gsub(/"/, "", $2); print $2}' /etc/os-release)
    print_kv "OS" "${OS_NAME:-N/A}"
fi
print_kv "Kernel" "$(uname -r)"
print_kv "Uptime" "$(uptime -p)"
print_kv "Current User" "$(whoami)"

# --- CPU Info ---
print_section "CPU INFORMATION"
if command_exists lscpu; then
    lscpu | awk -F: '
      /Architecture/          { printf "Architecture;%s\n", $2 }
      /Model name/            { printf "CPU Model;%s\n", $2 }
      /CPU\(s\)/               { printf "Logical Cores;%s\n", $2 }
      /Socket\(s\)/             { printf "Sockets;%s\n", $2 }
      /Core\(s\) per socket/    { printf "Cores per Socket;%s\n", $2 }
      /Thread\(s\) per core/    { printf "Threads per Core;%s\n", $2 }
    ' | while IFS=';' read -r key value; do
        print_kv "$key" "$(echo "$value" | xargs)"
    done
    (grep -q -E 'vmx|svm' /proc/cpuinfo && print_kv "Virtualization Support" "Yes" || print_kv "Virtualization Support" "No") || true
    (grep -q 'aes' /proc/cpuinfo && print_kv "AES Encryption" "Yes" || print_kv "AES Encryption" "No") || true
else
    print_kv "CPU Info" "lscpu command not found."
fi

# --- Memory Info ---
print_section "MEMORY INFORMATION"
if [ -f /proc/meminfo ]; then
    awk '
        /MemTotal/ { total_kb = $2 }
        /MemAvailable/ { avail_kb = $2 }
        END {
            printf "Total RAM;%.2f GB\n", total_kb / 1024 / 1024
            if (avail_kb) {
                printf "Available RAM;%.2f GB\n", avail_kb / 1024 / 1024
            } else {
                printf "Available RAM;Not Reported\n"
            }
        }
    ' /proc/meminfo | while IFS=';' read -r key value; do
        print_kv "$key" "$value"
    done
    if command_exists dmidecode; then
        (sudo dmidecode -t memory 2>/dev/null | grep -iq "Error Correction Type:.*ECC" && print_kv "ECC Supported" "Yes" || print_kv "ECC Supported" "No or Undetermined") || true
    fi
else
    print_kv "Memory Info" "/proc/meminfo not found."
fi

# --- Disk Info ---
print_section "DISK INFORMATION"
if command_exists lsblk; then
    lsblk -d -o NAME,SIZE,ROTA,TYPE,MODEL | grep -v "loop" | tail -n +2 | while IFS= read -r line || [[ -n "$line" ]]; do
        read -r name size rota _ model <<< "$line"
        
        echo "--- Disk: /dev/${name} ---" >> "$REPORT_TEXT"
        media="HDD"
        [[ "$rota" == "0" ]] && media="SSD/NVMe"
        
        print_sub_kv "Type" "$media"
        print_sub_kv "Size" "$size"
        print_sub_kv "Model" "${model}"
        
        if [[ "$media" == "SSD/NVMe" ]]; then
            disc_max=$(lsblk -d -o DISC-MAX "/dev/${name}" | tail -n1 | xargs)
            if [[ -n "$disc_max" && "$disc_max" != "0B" ]]; then
                print_sub_kv "TRIM/Discard" "Supported ($disc_max)"
            else
                print_sub_kv "TRIM/Discard" "Not Supported"
            fi
        fi

        if command_exists smartctl; then
            health=$(sudo smartctl -H "/dev/${name}" 2>/dev/null | grep "self-assessment test" | awk '{print $6}') || health="Unavailable"
            print_sub_kv "SMART Health" "$health"
        fi
    done
else
    print_kv "Disk Info" "lsblk command not found."
fi

# --- GPU Info ---
print_section "GPU INFORMATION"
if command_exists lspci; then
    echo "--- Detected Display Controllers ---" >> "$REPORT_TEXT"
    lspci -vnn | (grep -i 'vga\|3d' || true) | while read -r line; do
        pci_id=$(echo "$line" | awk '{print $1}')
        model_info=$(echo "$line" | cut -d':' -f3- | xargs)
        driver_info=$(lspci -vks "$pci_id" 2>/dev/null | grep -i "Kernel driver in use:" | awk '{print $5}') || driver_info="N/A"
        
        echo >> "$REPORT_TEXT"
        print_kv "GPU @ ${pci_id}" "$model_info"
        print_sub_kv "Kernel Driver" "$driver_info"
    done
fi

if command_exists nvidia-smi; then
    echo -e "\n--- NVIDIA GPU Detailed Status ---" >> "$REPORT_TEXT"
    query="name,driver_version,pstate,temperature.gpu,fan.speed,power.draw,utilization.gpu,utilization.memory,memory.total"
    (nvidia-smi --query-gpu=${query} --format=csv,noheader,nounits || true) | while IFS=',' read -r name driver pstate temp fan power util_gpu util_mem mem_total; do
        if [ -n "$name" ]; then
            print_kv "NVIDIA GPU Model" "$(echo "${name}" | xargs)"
            print_sub_kv "Driver Version" "$(echo "${driver}" | xargs)"
            print_sub_kv "Performance State" "$(echo "${pstate}" | xargs)"
            print_sub_kv "Temperature" "$(echo "${temp}" | xargs) C"
            print_sub_kv "Fan Speed" "$(echo "${fan}" | xargs) %"
            print_sub_kv "Power Draw" "$(echo "${power}" | xargs) W"
            print_sub_kv "GPU Utilization" "$(echo "${util_gpu}" | xargs) %"
            print_sub_kv "Memory Utilization" "$(echo "${util_mem}" | xargs) %"
            print_sub_kv "Total Memory" "$(echo "${mem_total}" | xargs) MiB"
        fi
    done
fi

# --- Network Info ---
print_section "NETWORK INFORMATION"
for iface_path in /sys/class/net/*; do
    iface=$(basename "$iface_path")
    [[ "$iface" == "lo" ]] && continue

    echo "--- Interface: ${iface} ---" >> "$REPORT_TEXT"
    
    mac=$(cat "/sys/class/net/${iface}/address")
    state=$(cat "/sys/class/net/${iface}/operstate")
    print_sub_kv "State" "${state^^}"
    print_sub_kv "MAC Address" "$mac"

    device_path=$(readlink -f "/sys/class/net/${iface}/device" 2>/dev/null || true)
    if [[ -n "$device_path" ]]; then
        device_id=$(basename "$device_path")
        if [[ "$device_id" =~ ^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9a-f]$ ]]; then
            model_info=$(lspci -s "$device_id" 2>/dev/null | cut -d':' -f3- | xargs)
            [[ -n "$model_info" ]] && print_sub_kv "Hardware Model" "$model_info"
        fi
    fi
    
    if command_exists ethtool; then
        (
          driver=$(sudo ethtool -i "$iface" 2>/dev/null | awk '/driver:/ {print $2}')
          speed=$(sudo ethtool "$iface" 2>/dev/null | awk -F': ' '/Speed:/ {print $2}')
          duplex=$(sudo ethtool "$iface" 2>/dev/null | awk '/Duplex:/ {print $2}')
          wol=$(sudo ethtool "$iface" 2>/dev/null | awk '/Wake-on:/ {print $2}')
          
          print_sub_kv "Driver" "${driver:-N/A}"
          print_sub_kv "Speed" "${speed:-N/A}"
          print_sub_kv "Duplex" "${duplex:-N/A}"
          print_sub_kv "Wake-on-LAN" "${wol:-N/A}"
        ) || true
    fi
done

# --- Motherboard Info ---
print_section "MOTHERBOARD INFORMATION"
if command_exists dmidecode; then
    print_kv "Manufacturer" "$(sudo dmidecode -s baseboard-manufacturer || echo 'N/A')"
    print_kv "Product Name" "$(sudo dmidecode -s baseboard-product-name || echo 'N/A')"
    print_kv "Serial Number" "$(sudo dmidecode -s baseboard-serial-number || echo 'N/A')"
else
    print_kv "Motherboard Info" "dmidecode not found. Cannot retrieve details."
fi

# === Final Output ===
echo -e "\n--- End of Report ---" >> "$REPORT_TEXT"

# Display full report on standard output
echo "========================= SYSTEM REPORT ========================="
cat "$REPORT_TEXT"
echo "==============================================================="
echo

# --- File Generation ---

# Convert to HTML
# CORRECTED: Added a UTF-8 meta tag to the HTML head to help with rendering.
{
    echo "<!DOCTYPE html><html><head><meta charset=\"UTF-8\"><title>System Report</title><style>body { font-family: monospace; white-space: pre; }</style></head><body>"
    # Use a simple `<pre>` block for reliability. `sed` is no longer needed here.
    echo "<pre>"
    cat "$REPORT_TEXT"
    echo "</pre>"
    echo "</body></html>"
} > "$REPORT_HTML"

echo "✅ Reports generated in: ${REPORT_DIR}"
echo "   - Text: ${REPORT_TEXT}"
echo "   - HTML: ${REPORT_HTML}"

# Convert to PDF (optional)
if command_exists wkhtmltopdf; then
    # CORRECTED: Explicitly tell wkhtmltopdf to use UTF-8 encoding.
    if wkhtmltopdf --encoding UTF-8 --enable-local-file-access "$REPORT_HTML" "$REPORT_PDF" >/dev/null 2>&1; then
        echo "   - PDF:  ${REPORT_PDF}"
    else
        echo "⚠️ PDF conversion failed. Check wkhtmltopdf installation or permissions."
    fi
else
    echo "ℹ️ wkhtmltopdf not found, skipping PDF generation."
fi

# --- Permission Fix ---
# CORRECTED: Change ownership of the entire report directory to the original user.
chown -R "$ORIGINAL_USER" "$REPORT_DIR"
echo "✅ Report ownership transferred to user: ${ORIGINAL_USER}"
