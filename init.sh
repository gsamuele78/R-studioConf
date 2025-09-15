#!/bin/bash
# Initialization script for the environment

# Determine the directory where this script resides for robust pathing
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

echo "Setting executable permissions for necessary scripts..."

# Make the main manager script executable
chmod +x "${SCRIPT_DIR}/r_env_manager.sh"

# Make all scripts in the 'scripts' directory executable
find "${SCRIPT_DIR}/scripts" -type f -name "*.sh" -print0 | while IFS= read -r -d $'\0' file; do
    chmod +x "$file"
done

# Note: library scripts in 'lib/' are 'sourced', not run directly, so they don't need executable permissions.

echo "Launching the R Environment Manager..."
# Execute the manager with sudo to ensure it runs with root privileges
sudo "${SCRIPT_DIR}/r_env_manager.sh"