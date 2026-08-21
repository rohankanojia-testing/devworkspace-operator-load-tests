#!/usr/bin/env bash
set -eo pipefail

# Parse all backup test logs in a directory and generate CSV
#
# Usage: ./parse-backup-outputs.sh <output-dir>
#        ./parse-backup-outputs.sh outputs/backup_run_20260520_150000

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=backup-metrics-extract.sh
source "${SCRIPT_DIR}/backup-metrics-extract.sh"

# Check arguments
if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <output-directory>" >&2
    echo "" >&2
    echo "Example:" >&2
    echo "  $0 outputs/backup_run_20260520_150000" >&2
    echo "  $0 outputs/backup_run_20260520_150000/logs" >&2
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
CSV_FILE="backup_load_test_results.csv"

# Create CSV header if file doesn't exist
if [[ ! -f "$CSV_FILE" ]]; then
    echo "Config Type,DW Target,Backup Attempted,Backup Succeeded,Backup Pods,Backup Failed,Backup Job Duration (Avg ms),Restore Total,Restore Succeeded,Restore Failed,Restore Duration (Avg ms),Average CPU (milliCPU),Average Memory (MiB),Average Etcd CPU (milliCPU),Average Etcd Memory (MiB),Baseline Etcd CPU (milliCPU),Baseline Etcd Memory (MiB)" > "$CSV_FILE"
    echo "Created new CSV file: $CSV_FILE"
else
    echo "Appending to existing CSV file: $CSV_FILE"
fi

# Function to extract avg value from metric (legacy; prefer backup-metrics-extract.sh)
extract_avg() {
    backup_metrics_extract_avg "$1" "$2"
}

# Function to extract counter values (legacy; prefer backup-metrics-extract.sh)
extract_counter() {
    backup_metrics_extract_count "$1" "$2"
}

# Legacy gauge extractor (kept for compatibility)
extract_gauge() {
    local input="$1"
    local gauge_name="$2"
    echo "$input" | grep -E "^\s*✓?\s*✗?\s*$gauge_name" | head -1 | awk '{
        for (i=1; i<=NF; i++) {
            if ($i ~ /^value=/) {
                printf "%s", substr($i, 7)
                exit
            }
        }
        printf "0"
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

    # Extract test parameters from filename
    # Expected formats:
    #   backup_500_separate_ns_internal.log
    #   backup_2000_separate_ns_external_correct.log
    #   backup_1000_separate_ns_external_incorrect.log
    DW_TARGET=""
    CONFIG_TYPE=""

    # Extract DW target from filename
    if [[ "$FILENAME" =~ backup_([0-9]+)_ ]]; then
        DW_TARGET="${BASH_REMATCH[1]}"
    fi

    # Determine config type from filename
    if [[ "$FILENAME" =~ _internal ]]; then
        # OpenShift internal registry
        CONFIG_TYPE="openshift-internal"

        # Check for correct/incorrect in filename
        if [[ "$FILENAME" =~ _correct ]]; then
            CONFIG_TYPE="correct"
        elif [[ "$FILENAME" =~ _incorrect ]]; then
            CONFIG_TYPE="incorrect"
        fi
    elif [[ "$FILENAME" =~ _external ]]; then
        # External registry
        if [[ "$FILENAME" =~ _correct ]]; then
            CONFIG_TYPE="correct"
        elif [[ "$FILENAME" =~ _incorrect ]]; then
            CONFIG_TYPE="incorrect"
        else
            CONFIG_TYPE="external-registry"
        fi
    fi

    # If still can't determine from filename, try log content
    if [[ -z "$DW_TARGET" ]]; then
        DW_TARGET=$(grep -o 'MAX_DEVWORKSPACES: [0-9]\+' "$LOG_FILE" | head -1 | awk '{print $2}' || echo "")
        if [[ -z "$DW_TARGET" ]]; then
            DW_TARGET=$(grep -o 'max-devworkspaces [0-9]\+' "$LOG_FILE" | head -1 | awk '{print $2}' || echo "")
        fi
    fi

    if [[ -z "$CONFIG_TYPE" ]]; then
        # Try to determine from log content
        # Match both "DWOC_CONFIG_TYPE:" and "DWOC Config Type:" formats
        # Check "incorrect" first since "incorrect" contains "correct" as substring
        if grep -qE "DWOC.*(C|c)onfig.*(T|t)ype:.*incorrect" "$LOG_FILE"; then
            CONFIG_TYPE="incorrect"
        elif grep -qE "DWOC.*(C|c)onfig.*(T|t)ype:.*openshift-internal" "$LOG_FILE"; then
            CONFIG_TYPE="openshift-internal"
        elif grep -qE "DWOC.*(C|c)onfig.*(T|t)ype:.*\bcorrect\b" "$LOG_FILE"; then
            CONFIG_TYPE="correct"
        fi
    fi

    # Set defaults if still empty
    DW_TARGET=${DW_TARGET:-0}
    CONFIG_TYPE=${CONFIG_TYPE:-unknown}

    # Read log content and strip ANSI color codes
    INPUT=$(backup_metrics_strip_ansi < "$LOG_FILE")

    backup_metrics_map_legacy_csv "$INPUT" "$CONFIG_TYPE"

    # Set defaults if empty
    BACKUP_ATTEMPTED=${BACKUP_ATTEMPTED:-0}
    BACKUP_SUCCEEDED=${BACKUP_SUCCEEDED:-0}
    BACKUP_PODS=${BACKUP_PODS:-0}
    BACKUP_FAILED=${BACKUP_FAILED:-0}
    BACKUP_JOB_DURATION=${BACKUP_JOB_DURATION:-0}
    RESTORE_TOTAL=${RESTORE_TOTAL:-0}
    RESTORE_SUCCEEDED=${RESTORE_SUCCEEDED:-0}
    RESTORE_FAILED=${RESTORE_FAILED:-0}
    RESTORE_DURATION=${RESTORE_DURATION:-0}
    AVG_OP_CPU=${AVG_OP_CPU:-0}
    AVG_OP_MEM=${AVG_OP_MEM:-0}
    AVG_ETCD_CPU=${AVG_ETCD_CPU:-0}
    AVG_ETCD_MEM=${AVG_ETCD_MEM:-0}
    BASELINE_ETCD_CPU=${BASELINE_ETCD_CPU:-0}
    BASELINE_ETCD_MEM=${BASELINE_ETCD_MEM:-0}

    # Check if any metrics were found
    if [[ "$BACKUP_ATTEMPTED" == "0" && "$BACKUP_SUCCEEDED" == "0" && "$AVG_OP_CPU" == "0" ]]; then
        echo "  ⚠️  Warning: No metrics found in log file (test may have failed or incomplete)"
    elif backup_metrics_is_formatted_summary "$INPUT"; then
        echo "  ℹ️  Parsed formatted Metrics Summary"
    fi

    # Build CSV row
    CSV_ROW="$CONFIG_TYPE,$DW_TARGET,$BACKUP_ATTEMPTED,$BACKUP_SUCCEEDED,$BACKUP_PODS,$BACKUP_FAILED,$BACKUP_JOB_DURATION,$RESTORE_TOTAL,$RESTORE_SUCCEEDED,$RESTORE_FAILED,$RESTORE_DURATION,$AVG_OP_CPU,$AVG_OP_MEM,$AVG_ETCD_CPU,$AVG_ETCD_MEM,$BASELINE_ETCD_CPU,$BASELINE_ETCD_MEM"

    # Append to CSV
    echo "$CSV_ROW" >> "$CSV_FILE"

    echo "  ✅ Config: $CONFIG_TYPE, DW Target: $DW_TARGET, Backup Succeeded: $BACKUP_SUCCEEDED"

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
