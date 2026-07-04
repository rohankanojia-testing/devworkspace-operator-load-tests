#!/usr/bin/env bash
set -euo pipefail

# Generate backup load test report (markdown + CSV) after all runs complete.
#
# Usage:
#   ./scripts/generate-backup-loadtest-report.sh outputs/backup_run_20260704_120000
#   ./scripts/generate-backup-loadtest-report.sh outputs/backup_run_20260704_120000 outputs/cluster_capacity_20260704_120000.txt
#
# Outputs (inside the run directory):
#   backup_load_test_results.csv — parsed metrics for all workspace counts
#   loadtest_report.md           — detailed markdown report

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

RUN_DIR="${1:-}"
CAPACITY_LOG="${2:-}"

if [[ -z "${RUN_DIR}" ]]; then
  echo "Usage: $0 <outputs/backup_run_YYYYMMDD_HHMMSS> [cluster_capacity_log.txt]" >&2
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

CSV_OUT="${RUN_DIR}/backup_load_test_results.csv"
REPORT_OUT="${RUN_DIR}/loadtest_report.md"

log_info() { echo "ℹ️  $*" >&2; }
log_success() { echo "✅ $*" >&2; }

# --- Generate CSV from run logs ---
log_info "Parsing backup logs → ${CSV_OUT}"
(
  cd "${REPO_ROOT}"
  rm -f backup_load_test_results.csv
  "${SCRIPT_DIR}/parse-backup-outputs.sh" "${RUN_DIR}" >/dev/null
  cp backup_load_test_results.csv "${CSV_OUT}"
)

# Function to check if test had actual failures
has_failures() {
  local log_file="$1"
  # Check for devworkspace_ready_failed metric
  local line=$(grep "devworkspace_ready_failed" "$log_file" | grep -v "^time=" | sed 's/\x1b\[[0-9;]*m//g')
  local failed_count=$(echo "$line" | sed 's/.*devworkspace_ready_failed[.:]*//g' | awk '{print $1}')

  if [[ "$failed_count" =~ ^[0-9]+$ ]] && [[ "$failed_count" -gt 0 ]]; then
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

  # Extract k6 summary metrics (the final summary table)
  grep -A35 "✓ DevWorkspace created" "$log_file" 2>/dev/null | head -36 | sed 's/\x1b\[[0-9;]*m//g' || echo "Metrics not found"
}

format_failures() {
  local test_name="$1"
  local failure_csv="${LOG_DIR}/${test_name}_failure_report.csv"

  # Check if test actually had failures by reading the log
  local log_file="${LOG_DIR}/${test_name}.log"
  if ! has_failures "$log_file"; then
    echo "None"
    return
  fi

  if [[ -f "${failure_csv}" ]]; then
    # Only include real DevWorkspace failure rows
    local rows
    rows=$(grep -E '^"?load(test)?-' "${failure_csv}" 2>/dev/null || true)
    if [[ -n "${rows}" ]]; then
      echo '```csv'
      echo "${rows}"
      echo '```'
      return
    fi
  fi

  echo "None"
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

# --- Find all backup test logs and generate report sections ---
TEST_LOGS=($(ls "${LOG_DIR}"/*.log 2>/dev/null | sort -V || true))

if [[ ${#TEST_LOGS[@]} -eq 0 ]]; then
  echo "Error: No backup test logs found in ${LOG_DIR}" >&2
  exit 1
fi

# --- Write markdown report ---
cat > "${REPORT_OUT}" <<EOF
# Backup Load Test Report

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

Edit DevWorkspaceOperatorConfig in openshift-operators to use OpenShift Internal registry:

\`\`\`yaml
progressTimeout: 3600s
dwoc-config-type: openshift-internal
\`\`\`

**Registry:** OpenShift Internal (\`image-registry.openshift-image-registry.svc:5000\`)

## Test Results

EOF

# Generate report sections for each test
for log_file in "${TEST_LOGS[@]}"; do
  log_basename=$(basename "$log_file" .log)

  # Extract workspace count from filename (e.g., "backup_30_separate_ns_internal" -> "30")
  workspace_count=$(echo "$log_basename" | grep -oE '[0-9]+' | head -1 || echo "unknown")

  # Detect namespace mode from filename
  namespace_mode="separate namespaces"
  if echo "$log_basename" | grep -q "single"; then
    namespace_mode="single namespace"
  fi

  cat >> "${REPORT_OUT}" <<SECTION_EOF

### ${workspace_count} Workspaces (${namespace_mode})

\`\`\`bash
make test_load ARGS="--mode binary --max-vus ${workspace_count} --max-devworkspaces ${workspace_count} --separate-namespaces $(echo "$namespace_mode" | grep -q "separate" && echo "true" || echo "false") --run-backup-test-hook true --dwoc-config-type openshift-internal"
\`\`\`

#### k6 Output

\`\`\`
$(format_k6_output "$log_file")
\`\`\`

#### Failures

$(format_failures "$log_basename")

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
