#!/usr/bin/env bash
set -euo pipefail

# Generate CRC QE AWS pre-release load test report (markdown + CSV) after both runs complete.
#
# Usage:
#   ./scripts/generate-prerelease-loadtest-report.sh outputs/run_20260520_031456
#   ./scripts/generate-prerelease-loadtest-report.sh outputs/run_20260520_031456 outputs/cluster_capacity_20260520_031000.txt
#
# Outputs (inside the run directory):
#   controller_load_test_results.csv  — metrics for single + separate namespace runs
#   loadtest_report.md                — detailed markdown report

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

RUN_DIR="${1:-}"
CAPACITY_LOG="${2:-}"

if [[ -z "${RUN_DIR}" ]]; then
  echo "Usage: $0 <outputs/run_YYYYMMDD_HHMMSS> [cluster_capacity_log.txt]" >&2
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

SINGLE_TEST="1500_single_ns_40m"
SEPARATE_TEST="1500_separate_ns_40m"

SINGLE_CMD='make test_load ARGS=" --mode binary --create-automount-resources true --max-devworkspaces 1500 --delete-devworkspace-after-ready false --separate-namespaces false --test-duration-minutes 40"'
SEPARATE_CMD='make test_load ARGS=" --mode binary  --create-automount-resources true --max-devworkspaces 1500 --delete-devworkspace-after-ready false --separate-namespaces true --test-duration-minutes 40"'

CSV_OUT="${RUN_DIR}/controller_load_test_results.csv"
REPORT_OUT="${RUN_DIR}/loadtest_report.md"

log_info() { echo "ℹ️  $*" >&2; }
log_success() { echo "✅ $*" >&2; }

# --- Generate CSV from run logs ---
log_info "Parsing controller logs → ${CSV_OUT}"
(
  cd "${REPO_ROOT}"
  rm -f controller_load_test_results.csv
  "${SCRIPT_DIR}/parse-controller-outputs.sh" "${RUN_DIR}" >/dev/null
  cp controller_load_test_results.csv "${CSV_OUT}"
)

format_failures() {
  local test_name="$1"
  local failure_csv="${LOG_DIR}/${test_name}_failure_report.csv"

  if [[ -f "${failure_csv}" ]]; then
    # Only include real DevWorkspace failure rows — never raw k6 metrics/check lines
    local rows
    rows=$(grep -E '^"?load-test-' "${failure_csv}" 2>/dev/null || true)
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

# --- Write markdown report ---
cat > "${REPORT_OUT}" <<EOF
# Load Test Report

Run directory: \`${RUN_DIR}\`

## Cluster Info

\`\`\`
${CLUSTER_INFO}
\`\`\`

Edit DevWorkspaceOperatorConfig in openshift-operators to increase progressTimeout to 3600s

\`\`\`
progressTimeout: 3600s
\`\`\`

Increase each node capacity from 250 to 500 pods

## Test Results

### Single Namespace

1500

\`\`\`bash
${SINGLE_CMD}
\`\`\`

#### Failures

$(format_failures "${SINGLE_TEST}")

### Separate Namespace

1500

\`\`\`bash
${SEPARATE_CMD}
\`\`\`

#### Failures

$(format_failures "${SEPARATE_TEST}")

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
echo "REPORT FILES (share after both tests finish)"
echo "=========================================="
echo "CSV:      ${CSV_OUT}"
echo "Markdown: ${REPORT_OUT}"
echo "=========================================="
