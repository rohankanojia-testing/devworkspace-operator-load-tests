#!/usr/bin/env bash
set -eo pipefail

# Parse all webhook test logs in a directory and generate CSV
#
# Usage: ./parse-webhook-outputs.sh <output-dir>
#        ./parse-webhook-outputs.sh outputs/webhook_run_20260327_233952

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Check arguments
if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <output-directory>" >&2
    echo "" >&2
    echo "Example:" >&2
    echo "  $0 outputs/webhook_run_20260327_233952" >&2
    echo "  $0 outputs/webhook_run_20260327_233952/logs" >&2
    exit 1
fi

OUTPUT_DIR="$1"

# Validate directory exists
if [[ ! -d "$OUTPUT_DIR" ]]; then
    echo "Error: Directory not found: $OUTPUT_DIR" >&2
    exit 1
fi

# If given the run directory, look in logs subdirectory
if [[ -d "$OUTPUT_DIR/logs" ]]; then
    LOG_DIR="$OUTPUT_DIR/logs"
else
    LOG_DIR="$OUTPUT_DIR"
fi

# Find all .log files
LOG_FILES=("$LOG_DIR"/*.log)

if [[ ! -e "${LOG_FILES[0]}" ]]; then
    echo "Error: No .log files found in $LOG_DIR" >&2
    exit 1
fi

echo "Found ${#LOG_FILES[@]} log file(s) in $LOG_DIR"
echo ""

# CSV output file
CSV_FILE="webhook_load_test_results.csv"

# Create CSV header if file doesn't exist
if [[ ! -f "$CSV_FILE" ]]; then
    echo "Users,Iterations,DWs Ready,Avg Webhook CPU (mCPU),Avg Webhook Mem (MB),Create Latency (ms),Exec Attempted,Exec Allowed,Exec Denied,Exec Skipped,Exec Latency (ms),Mutating Latency (ms),Validating Latency (ms),Mutation Timeouts,Validation Timeouts,Invalid Mutating Deny,Webhook Restarts" > "$CSV_FILE"
    echo "Created new CSV file: $CSV_FILE"
else
    echo "Appending to existing CSV file: $CSV_FILE"
fi

# Function to extract avg value from metric
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
    }'
}

# Function to extract counter values
extract_counter() {
    local input="$1"
    local counter_name="$2"
    echo "$input" | grep -E "^\s*✓?\s*✗?\s*$counter_name" | awk '{
        for (i=1; i<=NF; i++) {
            if ($i ~ /^[0-9]+$/ && $(i+1) ~ /^[0-9.]+\/s$/) {
                print $i
                exit
            }
        }
        print "0"
    }'
}

# Function to extract counter with min/max
extract_counter_minmax() {
    local input="$1"
    local counter_name="$2"
    echo "$input" | grep -E "^\s*✓?\s*✗?\s*$counter_name" | awk '{
        for (i=1; i<=NF; i++) {
            if ($i ~ /^[0-9]+$/ && $(i+1) ~ /^min=/) {
                print $i
                exit
            }
        }
        print "0"
    }'
}

# Process each log file
PROCESSED_COUNT=0

for LOG_FILE in "${LOG_FILES[@]}"; do
    FILENAME=$(basename "$LOG_FILE")

    # Skip metrics files
    if [[ "$FILENAME" == *"_metrics.txt" ]]; then
        continue
    fi

    echo "Processing: $FILENAME"

    # Extract users from filename (e.g., "100users.log" -> 100, "custom_test.log" -> try to find in log)
    USERS=""
    if [[ "$FILENAME" =~ ^([0-9]+)users\.log$ ]]; then
        USERS="${BASH_REMATCH[1]}"
    else
        # Try to extract from log content
        USERS=$(grep -oP 'number-of-users\s+\K[0-9]+' "$LOG_FILE" | head -1 || echo "")
        if [[ -z "$USERS" ]]; then
            USERS=$(grep -oP 'NUM_USERS:\s*\K[0-9]+' "$LOG_FILE" | head -1 || echo "")
        fi
        if [[ -z "$USERS" ]]; then
            echo "  ⚠️  Warning: Could not determine user count, skipping"
            continue
        fi
    fi

    # Iterations is typically same as users for webhook tests
    ITERATIONS="$USERS"

    # Read log content and strip ANSI color codes
    INPUT=$(cat "$LOG_FILE" | sed 's/\x1b\[[0-9;]*m//g')

    # Extract all metrics (with defaults if not found)
    DW_READY=$(extract_counter_minmax "$INPUT" "devworkspaces_ready" || echo "0")
    AVG_WEBHOOK_CPU=$(extract_avg "$INPUT" "average_webhook_cpu_millicores" || echo "0")
    AVG_WEBHOOK_MEM=$(extract_avg "$INPUT" "average_webhook_memory_mb" || echo "0")
    CREATE_LATENCY=$(extract_avg "$INPUT" "create_latency_ms" || echo "0")

    EXEC_ATTEMPTED=$(extract_counter "$INPUT" "exec_attempted" || echo "0")
    EXEC_ALLOWED=$(extract_counter "$INPUT" "exec_allowed_total" || echo "0")
    EXEC_DENIED=$(extract_counter "$INPUT" "exec_denied_total" || echo "0")
    EXEC_SKIPPED=$(extract_counter "$INPUT" "exec_skipped_due_to_pod_not_ready" || echo "0")
    EXEC_LATENCY=$(extract_avg "$INPUT" "exec_latency_ms" || echo "0")

    MUTATING_LATENCY=$(extract_avg "$INPUT" "mutating_latency_ms" || echo "0")
    VALIDATING_LATENCY=$(extract_avg "$INPUT" "validating_latency_ms" || echo "0")

    MUTATION_TIMEOUTS=$(extract_counter "$INPUT" "mutation_webhook_timeout_500" || echo "0")
    VALIDATION_TIMEOUTS=$(extract_counter "$INPUT" "validation_webhook_timeout_500" || echo "0")
    INVALID_MUTATING_DENY=$(extract_counter "$INPUT" "invalid_mutating_deny_total" || echo "0")

    WEBHOOK_RESTARTS=$(extract_counter_minmax "$INPUT" "webhook_pod_restarts_total" || echo "0")

    # Set defaults if empty
    DW_READY=${DW_READY:-0}
    AVG_WEBHOOK_CPU=${AVG_WEBHOOK_CPU:-0}
    AVG_WEBHOOK_MEM=${AVG_WEBHOOK_MEM:-0}
    CREATE_LATENCY=${CREATE_LATENCY:-0}
    EXEC_ATTEMPTED=${EXEC_ATTEMPTED:-0}
    EXEC_ALLOWED=${EXEC_ALLOWED:-0}
    EXEC_DENIED=${EXEC_DENIED:-0}
    EXEC_SKIPPED=${EXEC_SKIPPED:-0}
    EXEC_LATENCY=${EXEC_LATENCY:-0}
    MUTATING_LATENCY=${MUTATING_LATENCY:-0}
    VALIDATING_LATENCY=${VALIDATING_LATENCY:-0}
    MUTATION_TIMEOUTS=${MUTATION_TIMEOUTS:-0}
    VALIDATION_TIMEOUTS=${VALIDATION_TIMEOUTS:-0}
    INVALID_MUTATING_DENY=${INVALID_MUTATING_DENY:-0}
    WEBHOOK_RESTARTS=${WEBHOOK_RESTARTS:-0}

    # Check if any metrics were found
    if [[ "$DW_READY" == "0" && "$AVG_WEBHOOK_CPU" == "0" && "$EXEC_ATTEMPTED" == "0" ]]; then
        echo "  ⚠️  Warning: No metrics found in log file (test may have failed or incomplete)"
    fi

    # Build CSV row
    CSV_ROW="$USERS,$ITERATIONS,$DW_READY,$AVG_WEBHOOK_CPU,$AVG_WEBHOOK_MEM,$CREATE_LATENCY,$EXEC_ATTEMPTED,$EXEC_ALLOWED,$EXEC_DENIED,$EXEC_SKIPPED,$EXEC_LATENCY,$MUTATING_LATENCY,$VALIDATING_LATENCY,$MUTATION_TIMEOUTS,$VALIDATION_TIMEOUTS,$INVALID_MUTATING_DENY,$WEBHOOK_RESTARTS"

    # Append to CSV
    echo "$CSV_ROW" >> "$CSV_FILE"

    echo "  ✅ Users: $USERS, DWs Ready: $DW_READY, Create Latency: ${CREATE_LATENCY}ms"

    PROCESSED_COUNT=$((PROCESSED_COUNT + 1))
done

echo ""
echo "=========================================="
echo "✅ Processed $PROCESSED_COUNT log file(s)"
echo "=========================================="
echo "Results saved to: $CSV_FILE"
echo ""
echo "CSV Contents:"
echo "----------------------------------------"
cat "$CSV_FILE"
echo "----------------------------------------"
