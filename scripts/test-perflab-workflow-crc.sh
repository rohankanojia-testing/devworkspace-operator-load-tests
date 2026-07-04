#!/bin/bash
# Test PerformanceLabs workflow with local CRC cluster (50 workspaces)
#
# Usage:
#   export PERFLAB_USER="rokumar"
#   export PERFLAB_HOST="192.168.29.152"
#   ./scripts/test-perflab-workflow-crc.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLUSTER_MODE="perflab"
TEST_TYPE="controller"
TEST_PLAN="${REPO_DIR}/test-plans/crc-50-test-plan.json"
REMOTE_REPO="${REMOTE_REPO:-/home/devworkspace-operator-load-tests}"

log_info() { echo -e "\nℹ️  $*" >&2; }
log_success() { echo -e "\n✅ $*" >&2; }
log_error() { echo -e "\n❌ $*" >&2; }

# SSH helper (bypasses SSH config proxy)
run_remote() {
  ssh -F /dev/null -o StrictHostKeyChecking=no -o UserKnownHostsFile=~/.ssh/known_hosts "${PERFLAB_USER}@${PERFLAB_HOST}" "$@"
}

echo "=========================================="
echo "PERFORMANCELABS WORKFLOW TEST"
echo "=========================================="
echo "Mode: ${CLUSTER_MODE}"
echo "Test: ${TEST_TYPE}"
echo "Plan: ${TEST_PLAN}"
echo "Remote: ${PERFLAB_USER}@${PERFLAB_HOST}:${REMOTE_REPO}"
echo "=========================================="

# Step 0: Verify repo
log_info "Step 0: Verifying local repo..."
if [[ ! -f "${REPO_DIR}/scripts/run_all_loadtests.sh" ]]; then
  log_error "Not in load-testing repo"
  exit 1
fi
log_success "Local repo verified: ${REPO_DIR}"

# Step 1: Verify SSH access
log_info "Step 1: Verifying SSH access to CRC..."
if ! run_remote "echo 'SSH OK' && oc whoami" >/dev/null 2>&1; then
  log_error "Cannot SSH to ${PERFLAB_HOST} or oc not configured"
  echo "Fix with:"
  echo "  ssh ${PERFLAB_USER}@${PERFLAB_HOST}"
  echo "  oc login ..."
  exit 1
fi
SSH_USER=$(run_remote "oc whoami")
log_success "SSH OK, logged into cluster as: ${SSH_USER}"

# Step 2: Check cluster capacity
log_info "Step 2: Checking cluster capacity..."
mkdir -p "${REPO_DIR}/outputs"
CAPACITY_LOG_FILE="${REPO_DIR}/outputs/cluster_capacity_$(date +%Y%m%d_%H%M%S).txt"

run_remote "kubectl get nodes -o custom-columns=NAME:.metadata.name,CPU:.status.allocatable.cpu,MEMORY:.status.allocatable.memory" \
  | tee "${CAPACITY_LOG_FILE}"

NODE_COUNT=$(run_remote "kubectl get nodes --no-headers | wc -l" | tr -d ' ')
log_success "Cluster has ${NODE_COUNT} node(s), logged to: ${CAPACITY_LOG_FILE}"

# Step 3: Verify/clone remote repo
log_info "Step 3: Checking remote repository at ${REMOTE_REPO}..."
if ! run_remote "test -f ${REMOTE_REPO}/scripts/run_all_loadtests.sh" 2>/dev/null; then
  log_info "Repository not found on remote, cloning..."
  run_remote "mkdir -p $(dirname ${REMOTE_REPO}) && cd $(dirname ${REMOTE_REPO}) && \
    git clone --depth 1 https://github.com/devfile/devworkspace-operator-load-tests.git $(basename ${REMOTE_REPO}) || \
    git clone --depth 1 git@github.com:devfile/devworkspace-operator-load-tests.git $(basename ${REMOTE_REPO})"
  log_success "Repository cloned to: ${REMOTE_REPO}"
else
  log_success "Repository found at: ${REMOTE_REPO}"
fi

# Step 4: Check DWO version
log_info "Step 4: Checking DevWorkspace Operator version..."
DWO_VERSION_LOG_FILE="${REPO_DIR}/outputs/dwo_version_$(date +%Y%m%d_%H%M%S).txt"

{
  echo "=== DevWorkspace Operator CSV ==="
  run_remote "kubectl get csv -n openshift-operators -o custom-columns=NAME:.metadata.name,VERSION:.spec.version,PHASE:.status.phase 2>/dev/null | grep -E 'NAME|devworkspace-operator' || echo 'No DWO CSV found'"
  echo ""
  echo "=== DWO Deployments ==="
  run_remote "kubectl get deployment -n openshift-operators devworkspace-controller-manager devworkspace-webhook-server -o custom-columns=NAME:.metadata.name,READY:.status.readyReplicas/.spec.replicas 2>/dev/null || echo 'DWO deployments not found'"
} | tee "${DWO_VERSION_LOG_FILE}"

DWO_VERSION=$(run_remote "kubectl get csv -n openshift-operators -o jsonpath='{.items[?(@.spec.displayName==\"DevWorkspace Operator\")].spec.version}' 2>/dev/null" | tr -d '[:space:]')
log_success "DWO version: ${DWO_VERSION:-NOT FOUND}, logged to: ${DWO_VERSION_LOG_FILE}"

if [[ -z "${DWO_VERSION}" ]]; then
  log_error "DevWorkspace Operator not installed. Install it first:"
  echo "  oc apply -f https://raw.githubusercontent.com/devfile/devworkspace-operator/main/deploy/deployment/openshift/objects/devworkspace-operator-catalog.yaml"
  echo "  # Then create subscription via OperatorHub"
  exit 1
fi

# Step 5: Patch DevWorkspaceOperatorConfig
log_info "Step 5: Patching DevWorkspaceOperatorConfig..."
DWOC_LOG_FILE="${REPO_DIR}/outputs/dwoc_config_$(date +%Y%m%d_%H%M%S).txt"

{
  echo "=== BEFORE PATCH ==="
  run_remote "kubectl get devworkspaceoperatorconfig devworkspace-operator-config -n openshift-operators -o yaml 2>/dev/null || echo 'DevWorkspaceOperatorConfig not found'"
} | tee "${DWOC_LOG_FILE}"

if run_remote "kubectl get devworkspaceoperatorconfig devworkspace-operator-config -n openshift-operators" >/dev/null 2>&1; then
  run_remote "kubectl patch devworkspaceoperatorconfig devworkspace-operator-config -n openshift-operators --type merge --patch '{\"config\":{\"workspace\":{\"imagePullPolicy\":\"IfNotPresent\",\"progressTimeout\":\"3600s\"}}}'"
else
  run_remote "kubectl apply -f - <<'DWOC_EOF'
apiVersion: controller.devfile.io/v1alpha1
kind: DevWorkspaceOperatorConfig
metadata:
  name: devworkspace-operator-config
  namespace: openshift-operators
config:
  workspace:
    imagePullPolicy: IfNotPresent
    progressTimeout: 3600s
DWOC_EOF"
fi

{
  echo ""
  echo "=== AFTER PATCH ==="
  run_remote "kubectl get devworkspaceoperatorconfig devworkspace-operator-config -n openshift-operators -o yaml"
} | tee -a "${DWOC_LOG_FILE}"

log_success "DevWorkspaceOperatorConfig patched, logged to: ${DWOC_LOG_FILE}"

# Step 8: Check for existing tmux session
log_info "Step 8: Checking for existing tmux session..."
if run_remote "tmux ls 2>/dev/null | grep -q 'loadtest'"; then
  log_error "Existing tmux session 'loadtest' found!"
  echo "Attach with: ssh -t ${PERFLAB_USER}@${PERFLAB_HOST} 'tmux attach -t loadtest'"
  echo "Kill with:   ssh ${PERFLAB_USER}@${PERFLAB_HOST} 'tmux kill-session -t loadtest'"
  exit 1
fi
log_success "No existing tmux session"

# Step 9: Copy test plan to remote and start test
log_info "Step 9: Copying test plan to remote and starting test in tmux..."

# Copy test plan to remote
scp -F /dev/null -o StrictHostKeyChecking=no "${TEST_PLAN}" "${PERFLAB_USER}@${PERFLAB_HOST}:${REMOTE_REPO}/test-plans/"

# Start test in remote tmux
run_remote "tmux new-session -d -s loadtest 'cd ${REMOTE_REPO} && ./scripts/run_all_loadtests.sh test-plans/$(basename ${TEST_PLAN}); exec bash'"

log_success "Test started in remote tmux session 'loadtest'"
echo ""
echo "Monitor with:"
echo "  ssh -t ${PERFLAB_USER}@${PERFLAB_HOST} 'tmux attach -t loadtest'"
echo "  # Detach with Ctrl+b d"
echo ""
echo "Or capture output without attaching:"
echo "  ssh ${PERFLAB_USER}@${PERFLAB_HOST} 'tmux capture-pane -t loadtest -p | tail -30'"
echo ""
echo "=========================================="
echo "TEST RUNNING - MONITOR REMOTELY"
echo "=========================================="
echo "Expected duration: ~20 minutes (50 workspaces)"
echo ""
echo "When complete, run:"
echo "  ${REPO_DIR}/scripts/test-perflab-workflow-crc-collect-results.sh"
echo "=========================================="
