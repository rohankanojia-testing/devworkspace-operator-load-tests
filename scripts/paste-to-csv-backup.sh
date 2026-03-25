#!/usr/bin/env bash
set -euo pipefail

# Interactive script to convert pasted backup k6 output to CSV
#
# Usage: ./paste-to-csv-backup.sh

echo "Paste your backup k6 output below, then press Ctrl+D (EOF) when done:"
echo "---"

# Read all input until EOF (Ctrl+D)
INPUT=$(cat)

# Prompt for test configuration
echo ""
echo "Select DWOC config type:"
echo "  1) correct (proper registry configuration)"
echo "  2) incorrect (wrong credentials - expects backup failures)"
echo "  3) openshift-internal (uses OpenShift internal registry)"
read -p "Enter choice [1-3]: " CONFIG_CHOICE

case $CONFIG_CHOICE in
    1)
        CONFIG_TYPE="correct"
        ;;
    2)
        CONFIG_TYPE="incorrect"
        ;;
    3)
        CONFIG_TYPE="openshift-internal"
        ;;
    *)
        echo "Invalid choice. Defaulting to 'correct'" >&2
        CONFIG_TYPE="correct"
        ;;
esac

read -p "Enter namespace mode (single or separate): " NAMESPACES
read -p "Was restore verification enabled? (true or false): " RESTORE

# Get the script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Call the main script
echo "$INPUT" | "${SCRIPT_DIR}/backup-output-to-csv.sh" --config-type "$CONFIG_TYPE" --namespaces "$NAMESPACES" --restore "$RESTORE"
