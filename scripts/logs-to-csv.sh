#!/usr/bin/env bash
set -euo pipefail

# Read load test logs from a directory and generate CSV report
#
# Usage: ./logs-to-csv.sh <logs-directory>
# Example: ./logs-to-csv.sh outputs/run_20260324_123456/logs/

if [ $# -eq 0 ]; then
    echo "Error: logs directory required" >&2
    echo "Usage: $0 <logs-directory>" >&2
    echo "Example: $0 outputs/run_20260324_123456/logs/" >&2
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

    # Extract target (e.g., 1500_single_ns_40m -> 1500)
    target=$(echo "$test_name" | grep -oP '^\K[0-9]+' || echo "unknown")

    # Extract namespace type
    if echo "$test_name" | grep -q "single_ns"; then
        namespace="Single"
    elif echo "$test_name" | grep -q "separate_ns"; then
        namespace="Separate"
    else
        namespace="unknown"
    fi

    echo "$target|$namespace"
}

# Print CSV header
echo "Test Name,Target,Namespace,DevWorkspaces Created,DevWorkspaces Ready,DevWorkspaces Ready Failed,DevWorkspaces Create Failed,Ready Failed (%),Create Failed (%),Create Duration (Avg ms),Ready Duration (Avg ms),Delete Duration (Avg ms),Avg Operator CPU (milliCPU),Avg Operator Memory (MiB),Avg Etcd CPU (milliCPU),Avg Etcd Memory (MiB),Operator CPU Violations,Operator Memory Violations,Operator Pod Restarts,Etcd Pod Restarts"

# Process each log file
for log_file in "$LOGS_DIR"/*.log; do
    [ -f "$log_file" ] || continue

    # Get test name from filename
    test_name=$(basename "$log_file" .log)

    # Parse test metadata from name
    metadata=$(parse_test_name "$test_name")
    IFS='|' read -r target namespace <<< "$metadata"

    # Read log file content
    log_content=$(cat "$log_file")

    # Extract DevWorkspace metrics
    dw_create_count=$(extract_counter "$log_content" "devworkspace_create_count")
    dw_ready=$(extract_counter "$log_content" "devworkspace_ready")
    dw_ready_failed=$(extract_counter "$log_content" "devworkspace_ready_failed")
    dw_create_failed=$(extract_counter "$log_content" "devworkspace_create_failed")

    # Calculate failure percentages
    if [ "$dw_create_count" -gt 0 ]; then
        ready_failed_pct=$(awk "BEGIN {printf \"%.2f\", ($dw_ready_failed / $dw_create_count) * 100}")
        create_failed_pct=$(awk "BEGIN {printf \"%.2f\", ($dw_create_failed / $dw_create_count) * 100}")
    else
        ready_failed_pct="0.00"
        create_failed_pct="0.00"
    fi

    # Extract duration metrics
    create_duration=$(extract_avg "$log_content" "devworkspace_create_duration")
    ready_duration=$(extract_avg "$log_content" "devworkspace_ready_duration")
    delete_duration=$(extract_avg "$log_content" "devworkspace_delete_duration")

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
    echo "$test_name,$target,$namespace,$dw_create_count,$dw_ready,$dw_ready_failed,$dw_create_failed,$ready_failed_pct,$create_failed_pct,$create_duration,$ready_duration,$delete_duration,$avg_op_cpu,$avg_op_mem,$avg_etcd_cpu,$avg_etcd_mem,$op_cpu_viol,$op_mem_viol,$op_pod_restarts,$etcd_pod_restarts"
done
