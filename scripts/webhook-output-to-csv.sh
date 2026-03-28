#!/usr/bin/env bash
set -euo pipefail

# Parse webhook k6 output and convert metrics to CSV
#
# Usage: cat k6-webhook-output.txt | ./webhook-output-to-csv.sh --users 200 --iterations 200
#        echo "$K6_OUTPUT" | ./webhook-output-to-csv.sh --users 200 --iterations 200

# Parse arguments
USERS=""
ITERATIONS=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --users)
            USERS="$2"
            shift 2
            ;;
        --iterations)
            ITERATIONS="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

if [[ -z "$USERS" || -z "$ITERATIONS" ]]; then
    echo "Error: --users and --iterations are required" >&2
    echo "Usage: $0 --users <number> --iterations <number>" >&2
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

# Extract min/max values for counters like devworkspaces_ready
extract_counter_minmax() {
    local counter_name="$1"
    echo "$INPUT" | grep -E "^\s*✓?\s*✗?\s*$counter_name" | awk '{
        # Look for the first number (the count)
        for (i=1; i<=NF; i++) {
            if ($i ~ /^[0-9]+$/ && $(i+1) ~ /^min=/) {
                print $i
                exit
            }
        }
        print "0"
    }'
}

# Check if CSV file exists, if not create header
CSV_FILE="webhook_load_test_results.csv"

if [ ! -f "$CSV_FILE" ]; then
    echo "Users,Iterations,DWs Ready,Create Latency (ms),Exec Attempted,Exec Allowed,Exec Failed,Exec Denied,Exec Skipped,Exec Latency (ms),Mutating Latency (ms),Validating Latency (ms),Mutation Timeouts,Validation Timeouts,Immutable Labels Enforced (%),Webhook Restarts,Avg Webhook CPU (mCPU),Avg Webhook Mem (MB)" > "$CSV_FILE"
fi

# Extract all metrics
DW_READY=$(extract_counter_minmax "devworkspaces_ready")
CREATE_LATENCY=$(extract_avg "create_latency_ms")

EXEC_ATTEMPTED=$(extract_counter "exec_attempted")
EXEC_ALLOWED=$(extract_counter "exec_allowed_total")
EXEC_FAILED=$(extract_counter "exec_failed_total")
EXEC_DENIED=$(extract_counter "exec_denied_total")
EXEC_SKIPPED=$(extract_counter "exec_skipped_pod_not_ready")
EXEC_LATENCY=$(extract_avg "exec_latency_ms")

MUTATING_LATENCY=$(extract_avg "mutating_latency_ms")
VALIDATING_LATENCY=$(extract_avg "validating_latency_ms")

MUTATION_TIMEOUTS=$(extract_counter "mutation_webhook_timeout_500")
VALIDATION_TIMEOUTS=$(extract_counter "validation_webhook_timeout_500")
IMMUTABLE_LABELS_ENFORCED=$(extract_avg "immutable_labels_enforced_rate")

WEBHOOK_RESTARTS=$(extract_counter_minmax "webhook_pod_restarts_total")

AVG_WEBHOOK_CPU=$(extract_avg "average_webhook_cpu_millicores")
AVG_WEBHOOK_MEM=$(extract_avg "average_webhook_memory_mb")

# Build CSV row
CSV_ROW="$USERS,$ITERATIONS,$DW_READY,$CREATE_LATENCY,$EXEC_ATTEMPTED,$EXEC_ALLOWED,$EXEC_FAILED,$EXEC_DENIED,$EXEC_SKIPPED,$EXEC_LATENCY,$MUTATING_LATENCY,$VALIDATING_LATENCY,$MUTATION_TIMEOUTS,$VALIDATION_TIMEOUTS,$IMMUTABLE_LABELS_ENFORCED,$WEBHOOK_RESTARTS,$AVG_WEBHOOK_CPU,$AVG_WEBHOOK_MEM"

# Append to CSV
echo "$CSV_ROW" >> "$CSV_FILE"

echo "Results appended to $CSV_FILE"
echo ""
echo "Summary:"
echo "  Users: $USERS"
echo "  Iterations: $ITERATIONS"
echo "  DevWorkspaces Ready: $DW_READY"
echo "  Create Latency: $CREATE_LATENCY ms"
echo "  Exec Attempted: $EXEC_ATTEMPTED"
echo "  Exec Allowed: $EXEC_ALLOWED"
echo "  Exec Failed: $EXEC_FAILED"
echo "  Exec Denied: $EXEC_DENIED"
echo "  Exec Skipped (Pod Not Ready): $EXEC_SKIPPED"
echo "  Exec Latency: $EXEC_LATENCY ms"
echo "  Mutating Webhook Latency: $MUTATING_LATENCY ms"
echo "  Validating Webhook Latency: $VALIDATING_LATENCY ms"
echo "  Mutation Timeouts (500): $MUTATION_TIMEOUTS"
echo "  Validation Timeouts (500): $VALIDATION_TIMEOUTS"
echo "  Immutable Labels Enforced: $IMMUTABLE_LABELS_ENFORCED"
echo "  Webhook Pod Restarts: $WEBHOOK_RESTARTS"
echo "  Average Webhook CPU: $AVG_WEBHOOK_CPU mCPU"
echo "  Average Webhook Memory: $AVG_WEBHOOK_MEM MB"
echo ""
echo "----------------------------------------"
echo "Current CSV contents:"
echo "----------------------------------------"
cat "$CSV_FILE"
