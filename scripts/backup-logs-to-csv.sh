#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=backup-metrics-extract.sh
source "${SCRIPT_DIR}/backup-metrics-extract.sh"

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
    backup_metrics_extract_avg "$1" "$2"
}

# Extract counter or formatted-summary count
extract_counter() {
    backup_metrics_extract_count "$1" "$2"
}

# Extract gauge values (percentages and final values)
extract_gauge() {
    local input="$1"
    local gauge_name="$2"
    # Formatted summary percentage: "imagestreamtag_success_rate ......... 100.00%"
    local pct
    pct=$(echo "$input" | grep -E "[✓✗ ] ${gauge_name}[ .]+[0-9]+%" | head -1 | grep -oE '[0-9.]+%' | tr -d '%' || true)
    if [[ -n "$pct" ]]; then
        # CSV stores rate as 0-1 fraction for some gauges; keep raw percent value for display
        echo "$pct"
        return 0
    fi
    # Formatted plain value
    local val
    val=$(echo "$input" | grep -E "[✓✗ ] ${gauge_name}[ .]+[0-9]" | head -1 | grep -oE '[0-9.]+$' || true)
    if [[ -n "$val" ]]; then
        echo "$val"
        return 0
    fi
    # Legacy k6 gauge
    echo "$input" | grep -E "^\s*✓?\s*✗?\s*$gauge_name" | awk '{
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

    # Read log file content (strip ANSI)
    log_content=$(backup_metrics_strip_ansi < "$log_file")

    # openshift-internal in filename → use internal config for job→IST mapping
    local_config_type="$config_type"
    if echo "$test_name" | grep -q '_internal'; then
        local_config_type="openshift-internal"
    fi

    # Extract backup metrics
    backup_jobs_total=$(backup_metrics_extract_count "$log_content" "backup_jobs_total")
    backup_jobs_succeeded=$(backup_metrics_extract_count "$log_content" "backup_jobs_succeeded")
    backup_jobs_failed=$(backup_metrics_extract_count "$log_content" "backup_jobs_failed")
    backup_pods_total=$(backup_metrics_extract_count "$log_content" "backup_pods_total")
    if [[ "$local_config_type" == "openshift-internal" && "${backup_jobs_total:-0}" -eq 0 ]]; then
        ist_ratio=$(backup_metrics_extract_imagestreamtags "$log_content")
        if [[ -n "$ist_ratio" ]]; then
            backup_jobs_succeeded=$(echo "$ist_ratio" | awk '{print $1}')
            backup_jobs_total=$(echo "$ist_ratio" | awk '{print $3}')
            backup_jobs_failed=$(( backup_jobs_total - backup_jobs_succeeded ))
            [[ "$backup_jobs_failed" -lt 0 ]] && backup_jobs_failed=0
        fi
    fi

    workspaces_stopped=$(backup_metrics_extract_count "$log_content" "workspaces_stopped")
    workspaces_backed_up=$(backup_metrics_extract_count "$log_content" "workspaces_backed_up")
    backup_success_rate=$(extract_gauge "$log_content" "backup_success_rate")
    backup_job_duration=$(extract_avg "$log_content" "backup_job_duration")

    # Extract ImageStream metrics
    imagestreams_created=$(backup_metrics_extract_count "$log_content" "imagestreams_created")
    imagestreams_expected=$(backup_metrics_extract_count "$log_content" "imagestreams_expected")
    if [ "$imagestreams_created" = "0" ]; then
        ist_ratio=$(backup_metrics_extract_imagestreamtags "$log_content")
        if [[ -n "$ist_ratio" ]]; then
            imagestreams_created=$(echo "$ist_ratio" | awk '{print $1}')
            imagestreams_expected=$(echo "$ist_ratio" | awk '{print $3}')
        fi
    fi

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
    op_pod_restarts=$(extract_counter "$log_content" "operator_pod_restarts_total")
    etcd_pod_restarts=$(extract_counter "$log_content" "etcd_pod_restarts_total")

    # Print CSV row
    echo "$test_name,$target,$namespace,$registry_type,$config_type,$backup_jobs_total,$backup_jobs_succeeded,$backup_jobs_failed,$backup_pods_total,$workspaces_stopped,$workspaces_backed_up,$backup_success_rate,$backup_job_duration,$imagestreams_created,$imagestreams_expected,$restore_total,$restore_succeeded,$restore_failed,$restore_success_rate,$restore_duration,$avg_op_cpu,$avg_op_mem,$avg_etcd_cpu,$avg_etcd_mem,$op_cpu_viol,$op_mem_viol,$op_pod_restarts,$etcd_pod_restarts"
done
