#!/bin/bash

# ============================================================================
# DevWorkspace Backup Load Testing Suite Runner
# ============================================================================
#
# This script runs multiple backup load tests sequentially with automated
# cleanup between tests and generates comprehensive reports.
#
# USAGE:
#   ./scripts/run_all_backup_loadtests.sh <TEST_PLAN_FILE>
#
# ARGUMENTS:
#   TEST_PLAN_FILE            - JSON test plan file (required)
#
# ENVIRONMENT VARIABLES:
#   OUTPUT_DIR                - Base directory for outputs (default: outputs/)
#   SKIP_CLEANUP              - Skip cleanup steps (default: false)
#   RESTART_OPERATOR          - Restart DWO operator after cleanup (default: true)
#   PROVISION_PVS             - Run provision-pvs.sh before tests (default: true; auto false on CRC)
#   PROVISION_PV_EXTRA        - Extra PV headroom beyond max workspaces (default: MAX_RESTORE_SAMPLES or 10)
#                               Covers parallel restore samples while originals release PVCs
#   TEST_TIMEOUT              - Max time per test in seconds (default: 18000 = 5h)
#   CLEANUP_MAX_WAIT          - Max time for cleanup in seconds (default: 7200 = 2h)
#
# EXAMPLES:
#   # Run with backup test plan
#   ./scripts/run_all_backup_loadtests.sh test-plans/backup-restore-crc-complete-test-plan.json
#
#   # Run with custom output directory
#   OUTPUT_DIR=./my-results ./scripts/run_all_backup_loadtests.sh test-plans/backup-restore-smoke-test-plan.json
#
#   # Run without cleanup (for debugging)
#   SKIP_CLEANUP=true ./scripts/run_all_backup_loadtests.sh test-plans/backup-restore-crc-complete-test-plan.json
#
# OUTPUT:
#   All results are saved in OUTPUT_DIR/run_TIMESTAMP/:
#   - summary.txt           - Text summary of results
#   - logs/                 - Individual test logs and metrics
#
# ============================================================================

set -o pipefail

# --- Configuration ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_DIR="${OUTPUT_DIR:-outputs}"
RUN_DIR="$OUTPUT_DIR/backup_run_$TIMESTAMP"
LOG_DIR="$RUN_DIR/logs"
MAKE_COMMAND="make test_backup"
POLL_INTERVAL=30
CLEANUP_MAX_WAIT=7200   # 2 hours for cleanup
TEST_TIMEOUT=18000      # 5 hours per test (backup tests take longer)
SKIP_CLEANUP="${SKIP_CLEANUP:-false}"
RESTART_OPERATOR="${RESTART_OPERATOR:-true}"
# Headroom for restore verification (parallel samples may overlap with terminating PVCs)
PROVISION_PV_EXTRA="${PROVISION_PV_EXTRA-${MAX_RESTORE_SAMPLES:-10}}"

# Test plan file (required)
TEST_PLAN_FILE="${1:-}"

# Validate test plan file is provided
if [ -z "$TEST_PLAN_FILE" ]; then
    echo "ERROR: Test plan file is required for backup tests"
    echo ""
    echo "USAGE:"
    echo "  $0 <test-plan-file.json>"
    echo ""
    echo "EXAMPLE:"
    echo "  $0 test-plans/backup-restore-crc-complete-test-plan.json"
    exit 1
fi

# Check for jq
if ! command -v jq &> /dev/null; then
    echo "ERROR: jq is required but not installed."
    echo "Install it with: brew install jq (macOS) or apt-get install jq (Linux)"
    exit 1
fi

# Validate test plan file exists
if [ ! -f "$TEST_PLAN_FILE" ]; then
    echo "ERROR: Test plan file not found: $TEST_PLAN_FILE"
    exit 1
fi

# Validate JSON
if ! jq empty "$TEST_PLAN_FILE" 2>/dev/null; then
    echo "ERROR: Invalid JSON in test plan file: $TEST_PLAN_FILE"
    exit 1
fi

########################################
# CRC DETECTION & PV PROVISIONING DEFAULT
########################################
is_crc_cluster() {
    local console_url
    console_url=$(kubectl get console cluster -o jsonpath='{.status.consoleURL}' 2>/dev/null || echo "")

    if [[ "${console_url}" == *"crc.testing"* ]] || [[ "${console_url}" == *"apps-crc"* ]]; then
        return 0
    fi

    local cluster_domain
    cluster_domain=$(kubectl get ingress.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || echo "")

    if [[ "${cluster_domain}" == *"crc.testing"* ]] || [[ "${cluster_domain}" == *"apps-crc"* ]]; then
        return 0
    fi

    return 1
}

# Respect PROVISION_PVS when already exported (e.g. PROVISION_PVS=true|false).
# Only apply defaults when the variable was not set before this script runs.
if [ -n "${PROVISION_PVS+x}" ]; then
    PROVISION_PVS_USER_SET=true
else
    PROVISION_PVS_USER_SET=false
fi

if is_crc_cluster; then
    if [ "$PROVISION_PVS_USER_SET" == "true" ]; then
        PROVISION_PVS_AUTO_DISABLED=false
    else
        PROVISION_PVS=false
        PROVISION_PVS_AUTO_DISABLED=true
    fi
else
    if [ "$PROVISION_PVS_USER_SET" != "true" ]; then
        PROVISION_PVS=true
    fi
    PROVISION_PVS_AUTO_DISABLED=false
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test tracking
declare -a TEST_RESULTS
declare -a TEST_PLAN
TEST_COUNT=0
PASSED_COUNT=0
FAILED_COUNT=0

echo "========================================================"
echo "Starting backup load test suite at $(date)"
echo "========================================================"
echo "Test plan file: $TEST_PLAN_FILE"

mkdir -p "$LOG_DIR"
mkdir -p "$OUTPUT_DIR"

# Create README in output directory
cat > "$OUTPUT_DIR/README.md" <<'EOREADME'
# Backup Load Test Results

This directory contains the results of backup load test runs.

## Directory Structure

Each run is stored in a `backup_run_YYYYMMDD_HHMMSS/` directory containing:
- `summary.txt` - Text summary of all test results
- `logs/` - Directory containing individual test logs
  - `<test_name>.log` - Full test output
  - `<test_name>_metrics.txt` - Extracted metrics and summary

## Viewing Results

1. View the text summary:
   ```bash
   cat backup_run_YYYYMMDD_HHMMSS/summary.txt
   ```

2. Check individual test logs:
   ```bash
   cat backup_run_YYYYMMDD_HHMMSS/logs/<test_name>.log
   ```

3. Check extracted metrics:
   ```bash
   cat backup_run_YYYYMMDD_HHMMSS/logs/<test_name>_metrics.txt
   ```

## Test Status

- **PASSED**: Test completed successfully
- **FAILED**: Test failed with errors
- **TIMEOUT**: Test exceeded maximum time limit
- **CLEANUP_FAILED**: Pre-test cleanup failed
EOREADME

echo "Output directory: $RUN_DIR"
echo "Logs directory: $LOG_DIR"
echo "Skip cleanup: $SKIP_CLEANUP"
echo "Restart operator: $RESTART_OPERATOR"
echo "Provision PVs: $PROVISION_PVS"
if [ "$PROVISION_PVS_USER_SET" == "true" ]; then
    echo "  (PROVISION_PVS set in environment — CRC/default auto logic not applied)"
elif [ "${PROVISION_PVS_AUTO_DISABLED:-false}" == "true" ]; then
    echo "  (CRC detected — using cluster dynamic storage; set PROVISION_PVS=true to force static PVs)"
fi
if [ "$PROVISION_PVS" == "true" ]; then
    echo "PV extra headroom: ${PROVISION_PV_EXTRA} (PROVISION_PV_EXTRA; default matches MAX_RESTORE_SAMPLES)"
fi
echo "Test timeout: ${TEST_TIMEOUT}s"
echo "Cleanup timeout: ${CLEANUP_MAX_WAIT}s"
echo "--------------------------------------------------------"

# Trap to handle interruption
trap 'handle_interrupt' INT TERM

handle_interrupt() {
    echo ""
    echo -e "${YELLOW}========================================${NC}"
    echo -e "${YELLOW}Test suite interrupted!${NC}"
    echo -e "${YELLOW}========================================${NC}"
    echo "Generating partial results..."
    generate_summary_report
    echo ""
    echo "Partial results saved in: $RUN_DIR"
    exit 130
}


########################################
# PV PROVISIONING FOR BACKUP TESTS     #
########################################
delete_old_pvs() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}Deleting old PVs from previous runs...${NC}"
    echo -e "${BLUE}========================================${NC}"

    local pv_label="${PV_LABEL:-load-test}"
    local pv_count=$(kubectl get pv -l ${pv_label} --no-headers 2>/dev/null | wc -l || echo "0")

    if [ "$pv_count" -eq 0 ]; then
        echo "No old PVs found with label ${pv_label}"
        return 0
    fi

    echo "Found $pv_count PVs with label ${pv_label}, deleting..."
    kubectl delete pv -l ${pv_label} --wait=false 2>/dev/null || true

    # Wait for PVs to be deleted
    local max_wait=120
    local elapsed=0
    while [ "$elapsed" -lt "$max_wait" ]; do
        local remaining=$(kubectl get pv -l ${pv_label} --no-headers 2>/dev/null | wc -l || echo "0")
        if [ "$remaining" -eq 0 ]; then
            echo -e "${GREEN}All old PVs deleted successfully${NC}"
            return 0
        fi
        echo "  Waiting for $remaining PVs to be deleted... (${elapsed}s)"
        sleep 10
        elapsed=$((elapsed + 10))
    done

    echo -e "${YELLOW}Warning: Some PVs may still be deleting${NC}"
    return 0
}

provision_pvs_for_test() {
    local max_workspaces="$1"

    if [ -z "$max_workspaces" ] || [ "$max_workspaces" -eq 0 ]; then
        echo "Skipping PV provisioning - no max_workspaces specified"
        return 0
    fi

    # Call the external PV provisioning script
    local pv_script="${SCRIPT_DIR}/provision-pvs.sh"

    if [ ! -f "$pv_script" ]; then
        echo -e "${RED}ERROR: PV provisioning script not found: $pv_script${NC}"
        return 1
    fi

    bash "$pv_script" "$max_workspaces"
}

calculate_pv_provision_count() {
    local max_workspaces="$1"
    local pv_base=$(( max_workspaces + PROVISION_PV_EXTRA ))
    # 10% headroom before provision-pvs.sh (which applies another 10%)
    echo $(( pv_base + (pv_base / 10) ))
}

get_max_workspaces_from_plan() {
    # Find the highest max-devworkspaces value in the test plan
    local max_workspaces=0
    local custom_count=$(jq '.custom_tests | length' "$TEST_PLAN_FILE" 2>/dev/null || echo "0")

    for ((i=0; i<custom_count; i++)); do
        local enabled=$(jq -r ".custom_tests[$i].enabled" "$TEST_PLAN_FILE")

        if [ "$enabled" != "true" ]; then
            continue
        fi

        local args=$(jq -r ".custom_tests[$i].args" "$TEST_PLAN_FILE")
        local workspaces=$(echo "$args" | grep -oP '(?<=--max-devworkspaces )\S+' || echo "0")

        if [ "$workspaces" -gt "$max_workspaces" ]; then
            max_workspaces=$workspaces
        fi
    done

    echo "$max_workspaces"
}


########################################
# LOAD-TEST IMAGESTREAMTAG CLEANUP     #
########################################
count_load_test_imagestreamtags() {
    local count
    count=$(kubectl get imagestreamtags -A -o json 2>/dev/null | jq '[.items[] | select(
      .metadata.namespace == "loadtest-devworkspaces" or
      (.metadata.namespace | test("^load-test-ns-"))
    )] | length' 2>/dev/null || echo "0")
    if [[ -z "$count" || "$count" == "null" ]]; then
        echo "0"
    else
        echo "$count"
    fi
}

delete_imagestreams_in_namespace() {
    local ns="${1}"
    [[ -z "$ns" ]] && return 0
    kubectl delete imagestreams --all -n "$ns" --ignore-not-found --wait=false 2>/dev/null || true
}

delete_load_test_namespaces() {
    local ns_list ns

    ns_list=$(kubectl get ns -o json 2>/dev/null | jq -r '.items[] | select(
      .metadata.name == "loadtest-devworkspaces" or
      (.metadata.name | test("^load-test-ns-")) or
      (.metadata.labels["load-test"] == "test-type")
    ) | .metadata.name' 2>/dev/null | sort -u || true)

    while IFS= read -r ns; do
        [[ -z "$ns" ]] && continue
        delete_imagestreams_in_namespace "$ns"
        kubectl delete ns "$ns" --ignore-not-found --wait=false 2>/dev/null || true
    done <<< "$ns_list"
}

count_load_test_namespaces() {
    local count
    count=$(kubectl get ns -o json 2>/dev/null | jq '[.items[] | select(
      .metadata.name == "loadtest-devworkspaces" or
      (.metadata.name | test("^load-test-ns-")) or
      (.metadata.labels["load-test"] == "test-type")
    ) | .metadata.name] | unique | length' 2>/dev/null || echo "0")
    if [[ -z "$count" || "$count" == "null" ]]; then
        echo "0"
    else
        echo "$count"
    fi
}


########################################
# WAIT FOR COMPLETE CLEANUP CONDITIONS #
########################################
wait_for_cleanup() {
    if [ "$SKIP_CLEANUP" == "true" ]; then
        echo -e "${YELLOW}Skipping cleanup (SKIP_CLEANUP=true)${NC}"
        return 0
    fi

    echo -e "${BLUE}Waiting for environment cleanup...${NC}"
    echo "Conditions:"
    echo "  1) No DevWorkspaces anywhere (we'll delete leftovers)"
    echo "  2) No load-test namespaces (load-test-ns-*, loadtest-devworkspaces, labeled)"
    echo "  3) No backup jobs (we'll delete leftovers)"
    echo "  4) No ImageStreamTags in load-test namespaces (backup artifacts)"
    echo "--------------------------------------------------------"

    local start_time=$(date +%s)
    local cleanup_attempt=0

    while true; do
        local now=$(date +%s)
        local elapsed=$((now - start_time))
        cleanup_attempt=$((cleanup_attempt + 1))

        if [ $elapsed -gt $CLEANUP_MAX_WAIT ]; then
            echo -e "${RED}ERROR: Cleanup did not finish within $CLEANUP_MAX_WAIT seconds${NC}"
            local final_ist
            final_ist=$(count_load_test_imagestreamtags)
            echo -e "${RED}  Remaining load-test ImageStreamTags: ${final_ist}${NC}"
            return 1
        fi

        # --- Delete leftover DevWorkspaces ---
        local dw_list
        dw_list=$(kubectl get dw --all-namespaces --no-headers 2>/dev/null || true)

        local dw_count=0
        if [[ -n "$dw_list" ]] && ! echo "$dw_list" | grep -qi "No resources found"; then
            dw_count=$(echo "$dw_list" | wc -l | tr -d ' ')
            echo -e "${YELLOW}Found $dw_count leftover DevWorkspaces. Deleting...${NC}"
            echo "$dw_list" | awk '{print $2, $1}' | while read -r dw ns; do
                if [[ -n "$dw" && -n "$ns" ]]; then
                    echo "  Deleting DevWorkspace $dw in namespace $ns..."
                    kubectl delete dw "$dw" -n "$ns" --wait=false 2>/dev/null || true
                fi
            done
        fi

        # --- Delete leftover backup jobs ---
        local backup_jobs_list
        backup_jobs_list=$(kubectl get jobs --all-namespaces -l devworkspace.devfile.io/backup-job=true --no-headers 2>/dev/null || true)
        local backup_jobs_count=0
        if [[ -n "$backup_jobs_list" ]]; then
            backup_jobs_count=$(echo "$backup_jobs_list" | wc -l | tr -d ' ')
            echo -e "${YELLOW}Found $backup_jobs_count leftover backup jobs. Deleting...${NC}"
            echo "$backup_jobs_list" | awk '{print $2, $1}' | while read -r job ns; do
                if [[ -n "$job" && -n "$ns" ]]; then
                    echo "  Deleting job $job in namespace $ns..."
                    kubectl delete job "$job" -n "$ns" --wait=false 2>/dev/null || true
                fi
            done
        fi

        # --- Delete load-test namespaces (and ImageStreams within them) ---
        local load_test_ns_count
        load_test_ns_count=$(count_load_test_namespaces)
        if [ "$load_test_ns_count" -gt 0 ]; then
            echo -e "${YELLOW}Found $load_test_ns_count load-test namespace(s). Deleting (ImageStreams first)...${NC}"
            delete_load_test_namespaces
        fi

        # --- Delete stray ImageStreamTags if namespaces are gone but tags remain ---
        local ist_count
        ist_count=$(count_load_test_imagestreamtags)
        if [ "$ist_count" -gt 0 ]; then
            echo -e "${YELLOW}Found $ist_count load-test ImageStreamTag(s). Deleting parent ImageStreams...${NC}"
            local ist_ns_list
            ist_ns_list=$(kubectl get imagestreamtags -A -o json 2>/dev/null | jq -r '
              [.items[] | select(
                .metadata.namespace == "loadtest-devworkspaces" or
                (.metadata.namespace | test("^load-test-ns-"))
              ) | .metadata.namespace] | unique | .[]' 2>/dev/null || true)
            while IFS= read -r ns; do
                delete_imagestreams_in_namespace "$ns"
            done <<< "$ist_ns_list"
        fi

        # Re-count after deletion attempts
        load_test_ns_count=$(count_load_test_namespaces)
        ist_count=$(count_load_test_imagestreamtags)

        # --- All conditions satisfied ---
        if [ "$dw_count" -eq 0 ] && [ "$load_test_ns_count" -eq 0 ] && \
           [ "$backup_jobs_count" -eq 0 ] && [ "$ist_count" -eq 0 ]; then
            echo -e "${GREEN}Cleanup complete after ${elapsed}s (${cleanup_attempt} attempts)${NC}"
            echo -e "${GREEN}  ImageStreamTags in load-test namespaces: 0${NC}"
            echo "--------------------------------------------------------"

            # Restart operator if requested
            if [ "$RESTART_OPERATOR" == "true" ]; then
                echo ""
                echo -e "${BLUE}Restarting DevWorkspace Operator...${NC}"
                if bash "$(dirname "$0")/restart_dwo_operator.sh"; then
                    echo -e "${GREEN}Operator restart successful${NC}"
                else
                    echo -e "${RED}ERROR: Operator restart failed${NC}"
                    return 1
                fi
                echo "--------------------------------------------------------"
            fi

            return 0
        fi

        # --- Status output ---
        echo "Cleanup attempt #${cleanup_attempt} (elapsed ${elapsed}s):"
        echo "  - DevWorkspaces: $dw_count"
        echo "  - Backup jobs: $backup_jobs_count"
        echo "  - Load-test namespaces: $load_test_ns_count"
        echo "  - Load-test ImageStreamTags: $ist_count"

        echo "Retrying in ${POLL_INTERVAL}s..."
        sleep $POLL_INTERVAL
    done
}


#############################################
# EXTRACT METRICS FROM LOG FILE            #
#############################################
extract_metrics() {
    local LOG_FILE="$1"
    local METRICS_FILE="${LOG_FILE%.log}_metrics.txt"

    if [ ! -f "$LOG_FILE" ]; then
        return
    fi

    {
        echo "=== Backup Test Metrics ==="
        echo ""

        # Extract backup metrics
        if grep -q "backup_jobs_total" "$LOG_FILE"; then
            echo "--- Backup Metrics ---"
            grep "backup_jobs_total\|backup_jobs_succeeded\|backup_jobs_failed\|backup_success_rate\|workspaces_backed_up\|imagestreamtags_backed_up\|imagestreamtags_total\|imagestreamtag_success_rate\|imagestreams_created\|imagestreams_expected" "$LOG_FILE" | tail -30 || true
            echo ""
        fi

        # Extract restore metrics
        if grep -q "restore_workspaces_total" "$LOG_FILE"; then
            echo "--- Restore Metrics ---"
            grep "restore_workspaces_total\|restore_workspaces_succeeded\|restore_success_rate\|restore_duration" "$LOG_FILE" | tail -20 || true
            echo ""
        fi

        # Extract system metrics
        if grep -q "average_operator_cpu\|average_operator_memory" "$LOG_FILE"; then
            echo "--- System Metrics ---"
            grep "average_operator_cpu\|average_operator_memory\|average_etcd" "$LOG_FILE" | tail -20 || true
            echo ""
        fi

        # Extract any errors
        echo "--- Errors ---"
        grep -i "error\|failed\|timeout" "$LOG_FILE" | tail -10 || echo "No errors found"

    } > "$METRICS_FILE"
}

#############################################
# PARSE BACKUP TEST ARGS                   #
#############################################
parse_backup_args() {
    local args="$1"

    # Extract values from args string
    MAX_DEVWORKSPACES=$(echo "$args" | grep -oP '(?<=--max-devworkspaces )\S+' || echo "15")
    BACKUP_MONITOR_DURATION=$(echo "$args" | grep -oP '(?<=--backup-wait-minutes )\S+' || echo "30")
    SEPARATE_NAMESPACE=$(echo "$args" | grep -oP '(?<=--separate-namespaces )\S+' || echo "false")
    DWOC_CONFIG_TYPE=$(echo "$args" | grep -oP '(?<=--dwoc-config-type )\S+' || echo "correct")

    # For registry path and secret, match quoted empty strings or non-whitespace
    # Pattern: --registry-path "" or --registry-path <value>
    # Default to empty for OpenShift internal registry (no hardcoded external registry)
    if echo "$args" | grep -qP '--registry-path\s+""\s'; then
        REGISTRY_PATH=""
    else
        REGISTRY_PATH=$(echo "$args" | grep -oP '(?<=--registry-path )\S+' || echo "")
    fi

    if echo "$args" | grep -qP '--registry-secret\s+""\s'; then
        REGISTRY_SECRET=""
    else
        REGISTRY_SECRET=$(echo "$args" | grep -oP '(?<=--registry-secret )\S+' || echo "")
    fi

    # Extract backup schedule if specified (handle quoted values with space)
    BACKUP_SCHEDULE=$(echo "$args" | grep -oP "(?<=--backup-schedule )['\"]?[^'\"]+['\"]?" || echo "*/10 * * * *")
    BACKUP_SCHEDULE=$(echo "$BACKUP_SCHEDULE" | tr -d '"' | tr -d "'")

    # Remove quotes from registry path and secret if present (only if non-empty)
    REGISTRY_PATH=$(echo "$REGISTRY_PATH" | tr -d '"')
    REGISTRY_SECRET=$(echo "$REGISTRY_SECRET" | tr -d '"')

    # Export for make command
    export MAX_DEVWORKSPACES
    export BACKUP_MONITOR_DURATION
    export SEPARATE_NAMESPACE
    export DWOC_CONFIG_TYPE
    export REGISTRY_PATH
    export REGISTRY_SECRET
    export BACKUP_SCHEDULE
}

#############################################
# RUN BACKUP TEST                          #
#############################################
run_backup_test() {
    local TEST_NAME="$1"
    local ARGS="$2"
    local TEST_LOG="$LOG_DIR/$TEST_NAME.log"

    TEST_COUNT=$((TEST_COUNT + 1))

    echo ""
    echo "========================================================"
    echo -e "${BLUE}Test #$TEST_COUNT: $TEST_NAME${NC}"
    echo "========================================================"
    echo "Started at: $(date)"
    echo "Log file: $TEST_LOG"
    echo ""

    # Parse args to extract backup-specific parameters
    parse_backup_args "$ARGS"

    echo "Test Configuration:"
    echo "  MAX_DEVWORKSPACES: $MAX_DEVWORKSPACES"
    echo "  BACKUP_MONITOR_DURATION: $BACKUP_MONITOR_DURATION"
    echo "  SEPARATE_NAMESPACE: $SEPARATE_NAMESPACE"
    echo "  DWOC_CONFIG_TYPE: $DWOC_CONFIG_TYPE"
    echo "  REGISTRY_PATH: $REGISTRY_PATH"
    echo "  REGISTRY_SECRET: $REGISTRY_SECRET"
    echo "  BACKUP_SCHEDULE: $BACKUP_SCHEDULE"
    echo ""

    # Cleanup before test
    if ! wait_for_cleanup; then
        echo -e "${RED}FAILED: Pre-test cleanup failed for $TEST_NAME${NC}"
        TEST_RESULTS+=("$TEST_NAME|CLEANUP_FAILED|N/A")
        FAILED_COUNT=$((FAILED_COUNT + 1))
        return 1
    fi

    # Run test with timeout
    local test_start=$(date +%s)
    local test_status="RUNNING"

    echo -e "${BLUE}Starting backup test execution...${NC}"

    # Run test in background to allow timeout
    timeout $TEST_TIMEOUT $MAKE_COMMAND > "$TEST_LOG" 2>&1
    local exit_code=$?

    local test_end=$(date +%s)
    local duration=$((test_end - test_start))
    local duration_min=$((duration / 60))

    echo ""
    echo "Test finished at: $(date)"
    echo "Duration: ${duration}s (${duration_min} minutes)"

    # Determine test status
    if [ $exit_code -eq 124 ]; then
        test_status="TIMEOUT"
        echo -e "${RED}TEST TIMEOUT after ${TEST_TIMEOUT}s${NC}"
        FAILED_COUNT=$((FAILED_COUNT + 1))
    elif [ $exit_code -ne 0 ]; then
        test_status="FAILED"
        echo -e "${RED}TEST FAILED with exit code $exit_code${NC}"
        FAILED_COUNT=$((FAILED_COUNT + 1))
    else
        test_status="PASSED"
        echo -e "${GREEN}TEST PASSED${NC}"
        PASSED_COUNT=$((PASSED_COUNT + 1))
    fi

    # Extract metrics from log
    extract_metrics "$TEST_LOG"

    # Store result
    TEST_RESULTS+=("$TEST_NAME|$test_status|${duration_min}m")

    echo "Log saved: $TEST_LOG"
    echo "--------------------------------------------------------"

    # Cleanup after test — ensure ImageStreamTags are gone before the next test
    echo ""
    if [ "$test_status" == "PASSED" ]; then
        echo -e "${BLUE}Running post-test cleanup (waiting for ImageStreamTags to be removed)...${NC}"
    else
        echo -e "${BLUE}Running post-test cleanup...${NC}"
    fi
    if ! wait_for_cleanup; then
        if [ "$test_status" == "PASSED" ]; then
            echo -e "${RED}ERROR: Post-test cleanup failed — ImageStreamTags or load-test namespaces may remain${NC}"
            echo -e "${RED}         Next test may see stale backup artifacts. Fix cluster state before continuing.${NC}"
        else
            echo -e "${YELLOW}WARNING: Post-test cleanup failed, but continuing...${NC}"
        fi
    fi

    return $exit_code
}


#############################################
# GENERATE SUMMARY REPORT                  #
#############################################
generate_summary_report() {
    local SUMMARY_FILE="$RUN_DIR/summary.txt"

    echo ""
    echo "========================================================"
    echo "Generating summary report..."
    echo "========================================================"

    # Generate text summary
    {
        echo "========================================================"
        echo "Backup Load Test Suite Summary"
        echo "========================================================"
        echo "Test Plan: $TEST_PLAN_FILE"
        echo "Started: $(head -1 "$RUN_DIR/test_suite.log" 2>/dev/null || echo 'N/A')"
        echo "Completed: $(date)"
        echo "Output Directory: $RUN_DIR"
        echo ""
        echo "Test Results:"
        echo "  Total: $TEST_COUNT"
        echo "  Passed: $PASSED_COUNT"
        echo "  Failed: $FAILED_COUNT"
        echo ""
        echo "--------------------------------------------------------"
        echo "Individual Test Results:"
        echo "--------------------------------------------------------"
        printf "%-50s %-15s %-10s\n" "Test Name" "Status" "Duration"
        echo "--------------------------------------------------------"

        for result in "${TEST_RESULTS[@]}"; do
            IFS='|' read -r name status duration <<< "$result"
            printf "%-50s %-15s %-10s\n" "$name" "$status" "$duration"
        done

        echo "--------------------------------------------------------"
        echo ""
        echo "Log Files:"
        ls -lh "$LOG_DIR"/*.log 2>/dev/null || echo "No log files found"
        echo ""
        echo "========================================================"

    } | tee "$SUMMARY_FILE"

    echo ""
    echo -e "${GREEN}Summary report saved to: $SUMMARY_FILE${NC}"
}

#############################################
#    LOAD TEST PLAN FROM JSON FILE         #
#############################################

# Load tests from JSON file and populate TEST_PLAN array
load_test_plan_from_json() {
    echo "Loading test plan from: $TEST_PLAN_FILE"

    # Load custom tests (backup tests are all custom tests)
    local custom_count=$(jq '.custom_tests | length' "$TEST_PLAN_FILE" 2>/dev/null || echo "0")

    if [ "$custom_count" -eq 0 ]; then
        echo "ERROR: No custom tests found in test plan"
        echo "Backup test plans should contain custom_tests array"
        exit 1
    fi

    echo "Found $custom_count backup tests in plan"

    for ((i=0; i<custom_count; i++)); do
        local enabled=$(jq -r ".custom_tests[$i].enabled" "$TEST_PLAN_FILE")

        if [ "$enabled" != "true" ]; then
            continue
        fi

        local name=$(jq -r ".custom_tests[$i].name" "$TEST_PLAN_FILE")
        local description=$(jq -r ".custom_tests[$i].description" "$TEST_PLAN_FILE")

        # Add to plan
        TEST_PLAN+=("$name|$description")
    done

    if [ ${#TEST_PLAN[@]} -eq 0 ]; then
        echo "WARNING: No enabled tests found in test plan"
        echo "Please enable at least one test in $TEST_PLAN_FILE"
        exit 1
    fi

    echo "Loaded ${#TEST_PLAN[@]} enabled tests"
}

# Execute tests from JSON file
execute_tests_from_json() {
    local custom_count=$(jq '.custom_tests | length' "$TEST_PLAN_FILE" 2>/dev/null || echo "0")

    for ((i=0; i<custom_count; i++)); do
        local enabled=$(jq -r ".custom_tests[$i].enabled" "$TEST_PLAN_FILE")

        if [ "$enabled" != "true" ]; then
            continue
        fi

        local name=$(jq -r ".custom_tests[$i].name" "$TEST_PLAN_FILE")
        local args=$(jq -r ".custom_tests[$i].args" "$TEST_PLAN_FILE")

        run_backup_test "$name" "$args"
    done
}

# Show test plan before starting
show_test_plan() {
    echo ""
    echo "========================================================"
    echo "BACKUP TEST PLAN"
    echo "========================================================"
    echo "The following backup tests will be executed:"
    echo ""
    printf "%-50s %-60s\n" "Test Name" "Description"
    echo "--------------------------------------------------------"

    for plan in "${TEST_PLAN[@]}"; do
        IFS='|' read -r name description <<< "$plan"
        printf "%-50s %-60s\n" "$name" "$description"
    done

    echo "--------------------------------------------------------"
    echo "Total tests planned: ${#TEST_PLAN[@]}"
    echo ""
}

# Save suite start time
SUITE_START=$(date +%s)
echo "$(date)" > "$RUN_DIR/test_suite.log"

#############################################
#              MAIN EXECUTION               #
#############################################

# Load test plan from JSON
load_test_plan_from_json
show_test_plan

# Provision PVs if enabled (count derived from enabled tests in the plan)
if [ "$PROVISION_PVS" == "true" ]; then
    echo ""
    delete_old_pvs

    echo ""
    max_workspaces=$(get_max_workspaces_from_plan)
    if [ "$max_workspaces" -eq 0 ]; then
        echo -e "${YELLOW}No enabled tests with --max-devworkspaces in plan; skipping PV provisioning${NC}"
    else
        PV_COUNT=$(calculate_pv_provision_count "$max_workspaces")
        echo -e "${BLUE}Pre-allocating PVs from test plan:${NC}"
        echo "  Max workspaces: ${max_workspaces}"
        echo "  Restore headroom (PROVISION_PV_EXTRA): ${PROVISION_PV_EXTRA}"
        echo "  Argument to provision-pvs.sh: ${PV_COUNT} (includes 10% headroom; script adds another 10%)"
        provision_pvs_for_test "$PV_COUNT"
    fi
else
    echo ""
    echo -e "${YELLOW}PV provisioning is disabled (PROVISION_PVS=$PROVISION_PVS)${NC}"
fi

# Wait 10 seconds before starting
echo ""
echo -e "${YELLOW}Tests will begin in 10 seconds... (Press Ctrl+C to cancel)${NC}"
for i in {10..1}; do
    echo -n "$i... "
    sleep 1
done
echo ""
echo ""

# Execute tests from JSON
execute_tests_from_json

# Calculate total suite duration
SUITE_END=$(date +%s)
SUITE_DURATION=$((SUITE_END - SUITE_START))
SUITE_DURATION_MIN=$((SUITE_DURATION / 60))
SUITE_DURATION_HOUR=$((SUITE_DURATION / 3600))

echo ""
echo "========================================================"
echo -e "${GREEN}Backup load test suite COMPLETE${NC}"
echo "========================================================"
echo "Completed at: $(date)"
echo "Total duration: ${SUITE_DURATION}s (${SUITE_DURATION_MIN} minutes / ${SUITE_DURATION_HOUR} hours)"
echo ""

# Generate summary report
generate_summary_report

echo ""
echo "========================================================"
echo "All outputs saved in: $RUN_DIR"
echo "========================================================"
echo "View the summary:"
echo "  cat $RUN_DIR/summary.txt"
echo ""
