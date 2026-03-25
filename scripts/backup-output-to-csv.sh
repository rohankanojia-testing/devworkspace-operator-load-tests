#!/usr/bin/env bash
set -euo pipefail

# Parse k6 backup load test output and convert metrics to CSV
#
# Usage: cat k6-backup-output.txt | ./backup-output-to-csv.sh --config-type correct --namespaces single --restore true
#        echo "$K6_OUTPUT" | ./backup-output-to-csv.sh --config-type openshift-internal --namespaces separate --restore false

# Parse arguments
CONFIG_TYPE=""
NAMESPACES=""
RESTORE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --config-type)
            CONFIG_TYPE="$2"
            shift 2
            ;;
        --namespaces)
            NAMESPACES="$2"
            shift 2
            ;;
        --restore)
            RESTORE="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

if [[ -z "$CONFIG_TYPE" || -z "$NAMESPACES" || -z "$RESTORE" ]]; then
    echo "Error: --config-type, --namespaces, and --restore are required" >&2
    echo "Usage: $0 --config-type <correct|incorrect|openshift-internal> --namespaces <single|separate> --restore <true|false>" >&2
    exit 1
fi

# Read input
INPUT=$(cat)

# Extract just the avg value from a metric
extract_avg() {
    local metric_name="$1"
    echo "$INPUT" | grep -E "^\s*✓?\s*✗?\s*$metric_name" | awk '{
        for (i=1; i<=NF; i++) {
            if ($i ~ /^avg=/) {
                print substr($i, 5)
                exit
            }
        }
        print "0"
    }'
}

# Extract counter values
extract_counter() {
    local counter_name="$1"
    echo "$INPUT" | grep -E "^\s*✓?\s*✗?\s*$counter_name" | awk '{
        # Look for the count value (first number before rate)
        for (i=1; i<=NF; i++) {
            if ($i ~ /^[0-9]+$/ && $(i+1) ~ /^[0-9.]+\/s$/) {
                print $i
                exit
            }
        }
        print "0"
    }'
}

# Extract gauge values
extract_gauge() {
    local gauge_name="$1"
    echo "$INPUT" | grep -E "^\s*✓?\s*✗?\s*$gauge_name" | awk '{
        # Look for value=X pattern
        for (i=1; i<=NF; i++) {
            if ($i ~ /^value=/) {
                print substr($i, 7)
                exit
            }
        }
        print "0"
    }'
}

# Check if CSV file exists, if not create header
CSV_FILE="backup_load_test_results.csv"

if [ ! -f "$CSV_FILE" ]; then
    echo "Config Type,Namespaces,Restore Enabled,Backup Jobs Total,Backup Jobs Succeeded,Backup Jobs Failed,Backup Success Rate,Workspaces Stopped,Workspaces Backed Up,Backup Job Duration (Avg ms),ImageStreams Created,ImageStreams Expected,Restore Workspaces Total,Restore Workspaces Succeeded,Restore Workspaces Failed,Restore Success Rate,Restore Duration (Avg ms),Average CPU (milliCPU),Average Memory (MiB),CPU Violations,Memory Violations,Average Etcd CPU (milliCPU),Average Etcd Memory (MiB)" > "$CSV_FILE"
fi

# Extract backup metrics
BACKUP_JOBS_TOTAL=$(extract_counter "backup_jobs_total")
BACKUP_JOBS_SUCCEEDED=$(extract_counter "backup_jobs_succeeded")
BACKUP_JOBS_FAILED=$(extract_counter "backup_jobs_failed")
BACKUP_SUCCESS_RATE=$(extract_gauge "backup_success_rate")
WORKSPACES_STOPPED=$(extract_counter "workspaces_stopped")
WORKSPACES_BACKED_UP=$(extract_counter "workspaces_backed_up")
BACKUP_JOB_DURATION=$(extract_avg "backup_job_duration")

# Extract ImageStream metrics (for OpenShift internal registry mode)
IMAGESTREAMS_CREATED=$(extract_counter "imagestreams_created")
IMAGESTREAMS_EXPECTED=$(extract_counter "imagestreams_expected")

# Extract restore metrics
RESTORE_WORKSPACES_TOTAL=$(extract_counter "restore_workspaces_total")
RESTORE_WORKSPACES_SUCCEEDED=$(extract_counter "restore_workspaces_succeeded")
RESTORE_WORKSPACES_FAILED=$(extract_counter "restore_workspaces_failed")
RESTORE_SUCCESS_RATE=$(extract_gauge "restore_success_rate")
RESTORE_DURATION=$(extract_avg "restore_duration")

# Extract operator metrics (avg values)
AVG_OP_CPU=$(extract_avg "average_operator_cpu")
AVG_OP_MEM=$(extract_avg "average_operator_memory")

# Extract violations
OP_CPU_VIOL=$(extract_counter "operator_cpu_violations")
OP_MEM_VIOL=$(extract_counter "operator_mem_violations")

# Extract ETCD metrics (avg values)
AVG_ETCD_CPU=$(extract_avg "average_etcd_cpu")
AVG_ETCD_MEM=$(extract_avg "average_etcd_memory")

# Build CSV row
CSV_ROW="$CONFIG_TYPE,$NAMESPACES,$RESTORE,$BACKUP_JOBS_TOTAL,$BACKUP_JOBS_SUCCEEDED,$BACKUP_JOBS_FAILED,$BACKUP_SUCCESS_RATE,$WORKSPACES_STOPPED,$WORKSPACES_BACKED_UP,$BACKUP_JOB_DURATION,$IMAGESTREAMS_CREATED,$IMAGESTREAMS_EXPECTED,$RESTORE_WORKSPACES_TOTAL,$RESTORE_WORKSPACES_SUCCEEDED,$RESTORE_WORKSPACES_FAILED,$RESTORE_SUCCESS_RATE,$RESTORE_DURATION,$AVG_OP_CPU,$AVG_OP_MEM,$OP_CPU_VIOL,$OP_MEM_VIOL,$AVG_ETCD_CPU,$AVG_ETCD_MEM"

# Append to CSV
echo "$CSV_ROW" >> "$CSV_FILE"

echo "Results appended to $CSV_FILE"
echo ""
echo "Summary:"
echo "  Config Type: $CONFIG_TYPE"
echo "  Namespaces: $NAMESPACES"
echo "  Restore Enabled: $RESTORE"
echo ""
echo "Backup Metrics:"
echo "  Backup Jobs Total: $BACKUP_JOBS_TOTAL"
echo "  Backup Jobs Succeeded: $BACKUP_JOBS_SUCCEEDED"
echo "  Backup Jobs Failed: $BACKUP_JOBS_FAILED"
echo "  Backup Success Rate: $BACKUP_SUCCESS_RATE"
echo "  Workspaces Stopped: $WORKSPACES_STOPPED"
echo "  Workspaces Backed Up: $WORKSPACES_BACKED_UP"
echo "  Backup Job Duration (Avg): $BACKUP_JOB_DURATION ms"
if [[ "$CONFIG_TYPE" == "openshift-internal" ]]; then
    echo "  ImageStreams Created: $IMAGESTREAMS_CREATED"
    echo "  ImageStreams Expected: $IMAGESTREAMS_EXPECTED"
fi
echo ""
if [[ "$RESTORE" == "true" ]]; then
    echo "Restore Metrics:"
    echo "  Restore Workspaces Total: $RESTORE_WORKSPACES_TOTAL"
    echo "  Restore Workspaces Succeeded: $RESTORE_WORKSPACES_SUCCEEDED"
    echo "  Restore Workspaces Failed: $RESTORE_WORKSPACES_FAILED"
    echo "  Restore Success Rate: $RESTORE_SUCCESS_RATE"
    echo "  Restore Duration (Avg): $RESTORE_DURATION ms"
    echo ""
fi
echo "Operator Metrics:"
echo "  Average Operator CPU: $AVG_OP_CPU milliCPU"
echo "  Average Operator Memory: $AVG_OP_MEM MiB"
echo "  CPU Violations: $OP_CPU_VIOL"
echo "  Memory Violations: $OP_MEM_VIOL"
echo ""
echo "Etcd Metrics:"
echo "  Average Etcd CPU: $AVG_ETCD_CPU milliCPU"
echo "  Average Etcd Memory: $AVG_ETCD_MEM MiB"
echo ""
echo "----------------------------------------"
echo "Current CSV contents:"
echo "----------------------------------------"
cat "$CSV_FILE"
