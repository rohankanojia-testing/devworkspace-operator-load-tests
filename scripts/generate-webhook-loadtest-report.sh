#!/usr/bin/env bash
set -euo pipefail

# Generate webhook load test report (markdown + CSV) after all runs complete.
#
# Usage:
#   ./scripts/generate-webhook-loadtest-report.sh outputs/webhook_run_20260704_120000
#   ./scripts/generate-webhook-loadtest-report.sh outputs/webhook_run_20260704_120000 outputs/cluster_capacity_20260704_120000.txt
#
# Outputs (inside the run directory):
#   webhook_load_test_results.csv — parsed metrics for all user counts
#   loadtest_report.md            — detailed markdown report

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

RUN_DIR="${1:-}"
CAPACITY_LOG="${2:-}"

if [[ -z "${RUN_DIR}" ]]; then
  echo "Usage: $0 <outputs/webhook_run_YYYYMMDD_HHMMSS> [cluster_capacity_log.txt]" >&2
  exit 1
fi

if [[ ! -d "${RUN_DIR}" ]]; then
  echo "Error: Run directory not found: ${RUN_DIR}" >&2
  exit 1
fi

LOG_DIR="${RUN_DIR}/logs"
if [[ ! -d "${LOG_DIR}" ]]; then
  echo "Error: Logs directory not found: ${LOG_DIR}" >&2
  exit 1
fi

CSV_OUT="${RUN_DIR}/webhook_load_test_results.csv"
REPORT_OUT="${RUN_DIR}/loadtest_report.md"

log_info() { echo "ℹ️  $*" >&2; }
log_success() { echo "✅ $*" >&2; }

# --- Generate CSV from run logs ---
log_info "Parsing webhook logs → ${CSV_OUT}"
(
  cd "${REPO_ROOT}"
  rm -f webhook_load_test_results.csv
  "${SCRIPT_DIR}/parse-webhook-outputs.sh" "${RUN_DIR}" >/dev/null
  cp webhook_load_test_results.csv "${CSV_OUT}"
)

# Function to check if test had actual failures
has_failures() {
  local log_file="$1"
  # Webhook tests report failures differently - check for exec_failed or validation failures
  local exec_failed=$(grep "exec_failed" "$log_file" | grep -v "^time=" | sed 's/\x1b\[[0-9;]*m//g' | awk '{print $2}' || echo "0")

  if [[ "$exec_failed" =~ ^[0-9]+$ ]] && [[ "$exec_failed" -gt 0 ]]; then
    return 0  # Has failures
  else
    return 1  # No failures
  fi
}

format_k6_output() {
  local log_file="$1"

  if [[ ! -f "$log_file" ]]; then
    echo "Log file not found"
    return
  fi

  # Extract the full k6 metrics summary from the log
  # Look for the section starting with "✓ exec forbidden" and ending with "load_test ✓"
  local start_line=$(grep -n "exec forbidden for foreign workspace\|exec allowed for own workspace" "$log_file" | head -1 | cut -d: -f1)

  if [[ -z "$start_line" ]]; then
    # Test might have failed before k6 output - check for error
    # Extract error message and a few lines of context, stop before cleanup emoji
    local error_output=$(grep -B3 "Error:" "$log_file" | head -10 | sed 's/\x1b\[[0-9;]*m//g')
    if [[ -n "$error_output" ]]; then
      echo "$error_output"
    else
      echo "No k6 output found"
    fi
    return
  fi

  # Find the end line (load_test ✓ line) - this is the last line we want
  local end_line=$(sed -n "${start_line},\$p" "$log_file" | grep -n "load_test ✓" | head -1 | cut -d: -f1)

  if [[ -n "$end_line" ]]; then
    # Extract from start to end, then stop (don't include cleanup lines)
    sed -n "${start_line},$((start_line + end_line - 1))p" "$log_file" | sed 's/\x1b\[[0-9;]*m//g'
  else
    # Fallback: extract about 25 lines
    sed -n "${start_line},$((start_line + 25))p" "$log_file" | sed 's/\x1b\[[0-9;]*m//g'
  fi
}

# --- Cluster capacity section ---
CLUSTER_INFO="(cluster capacity log not provided — re-run with capacity log path as 2nd argument)"
if [[ -n "${CAPACITY_LOG}" && -f "${CAPACITY_LOG}" ]]; then
  CLUSTER_INFO=$(grep -v "^===" "${CAPACITY_LOG}" | sed '/^$/d' | tail -n +1 || cat "${CAPACITY_LOG}")
elif compgen -G "${REPO_ROOT}/outputs/cluster_capacity_*.txt" >/dev/null 2>&1; then
  CAPACITY_LOG=$(ls -t "${REPO_ROOT}"/outputs/cluster_capacity_*.txt 2>/dev/null | head -1)
  CLUSTER_INFO=$(grep -v "^===" "${CAPACITY_LOG}" | sed '/^$/d' || cat "${CAPACITY_LOG}")
  log_info "Using latest capacity log: ${CAPACITY_LOG}"
fi

# Get DWO version if available
DWO_VERSION="(version not captured)"
if compgen -G "${REPO_ROOT}/outputs/dwo_version_*.txt" >/dev/null 2>&1; then
  DWO_VERSION_FILE=$(ls -t "${REPO_ROOT}"/outputs/dwo_version_*.txt 2>/dev/null | head -1)
  DWO_VERSION=$(cat "${DWO_VERSION_FILE}" 2>/dev/null || echo "(version file empty)")
fi

# --- Find all webhook test logs and generate report sections ---
# Detect test scales from log filenames (e.g., 50_users.log, 100_users.log)
TEST_LOGS=($(ls "${LOG_DIR}"/*.log 2>/dev/null | sort -V || true))

if [[ ${#TEST_LOGS[@]} -eq 0 ]]; then
  echo "Error: No webhook test logs found in ${LOG_DIR}" >&2
  exit 1
fi

# --- Write markdown report ---
cat > "${REPORT_OUT}" <<EOF
# Webhook Load Test Report

Run directory: \`${RUN_DIR}\`

## Cluster Info

\`\`\`
${CLUSTER_INFO}
\`\`\`

## Operator Version

\`\`\`
${DWO_VERSION}
\`\`\`

## Configuration

Edit DevWorkspaceOperatorConfig in openshift-operators to increase progressTimeout to 3600s

\`\`\`
progressTimeout: 3600s
\`\`\`

## Test Results

EOF

# Generate report sections for each test
for log_file in "${TEST_LOGS[@]}"; do
  log_basename=$(basename "$log_file" .log)

  # Extract user count from filename (e.g., "50_users" -> "50")
  user_count=$(echo "$log_basename" | grep -oE '[0-9]+' | head -1 || echo "unknown")

  cat >> "${REPORT_OUT}" <<SECTION_EOF

### ${user_count} Concurrent Users

\`\`\`bash
make test_webhook_load ARGS="--number-of-users ${user_count}"
\`\`\`

#### k6 Output

\`\`\`
$(format_k6_output "$log_file")
\`\`\`

#### Failures

$(has_failures "$log_file" && echo "See k6 output above for exec_failed metrics" || echo "None")

SECTION_EOF
done

# Add CSV results section
cat >> "${REPORT_OUT}" <<EOF

## CSV Results

File: \`${CSV_OUT}\`

\`\`\`csv
$(cat "${CSV_OUT}")
\`\`\`
EOF

log_success "Markdown report: ${REPORT_OUT}"
log_success "CSV results:     ${CSV_OUT}"

echo ""
echo "=========================================="
echo "REPORT FILES"
echo "=========================================="
echo "CSV:      ${CSV_OUT}"
echo "Markdown: ${REPORT_OUT}"
echo "=========================================="
