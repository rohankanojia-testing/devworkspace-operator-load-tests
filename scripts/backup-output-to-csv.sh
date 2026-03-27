#!/usr/bin/env bash
set -euo pipefail

# Parse k6 backup load test output and convert metrics to CSV
#
# Usage: cat k6-backup-output.txt | ./backup-output-to-csv.sh --config-type correct --namespaces single --restore true
#        echo "$K6_OUTPUT" | ./backup-output-to-csv.sh --config-type openshift-internal --namespaces separate --restore false

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

# Extract just the avg value from a metric
extract_avg() {
    local metric_name="$1"
    local result
    result=$(echo "$INPUT" | grep -E "^\s*✓?\s*✗?\s*$metric_name" | awk '{
        for (i=1; i<=NF; i++) {
            if ($i ~ /^avg=/) {
                print substr($i, 5)
                exit
            }
        }
    }' || echo "")
    echo "${result:-0}"
}

# Extract counter values
extract_counter() {
    local counter_name="$1"
    local result
    result=$(echo "$INPUT" | grep -E "^\s*✓?\s*✗?\s*$counter_name" | awk '{
        # Look for the count value (first number before rate)
        for (i=1; i<=NF; i++) {
            if ($i ~ /^[0-9]+$/ && $(i+1) ~ /^[0-9.]+\/s$/) {
                print $i
                exit
            }
        }
    }' || echo "")
    echo "${result:-0}"
}

# Extract gauge values
extract_gauge() {
    local gauge_name="$1"
    local result
    result=$(echo "$INPUT" | grep -E "^\s*✓?\s*✗?\s*$gauge_name" | awk '{
        # Look for value=X pattern
        for (i=1; i<=NF; i++) {
            if ($i ~ /^value=/) {
                print substr($i, 7)
                exit
            }
        }
    }' || echo "")
    echo "${result:-0}"
}

# Check if CSV file exists, if not create header
CSV_FILE="backup_load_test_results.csv"

if [ ! -f "$CSV_FILE" ]; then
    echo "Config Type,DW Target,Backup Attempted,Backup Succeeded,Backup Pods,Backup Failed,Backup Job Duration (Avg ms),Restore Total,Restore Succeeded,Restore Failed,Restore Duration (Avg ms),Average CPU (milliCPU),Average Memory (MiB),Average Etcd CPU (milliCPU),Average Etcd Memory (MiB)" > "$CSV_FILE"
fi

# Extract backup metrics
BACKUP_ATTEMPTED=$(extract_counter "backup_jobs_total")
BACKUP_SUCCEEDED=$(extract_counter "backup_jobs_succeeded")
BACKUP_PODS=$(extract_counter "backup_pods_total")
BACKUP_FAILED=$(extract_counter "backup_jobs_failed")
BACKUP_JOB_DURATION=$(extract_avg "backup_job_duration")

# Extract restore metrics
RESTORE_TOTAL=$(extract_counter "restore_workspaces_total")
RESTORE_SUCCEEDED=$(extract_counter "restore_workspaces_succeeded")
RESTORE_FAILED=$(extract_counter "restore_workspaces_failed")
RESTORE_DURATION=$(extract_avg "restore_duration")

# Extract operator metrics
AVG_OP_CPU=$(extract_avg "average_operator_cpu")
AVG_OP_MEM=$(extract_avg "average_operator_memory")

# Extract ETCD metrics
AVG_ETCD_CPU=$(extract_avg "average_etcd_cpu")
AVG_ETCD_MEM=$(extract_avg "average_etcd_memory")

# Build CSV row
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
