#!/bin/bash
# Collect results from PerformanceLabs CRC test
# This tests Step 12g: Copy results to local directory
#
# Usage:
#   export PERFLAB_USER="rokumar"
#   export PERFLAB_HOST="192.168.29.152"
#   ./scripts/test-perflab-workflow-crc-collect-results.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLUSTER_MODE="perflab"
REMOTE_REPO="${REMOTE_REPO:-/home/devworkspace-operator-load-tests}"
EXEC_REPO="${REMOTE_REPO}"

log_info() { echo -e "\nℹ️  $*" >&2; }
log_success() { echo -e "\n✅ $*" >&2; }
log_error() { echo -e "\n❌ $*" >&2; }

# SSH helper (bypasses SSH config proxy)
run_remote() {
  ssh -F /dev/null -o StrictHostKeyChecking=no -o UserKnownHostsFile=~/.ssh/known_hosts "${PERFLAB_USER}@${PERFLAB_HOST}" "$@"
}

echo "=========================================="
echo "COLLECTING PERFORMANCELABS TEST RESULTS"
echo "=========================================="

# Step 10: Check test status
log_info "Step 10: Checking test status..."
if run_remote "tmux ls 2>/dev/null | grep -q 'loadtest'"; then
  log_info "Test is still running in tmux"
  echo ""
  echo "Latest output:"
  run_remote "tmux capture-pane -t loadtest -p | tail -30"
  echo ""
  echo "Wait for test to complete, or monitor with:"
  echo "  ssh -t ${PERFLAB_USER}@${PERFLAB_HOST} 'tmux attach -t loadtest'"
  exit 0
else
  log_success "Test completed (tmux session ended)"
fi

# Step 11: Locate latest run directory
log_info "Step 11: Locating latest run directory on remote..."
OUTPUT_DIR=$(run_remote "ls -td ${EXEC_REPO}/outputs/run_* 2>/dev/null | head -1")

if [[ -z "${OUTPUT_DIR}" ]]; then
  log_error "No run directory found on remote host"
  exit 1
fi

log_success "Latest run: ${OUTPUT_DIR}"
echo ""
echo "Remote directory contents:"
run_remote "ls -lh ${OUTPUT_DIR}"
echo ""
run_remote "ls -lh ${OUTPUT_DIR}/logs/ 2>/dev/null || echo 'No logs directory yet'"

# Step 12d: Parse results on remote
log_info "Step 12d: Parsing controller results on remote host..."
run_remote "cd ${EXEC_REPO} && ./scripts/parse-controller-outputs.sh ${OUTPUT_DIR}"

# Step 12e: Generate report on remote
log_info "Step 12e: Generating reports on remote host..."
CAPACITY_LOG=$(ls -t "${REPO_DIR}"/outputs/cluster_capacity_*.txt 2>/dev/null | head -1 || echo "")

if [[ -n "${CAPACITY_LOG}" ]]; then
  # Copy capacity log to remote for report generation
  log_info "Copying capacity log to remote..."
  scp -F /dev/null -o StrictHostKeyChecking=no "${CAPACITY_LOG}" \
    "${PERFLAB_USER}@${PERFLAB_HOST}:${EXEC_REPO}/outputs/"
  REMOTE_CAPACITY="${EXEC_REPO}/outputs/$(basename ${CAPACITY_LOG})"
  run_remote "cd ${EXEC_REPO} && ./scripts/generate-prerelease-loadtest-report.sh ${OUTPUT_DIR} ${REMOTE_CAPACITY}"
else
  log_info "No local capacity log found, generating report without it..."
  run_remote "cd ${EXEC_REPO} && ./scripts/generate-prerelease-loadtest-report.sh ${OUTPUT_DIR}"
fi

log_success "Reports generated on remote"
echo ""
echo "Remote report files:"
run_remote "ls -lh ${OUTPUT_DIR}/ | grep -E 'csv|md'"

# ==========================================
# STEP 12g: COPY RESULTS TO LOCAL DIRECTORY
# THIS IS THE MAIN TEST!
# ==========================================

log_info "Step 12g: **COPYING RESULTS FROM REMOTE TO LOCAL** (main test)"
echo "=========================================="
echo "TESTING STEP 12g: LOCAL COPY"
echo "=========================================="

# Determine local destination — current working directory where agent launched
LOCAL_DEST_DIR="${PWD}/outputs"
mkdir -p "${LOCAL_DEST_DIR}"

# Download the latest run directory from remote
REMOTE_RUN_DIR="${OUTPUT_DIR}"
LOCAL_RUN_NAME="$(basename ${REMOTE_RUN_DIR})"

echo "Remote dir: ${PERFLAB_USER}@${PERFLAB_HOST}:${REMOTE_RUN_DIR}"
echo "Local dest: ${LOCAL_DEST_DIR}/${LOCAL_RUN_NAME}"
echo "=========================================="

log_info "Downloading run directory via scp..."
scp -F /dev/null -o StrictHostKeyChecking=no -r \
  "${PERFLAB_USER}@${PERFLAB_HOST}:${REMOTE_RUN_DIR}" \
  "${LOCAL_DEST_DIR}/"

# Verify copy succeeded
if [[ -d "${LOCAL_DEST_DIR}/${LOCAL_RUN_NAME}" ]]; then
  log_success "Results copied successfully to: ${LOCAL_DEST_DIR}/${LOCAL_RUN_NAME}"
  echo ""
  echo "Local files:"
  ls -lh "${LOCAL_DEST_DIR}/${LOCAL_RUN_NAME}"
  echo ""
  if [[ -f "${LOCAL_DEST_DIR}/${LOCAL_RUN_NAME}/controller_load_test_results.csv" ]]; then
    echo "CSV: ${LOCAL_DEST_DIR}/${LOCAL_RUN_NAME}/controller_load_test_results.csv"
  fi
  if [[ -f "${LOCAL_DEST_DIR}/${LOCAL_RUN_NAME}/loadtest_report.md" ]]; then
    echo "Report: ${LOCAL_DEST_DIR}/${LOCAL_RUN_NAME}/loadtest_report.md"
  fi
else
  log_error "Failed to copy results locally"
  exit 1
fi

# Also copy pre-test snapshots
log_info "Copying pre-test snapshots..."
scp -F /dev/null -o StrictHostKeyChecking=no \
  "${PERFLAB_USER}@${PERFLAB_HOST}:${EXEC_REPO}/outputs/cluster_capacity_*.txt" \
  "${LOCAL_DEST_DIR}/" 2>/dev/null || true
scp -F /dev/null -o StrictHostKeyChecking=no \
  "${PERFLAB_USER}@${PERFLAB_HOST}:${EXEC_REPO}/outputs/dwo_version_*.txt" \
  "${LOCAL_DEST_DIR}/" 2>/dev/null || true
scp -F /dev/null -o StrictHostKeyChecking=no \
  "${PERFLAB_USER}@${PERFLAB_HOST}:${EXEC_REPO}/outputs/dwoc_config_*.txt" \
  "${LOCAL_DEST_DIR}/" 2>/dev/null || true

log_success "All snapshots copied"

# ==========================================
# FINAL RESULTS (LOCAL PATHS)
# ==========================================

echo ""
echo "=========================================="
echo "FINAL RESULTS (LOCAL COPIES) ✅"
echo "=========================================="
echo "Run directory: ${LOCAL_DEST_DIR}/${LOCAL_RUN_NAME}"
echo ""

if [[ -f "${LOCAL_DEST_DIR}/${LOCAL_RUN_NAME}/controller_load_test_results.csv" ]]; then
  echo "CSV (for Google Sheets):"
  echo "  ${LOCAL_DEST_DIR}/${LOCAL_RUN_NAME}/controller_load_test_results.csv"
  echo ""
fi

if [[ -f "${LOCAL_DEST_DIR}/${LOCAL_RUN_NAME}/loadtest_report.md" ]]; then
  echo "Markdown Report (for Google Docs):"
  echo "  ${LOCAL_DEST_DIR}/${LOCAL_RUN_NAME}/loadtest_report.md"
  echo ""
fi

echo "Pre-test snapshots:"
ls -1 "${LOCAL_DEST_DIR}"/cluster_capacity_*.txt 2>/dev/null | sed 's/^/  /' || echo "  (not found)"
ls -1 "${LOCAL_DEST_DIR}"/dwo_version_*.txt 2>/dev/null | sed 's/^/  /' || echo "  (not found)"
ls -1 "${LOCAL_DEST_DIR}"/dwoc_config_*.txt 2>/dev/null | sed 's/^/  /' || echo "  (not found)"
echo "=========================================="

# Display CSV if exists
if [[ -f "${LOCAL_DEST_DIR}/${LOCAL_RUN_NAME}/controller_load_test_results.csv" ]]; then
  echo ""
  echo "CSV Results Preview:"
  cat "${LOCAL_DEST_DIR}/${LOCAL_RUN_NAME}/controller_load_test_results.csv"
  echo ""
fi

# Display report summary if exists
if [[ -f "${LOCAL_DEST_DIR}/${LOCAL_RUN_NAME}/loadtest_report.md" ]]; then
  echo ""
  echo "Report Preview (first 50 lines):"
  head -50 "${LOCAL_DEST_DIR}/${LOCAL_RUN_NAME}/loadtest_report.md"
  echo ""
fi

# Cleanup remote tmux session
log_info "Cleaning up remote tmux session..."
run_remote "tmux kill-session -t loadtest 2>/dev/null || true"
log_success "Cleanup complete"

echo ""
echo "=========================================="
echo "✅ PERFORMANCELABS WORKFLOW TEST COMPLETE"
echo "=========================================="
echo "All results are now LOCAL at:"
echo "  ${LOCAL_DEST_DIR}/${LOCAL_RUN_NAME}"
echo ""
echo "You can now:"
echo "  1. Open CSV in Excel/Numbers"
echo "  2. Import CSV to Google Sheets"
echo "  3. View markdown report"
echo "  4. Share results without SSH access"
echo "=========================================="
