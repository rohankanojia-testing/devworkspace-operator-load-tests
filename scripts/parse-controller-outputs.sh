#!/usr/bin/env bash
set -eo pipefail

# Parse all controller test logs in a directory and generate CSV
#
# Usage: ./parse-controller-outputs.sh <output-dir>
#        ./parse-controller-outputs.sh outputs/run_20260518_204706
#        ./parse-controller-outputs.sh outputs/run_20260518_204706/logs

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Check arguments
if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <output-directory>" >&2
    echo "" >&2
    echo "Example:" >&2
    echo "  $0 outputs/run_20260518_204706" >&2
    echo "  $0 outputs/run_20260518_204706/logs" >&2
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
CSV_FILE="controller_load_test_results.csv"

# Create CSV header if file doesn't exist
if [[ ! -f "$CSV_FILE" ]]; then
    echo "Max DWs,Namespace Mode,Duration (min),DWs Created,DWs Ready,Ready Failed,Ready Failed %,Avg CPU (mCPU),Avg Mem (MiB),Create Duration (ms),Ready Duration (ms),CPU Violations,Mem Violations,Avg Etcd CPU (mCPU),Avg Etcd Mem (MiB)" > "$CSV_FILE"
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
    if [[ "$FILENAME" == *"_metrics.txt" ]] || [[ "$FILENAME" == *"_failure_report.csv" ]]; then
        continue
    fi

    echo "Processing: $FILENAME"

    # Extract test parameters from filename
    # Expected formats:
    #   1500_single_ns_40m.log or 1500_separate_ns_60m.log (with duration)
    #   3000_single_ns.log or 2000_separate_ns.log (without duration)
    MAX_DWS=""
    NAMESPACE_MODE=""
    DURATION=""

    if [[ "$FILENAME" =~ ^([0-9]+)_(single|separate)_ns_([0-9]+)m\.log$ ]]; then
        # Format with duration: 1500_single_ns_40m.log
        MAX_DWS="${BASH_REMATCH[1]}"
        NAMESPACE_MODE="${BASH_REMATCH[2]}"
        DURATION="${BASH_REMATCH[3]}"
    elif [[ "$FILENAME" =~ ^([0-9]+)_(single|separate)_ns\.log$ ]]; then
        # Format without duration: 3000_single_ns.log
        MAX_DWS="${BASH_REMATCH[1]}"
        NAMESPACE_MODE="${BASH_REMATCH[2]}"
        DURATION=""  # Will try to extract from log content
    else
        # Try to extract from log content (BSD-compatible)
        MAX_DWS=$(grep -o 'max-devworkspaces [0-9]\+' "$LOG_FILE" | head -1 | awk '{print $2}' || echo "")

        # Determine namespace mode from log
        if grep -q "separate-namespaces true" "$LOG_FILE"; then
            NAMESPACE_MODE="separate"
        elif grep -q "separate-namespaces false" "$LOG_FILE"; then
            NAMESPACE_MODE="single"
        else
            NAMESPACE_MODE="unknown"
        fi

        # Extract duration (BSD-compatible)
        DURATION=$(grep -o 'test-duration-minutes [0-9]\+' "$LOG_FILE" | head -1 | awk '{print $2}' || echo "")

        if [[ -z "$MAX_DWS" ]]; then
            echo "  ⚠️  Warning: Could not determine test parameters, skipping"
            continue
        fi
    fi

    # Set defaults
    MAX_DWS=${MAX_DWS:-0}
    NAMESPACE_MODE=${NAMESPACE_MODE:-unknown}
    DURATION=${DURATION:-0}

    # Read log content and strip ANSI color codes
    INPUT=$(cat "$LOG_FILE" | sed 's/\x1b\[[0-9;]*m//g')

    # Extract all metrics (with defaults if not found)
    DW_CREATE_COUNT=$(extract_counter "$INPUT" "devworkspace_create_count" || echo "0")
    DW_READY_COUNT=$(extract_counter_minmax "$INPUT" "devworkspace_ready" || echo "0")
    DW_READY_FAILED=$(extract_counter "$INPUT" "devworkspace_ready_failed" || echo "0")

    # Calculate Ready Failed percentage
    if [[ "$DW_CREATE_COUNT" -gt 0 ]]; then
        READY_FAILED_PCT=$(awk "BEGIN {printf \"%.2f\", ($DW_READY_FAILED / $DW_CREATE_COUNT) * 100}")
    else
        READY_FAILED_PCT="0.00"
    fi

    # Extract operator metrics (avg values)
    AVG_OP_CPU=$(extract_avg "$INPUT" "average_operator_cpu" || echo "0")
    AVG_OP_MEM=$(extract_avg "$INPUT" "average_operator_memory" || echo "0")

    # Extract durations (avg values)
    AVG_CREATE_DUR=$(extract_avg "$INPUT" "devworkspace_create_duration" || echo "0")
    AVG_READY_DUR=$(extract_avg "$INPUT" "devworkspace_ready_duration" || echo "0")

    # Extract violations
    OP_CPU_VIOL=$(extract_counter "$INPUT" "operator_cpu_violations" || echo "0")
    OP_MEM_VIOL=$(extract_counter "$INPUT" "operator_mem_violations" || echo "0")

    # Extract ETCD metrics (avg values)
    AVG_ETCD_CPU=$(extract_avg "$INPUT" "average_etcd_cpu" || echo "0")
    AVG_ETCD_MEM=$(extract_avg "$INPUT" "average_etcd_memory" || echo "0")

    # Set defaults if empty
    DW_CREATE_COUNT=${DW_CREATE_COUNT:-0}
    DW_READY_COUNT=${DW_READY_COUNT:-0}
    DW_READY_FAILED=${DW_READY_FAILED:-0}
    AVG_OP_CPU=${AVG_OP_CPU:-0}
    AVG_OP_MEM=${AVG_OP_MEM:-0}
    AVG_CREATE_DUR=${AVG_CREATE_DUR:-0}
    AVG_READY_DUR=${AVG_READY_DUR:-0}
    OP_CPU_VIOL=${OP_CPU_VIOL:-0}
    OP_MEM_VIOL=${OP_MEM_VIOL:-0}
    AVG_ETCD_CPU=${AVG_ETCD_CPU:-0}
    AVG_ETCD_MEM=${AVG_ETCD_MEM:-0}

    # Check if any metrics were found
    if [[ "$DW_CREATE_COUNT" == "0" && "$AVG_OP_CPU" == "0" && "$DW_READY_COUNT" == "0" ]]; then
        echo "  ⚠️  Warning: No metrics found in log file (test may have failed or incomplete)"
    fi

    # Build CSV row
    CSV_ROW="$MAX_DWS,$NAMESPACE_MODE,$DURATION,$DW_CREATE_COUNT,$DW_READY_COUNT,$DW_READY_FAILED,$READY_FAILED_PCT,$AVG_OP_CPU,$AVG_OP_MEM,$AVG_CREATE_DUR,$AVG_READY_DUR,$OP_CPU_VIOL,$OP_MEM_VIOL,$AVG_ETCD_CPU,$AVG_ETCD_MEM"

    # Append to CSV
    echo "$CSV_ROW" >> "$CSV_FILE"

    echo "  ✅ Max DWs: $MAX_DWS, Mode: $NAMESPACE_MODE, Created: $DW_CREATE_COUNT, Ready: $DW_READY_COUNT"

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
