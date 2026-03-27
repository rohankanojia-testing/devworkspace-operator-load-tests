#!/usr/bin/env bash
set -euo pipefail

# Interactive script to convert pasted webhook k6 output to CSV
#
# Usage: ./paste-to-csv-webhook.sh

echo "Paste your webhook k6 output below, then press Ctrl+D (EOF) when done:"
echo "---"

# Read all input until EOF (Ctrl+D)
INPUT=$(cat)

# Prompt for users and iterations
read -p "Enter number of users (e.g., 200): " USERS
read -p "Enter number of iterations (e.g., 200): " ITERATIONS

# Get the script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Call the main script
echo "$INPUT" | "${SCRIPT_DIR}/webhook-output-to-csv.sh" --users "$USERS" --iterations "$ITERATIONS"
