#!/usr/bin/env bash
set -euo pipefail

# Read backup test logs from a directory and generate CSV report
#
# Usage: ./backup-logs-to-csv.sh <logs-directory>
# Example: ./backup-logs-to-csv.sh outputs/backup_run_20260324_123456/logs/

if [ $# -eq 0 ]; then
    echo "Error: logs directory required" >&2
    echo "Usage: $0 <logs-directory>" >&2
    echo "Example: $0 outputs/backup_run_20260324_123456/logs/" >&2
    exit 1
fi

LOGS_DIR="$1"

if [ ! -d "$LOGS_DIR" ]; then
    echo "Error: Directory not found: $LOGS_DIR" >&2
    exit 1
fi

# Extract just the avg value from a metric (Trend)
extract_avg() {
    local input="$1"
    local metric_name="$2"
    echo "$input" | grep -E "^\s*✓?\s*✗?\s*$metric_name" | awk '{
        for (i=1; i<=NF; i++) {
            if ($i ~ /^avg=/) {
                print substr($i, 5)
                exit
            }
        }
        print "0"
    }' || echo "0"
}

# Extract counter values
extract_counter() {
    local input="$1"
    local counter_name="$2"
    echo "$input" | grep -E "^\s*✓?\s*✗?\s*$counter_name" | awk '{
        # Look for the count value (first number before rate)
        for (i=1; i<=NF; i++) {
            if ($i ~ /^[0-9]+$/ && $(i+1) ~ /^[0-9.]+\/s$/) {
                print $i
                exit
            }
        }
        print "0"
    }' || echo "0"
}

# Extract gauge values (current value)
extract_gauge() {
    local input="$1"
    local gauge_name="$2"
    echo "$input" | grep -E "^\s*✓?\s*✗?\s*$gauge_name" | awk '{
        # Gauge shows just the final value
        for (i=1; i<=NF; i++) {
            if ($i ~ /^[0-9.]+$/ && $(i-1) !~ /^value=/) {
                print $i
                exit
            }
        }
        print "0"
    }' || echo "0"
}

# Parse test name to extract metadata
parse_test_name() {
    local test_name="$1"
    local target=""
    local namespace=""
    local registry_type=""
    local config_type=""

    # Extract target (e.g., backup_10_single_ns_external_correct -> 10)
    target=$(echo "$test_name" | grep -oP 'backup_\K[0-9]+' || echo "unknown")

    # Extract namespace type
    if echo "$test_name" | grep -q "single_ns"; then
        namespace="Single"
    elif echo "$test_name" | grep -q "separate_ns"; then
        namespace="Separate"
    else
        namespace="unknown"
    fi

    # Extract registry type
    if echo "$test_name" | grep -q "external"; then
        registry_type="external"
    elif echo "$test_name" | grep -q "internal"; then
        registry_type="internal"
    else
        registry_type="unknown"
    fi

    # Extract config type
    if echo "$test_name" | grep -q "correct"; then
        config_type="correct"
    elif echo "$test_name" | grep -q "incorrect"; then
        config_type="incorrect"
    else
        config_type="unknown"
    fi

    echo "$target|$namespace|$registry_type|$config_type"
}

# Print CSV header
echo "Test Name,Target,Namespace,Registry Type,Config Type,Backup Jobs Total,Backup Jobs Succeeded,Backup Jobs Failed,Backup Pods Total,Workspaces Stopped,Workspaces Backed Up,Backup Success Rate (%),Backup Job Duration (Avg ms),ImageStreams Created,ImageStreams Expected,Restore Total,Restore Succeeded,Restore Failed,Restore Success Rate (%),Restore Duration (Avg ms),Avg Operator CPU (milliCPU),Avg Operator Memory (MiB),Avg Etcd CPU (milliCPU),Avg Etcd Memory (MiB),Operator CPU Violations,Operator Memory Violations,Operator Pod Restarts,Etcd Pod Restarts"

# Process each log file
for log_file in "$LOGS_DIR"/*.log; do
    [ -f "$log_file" ] || continue

    # Get test name from filename
    test_name=$(basename "$log_file" .log)

    # Parse test metadata from name
    metadata=$(parse_test_name "$test_name")
    IFS='|' read -r target namespace registry_type config_type <<< "$metadata"

    # Read log file content
    log_content=$(cat "$log_file")

    # Extract backup metrics
    backup_jobs_total=$(extract_counter "$log_content" "backup_jobs_total")
    backup_jobs_succeeded=$(extract_counter "$log_content" "backup_jobs_succeeded")
    backup_jobs_failed=$(extract_counter "$log_content" "backup_jobs_failed")
    backup_pods_total=$(extract_counter "$log_content" "backup_pods_total")
    workspaces_stopped=$(extract_counter "$log_content" "workspaces_stopped")
    workspaces_backed_up=$(extract_counter "$log_content" "workspaces_backed_up")
    backup_success_rate=$(extract_gauge "$log_content" "backup_success_rate")
    backup_job_duration=$(extract_avg "$log_content" "backup_job_duration")

    # Extract ImageStream metrics
    imagestreams_created=$(extract_counter "$log_content" "imagestreams_created")
    imagestreams_expected=$(extract_counter "$log_content" "imagestreams_expected")

    # Extract restore metrics
    restore_total=$(extract_counter "$log_content" "restore_workspaces_total")
    restore_succeeded=$(extract_counter "$log_content" "restore_workspaces_succeeded")
    restore_failed=$(extract_counter "$log_content" "restore_workspaces_failed")
    restore_success_rate=$(extract_gauge "$log_content" "restore_success_rate")
    restore_duration=$(extract_avg "$log_content" "restore_duration")

    # Extract system metrics
    avg_op_cpu=$(extract_avg "$log_content" "average_operator_cpu")
    avg_op_mem=$(extract_avg "$log_content" "average_operator_memory")
    avg_etcd_cpu=$(extract_avg "$log_content" "average_etcd_cpu")
    avg_etcd_mem=$(extract_avg "$log_content" "average_etcd_memory")
    op_cpu_viol=$(extract_counter "$log_content" "operator_cpu_violations")
    op_mem_viol=$(extract_counter "$log_content" "operator_mem_violations")
    op_pod_restarts=$(extract_gauge "$log_content" "operator_pod_restarts_total")
    etcd_pod_restarts=$(extract_gauge "$log_content" "etcd_pod_restarts_total")

    # Print CSV row
    echo "$test_name,$target,$namespace,$registry_type,$config_type,$backup_jobs_total,$backup_jobs_succeeded,$backup_jobs_failed,$backup_pods_total,$workspaces_stopped,$workspaces_backed_up,$backup_success_rate,$backup_job_duration,$imagestreams_created,$imagestreams_expected,$restore_total,$restore_succeeded,$restore_failed,$restore_success_rate,$restore_duration,$avg_op_cpu,$avg_op_mem,$avg_etcd_cpu,$avg_etcd_mem,$op_cpu_viol,$op_mem_viol,$op_pod_restarts,$etcd_pod_restarts"
done
