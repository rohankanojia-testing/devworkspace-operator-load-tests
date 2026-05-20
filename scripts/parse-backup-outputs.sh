#!/usr/bin/env bash
set -eo pipefail

# Parse all backup test logs in a directory and generate CSV
#
# Usage: ./parse-backup-outputs.sh <output-dir>
#        ./parse-backup-outputs.sh outputs/backup_run_20260520_150000

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
    echo "Config Type,DW Target,Backup Attempted,Backup Succeeded,Backup Pods,Backup Failed,Backup Job Duration (Avg ms),Restore Total,Restore Succeeded,Restore Failed,Restore Duration (Avg ms),Average CPU (milliCPU),Average Memory (MiB),Average Etcd CPU (milliCPU),Average Etcd Memory (MiB)" > "$CSV_FILE"
    echo "Created new CSV file: $CSV_FILE"
else
    echo "Appending to existing CSV file: $CSV_FILE"
fi

# Function to extract avg value from metric
extract_avg() {
    local input="$1"
    local metric_name="$2"
    echo "$input" | grep -E "^\s*✓?\s*✗?\s*$metric_name" | head -1 | awk '{
        for (i=1; i<=NF; i++) {
            if ($i ~ /^avg=/) {
                printf "%s", substr($i, 5)
                exit
            }
        }
        printf "0"
    }'
}

# Function to extract counter values
extract_counter() {
    local input="$1"
    local counter_name="$2"
    echo "$input" | grep -E "^\s*✓?\s*✗?\s*$counter_name" | head -1 | awk '{
        for (i=1; i<=NF; i++) {
            if ($i ~ /^[0-9]+$/ && $(i+1) ~ /^[0-9.]+\/s$/) {
                printf "%s", $i
                exit
            }
        }
        printf "0"
    }'
}

# Function to extract gauge values
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
            CONFIG_TYPE="openshift-internal correct"
        elif [[ "$FILENAME" =~ _incorrect ]]; then
            CONFIG_TYPE="openshift-internal incorrect"
        fi
    elif [[ "$FILENAME" =~ _external ]]; then
        # External registry
        if [[ "$FILENAME" =~ _correct ]]; then
            CONFIG_TYPE="external registry correct"
        elif [[ "$FILENAME" =~ _incorrect ]]; then
            CONFIG_TYPE="external registry incorrect"
        else
            CONFIG_TYPE="external registry"
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
        if grep -q "DWOC_CONFIG_TYPE: openshift-internal" "$LOG_FILE"; then
            CONFIG_TYPE="openshift-internal"
        elif grep -q "DWOC_CONFIG_TYPE: correct" "$LOG_FILE"; then
            if grep -q "REGISTRY_PATH:.*quay.io" "$LOG_FILE"; then
                CONFIG_TYPE="external registry correct"
            else
                CONFIG_TYPE="openshift-internal correct"
            fi
        elif grep -q "DWOC_CONFIG_TYPE: incorrect" "$LOG_FILE"; then
            if grep -q "REGISTRY_PATH:.*quay.io" "$LOG_FILE"; then
                CONFIG_TYPE="external registry incorrect"
            else
                CONFIG_TYPE="openshift-internal incorrect"
            fi
        fi
    fi

    # Set defaults if still empty
    DW_TARGET=${DW_TARGET:-0}
    CONFIG_TYPE=${CONFIG_TYPE:-unknown}

    # Read log content and strip ANSI color codes
    INPUT=$(cat "$LOG_FILE" | sed 's/\x1b\[[0-9;]*m//g')

    # Extract backup metrics
    BACKUP_ATTEMPTED=$(extract_counter "$INPUT" "backup_jobs_total" || echo "0")
    BACKUP_SUCCEEDED=$(extract_counter "$INPUT" "backup_jobs_succeeded" || echo "0")
    BACKUP_PODS=$(extract_counter "$INPUT" "backup_pods_total" || echo "0")
    BACKUP_FAILED=$(extract_counter "$INPUT" "backup_jobs_failed" || echo "0")
    BACKUP_JOB_DURATION=$(extract_avg "$INPUT" "backup_job_duration" || echo "0")

    # Extract restore metrics
    RESTORE_TOTAL=$(extract_counter "$INPUT" "restore_workspaces_total" || echo "0")
    RESTORE_SUCCEEDED=$(extract_counter "$INPUT" "restore_workspaces_succeeded" || echo "0")
    RESTORE_FAILED=$(extract_counter "$INPUT" "restore_workspaces_failed" || echo "0")
    RESTORE_DURATION=$(extract_avg "$INPUT" "restore_duration" || echo "0")

    # Extract operator metrics
    AVG_OP_CPU=$(extract_avg "$INPUT" "average_operator_cpu" || echo "0")
    AVG_OP_MEM=$(extract_avg "$INPUT" "average_operator_memory" || echo "0")

    # Extract ETCD metrics
    AVG_ETCD_CPU=$(extract_avg "$INPUT" "average_etcd_cpu" || echo "0")
    AVG_ETCD_MEM=$(extract_avg "$INPUT" "average_etcd_memory" || echo "0")

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

    # Check if any metrics were found
    if [[ "$BACKUP_ATTEMPTED" == "0" && "$BACKUP_SUCCEEDED" == "0" && "$AVG_OP_CPU" == "0" ]]; then
        echo "  ⚠️  Warning: No metrics found in log file (test may have failed or incomplete)"
    fi

    # Build CSV row
    CSV_ROW="$CONFIG_TYPE,$DW_TARGET,$BACKUP_ATTEMPTED,$BACKUP_SUCCEEDED,$BACKUP_PODS,$BACKUP_FAILED,$BACKUP_JOB_DURATION,$RESTORE_TOTAL,$RESTORE_SUCCEEDED,$RESTORE_FAILED,$RESTORE_DURATION,$AVG_OP_CPU,$AVG_OP_MEM,$AVG_ETCD_CPU,$AVG_ETCD_MEM"

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
