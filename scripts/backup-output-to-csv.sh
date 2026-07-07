#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=backup-metrics-extract.sh
source "${SCRIPT_DIR}/backup-metrics-extract.sh"

# Parse k6 backup load test output and convert metrics to CSV
#
# Usage: cat k6-backup-output.txt | ./backup-output-to-csv.sh --config-type "external registry correct" --dw-target 2500
#        echo "$K6_OUTPUT" | ./backup-output-to-csv.sh --config-type "openshift-internal correct" --dw-target 1500

# Parse arguments
CONFIG_TYPE=""
DW_TARGET=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --config-type)
            CONFIG_TYPE="$2"
            shift 2
            ;;
        --dw-target)
            DW_TARGET="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

if [[ -z "$CONFIG_TYPE" ]]; then
    echo "Error: --config-type is required" >&2
    echo "Usage: $0 --config-type <config-description> --dw-target <number>" >&2
    echo "Example: $0 --config-type 'external registry correct' --dw-target 2500" >&2
    exit 1
fi

if [[ -z "$DW_TARGET" ]]; then
    echo "Error: --dw-target is required" >&2
    echo "Usage: $0 --config-type <config-description> --dw-target <number>" >&2
    echo "Example: $0 --config-type 'external registry correct' --dw-target 2500" >&2
    exit 1
fi

# Read input
INPUT=$(cat)

backup_metrics_map_legacy_csv "$INPUT" "$CONFIG_TYPE"

# Check if CSV file exists, if not create header
CSV_FILE="backup_load_test_results.csv"

if [ ! -f "$CSV_FILE" ]; then
    echo "Config Type,DW Target,Backup Attempted,Backup Succeeded,Backup Pods,Backup Failed,Backup Job Duration (Avg ms),Restore Total,Restore Succeeded,Restore Failed,Restore Duration (Avg ms),Average CPU (milliCPU),Average Memory (MiB),Average Etcd CPU (milliCPU),Average Etcd Memory (MiB)" > "$CSV_FILE"
fi
CSV_ROW="$CONFIG_TYPE,$DW_TARGET,$BACKUP_ATTEMPTED,$BACKUP_SUCCEEDED,$BACKUP_PODS,$BACKUP_FAILED,$BACKUP_JOB_DURATION,$RESTORE_TOTAL,$RESTORE_SUCCEEDED,$RESTORE_FAILED,$RESTORE_DURATION,$AVG_OP_CPU,$AVG_OP_MEM,$AVG_ETCD_CPU,$AVG_ETCD_MEM"

# Append to CSV
echo "$CSV_ROW" >> "$CSV_FILE"

echo "Results appended to $CSV_FILE"
echo ""
echo "Summary:"
echo "  Config Type: $CONFIG_TYPE"
echo "  DW Target: $DW_TARGET"
echo "  Backup Attempted: $BACKUP_ATTEMPTED"
echo "  Backup Succeeded: $BACKUP_SUCCEEDED"
echo "  Backup Pods: $BACKUP_PODS"
echo "  Backup Failed: $BACKUP_FAILED"
echo "  Backup Job Duration (Avg): $BACKUP_JOB_DURATION ms"
echo "  Restore Total: $RESTORE_TOTAL"
echo "  Restore Succeeded: $RESTORE_SUCCEEDED"
echo "  Restore Failed: $RESTORE_FAILED"
echo "  Restore Duration (Avg): $RESTORE_DURATION ms"
echo "  Average Operator CPU: $AVG_OP_CPU milliCPU"
echo "  Average Operator Memory: $AVG_OP_MEM MiB"
echo "  Average Etcd CPU: $AVG_ETCD_CPU milliCPU"
echo "  Average Etcd Memory: $AVG_ETCD_MEM MiB"
echo ""
echo "----------------------------------------"
echo "Current CSV contents:"
echo "----------------------------------------"
cat "$CSV_FILE"
