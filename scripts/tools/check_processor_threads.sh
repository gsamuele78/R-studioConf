#!/bin/bash
# ==============================================================================
# check_processor_threads.sh - Accurate CPU Core/Thread diagnostics.
# ==============================================================================

set -euo pipefail

# Use lscpu to get clean machine-readable data
CPU_DATA=$(lscpu)

# Extract info safely
SOCKETS=$(echo "$CPU_DATA" | grep "^Socket(s):" | awk '{print $2}')
CORES_PER_SOCKET=$(echo "$CPU_DATA" | grep "^Core(s) per socket:" | awk '{print $4}')
THREADS_PER_CORE=$(echo "$CPU_DATA" | grep "^Thread(s) per core:" | awk '{print $4}')
TOTAL_THREADS=$(nproc) # Actual system-visible processing units

PHYSICAL_CORES=$(( SOCKETS * CORES_PER_SOCKET ))

echo "============================================================"
echo "  BIOME-CALC: CPU Topology Report"
echo "============================================================"
printf "%-25s: %s\n" "CPU Model" "$(echo "$CPU_DATA" | grep "^Model name:" | cut -d: -f2 | xargs)"
printf "%-25s: %s\n" "Architecture" "$(echo "$CPU_DATA" | grep "^Architecture:" | awk '{print $2}')"
echo "------------------------------------------------------------"
printf "%-25s: %s\n" "Physical Sockets" "$SOCKETS"
printf "%-25s: %s\n" "Physical Cores (total)" "$PHYSICAL_CORES"
printf "%-25s: %s (SMT: $( [[ $THREADS_PER_CORE -gt 1 ]] && echo "ON" || echo "OFF" ))\n" "Threads per Core" "$THREADS_PER_CORE"
printf "%-25s: %s\n" "Total Logical Threads" "$TOTAL_THREADS"
echo "============================================================"

# Verification logic
if [[ $TOTAL_THREADS -ne $(( PHYSICAL_CORES * THREADS_PER_CORE )) ]]; then
    echo "Note: Discrepancy detected in core count. This may be due to CPU isolation or VMs."
fi
