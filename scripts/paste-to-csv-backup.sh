#!/usr/bin/env bash
set -euo pipefail

# Interactive script to convert pasted backup k6 output to CSV
#
# Usage: ./paste-to-csv-backup.sh

# Prompt for test configuration FIRST (before reading stdin)
echo "Select registry type:"
echo "  1) external registry"
echo "  2) openshift-internal"
read -p "Enter choice [1-2]: " REGISTRY_CHOICE

case $REGISTRY_CHOICE in
    1)
        REGISTRY_TYPE="external registry"
        ;;
    2)
        REGISTRY_TYPE="openshift-internal"
        ;;
    *)
        echo "Invalid choice. Defaulting to 'external registry'" >&2
        REGISTRY_TYPE="external registry"
        ;;
esac

echo ""
echo "Select DWOC config type:"
echo "  1) correct"
echo "  2) incorrect"
read -p "Enter choice [1-2]: " CONFIG_CHOICE

case $CONFIG_CHOICE in
    1)
        DWOC_CONFIG="correct"
        ;;
    2)
        DWOC_CONFIG="incorrect"
        ;;
    *)
        echo "Invalid choice. Defaulting to 'correct'" >&2
        DWOC_CONFIG="correct"
        ;;
esac

# Build config type string (e.g., "external registry correct")
CONFIG_TYPE="${REGISTRY_TYPE} ${DWOC_CONFIG}"

echo ""
read -p "Enter DW Target (max DevWorkspaces): " DW_TARGET

# Validate DW_TARGET is a number
if ! [[ "$DW_TARGET" =~ ^[0-9]+$ ]]; then
    echo "Invalid DW Target. Using default: 0" >&2
    DW_TARGET="0"
fi

echo ""
echo "Now paste your k6 backup output below, then press Ctrl+D (EOF) when done:"
echo "---"

# Read all input until EOF (Ctrl+D)
INPUT=$(cat)

# Get the script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Call the main script
echo "$INPUT" | "${SCRIPT_DIR}/backup-output-to-csv.sh" --config-type "$CONFIG_TYPE" --dw-target "$DW_TARGET"
