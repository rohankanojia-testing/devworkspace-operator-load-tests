#!/bin/bash

# ============================================================================
# DevWorkspace Operator Restart Script
# ============================================================================
#
# This script restarts the DevWorkspace Operator (DWO) deployments without
# reinstalling the subscription. This is useful for getting a fresh operator
# state between tests without changing the operator version.
#
# USAGE:
#   ./scripts/restart_dwo_operator.sh
#
# ENVIRONMENT VARIABLES:
#   OPERATOR_NAMESPACE      - Namespace for operator (default: openshift-operators)
#   POD_READY_TIMEOUT       - Timeout for pod ready in seconds (default: 90)
#
# ============================================================================

set -e
set -o pipefail

# --- Configuration ---
OPERATOR_NAMESPACE="${OPERATOR_NAMESPACE:-openshift-operators}"
POD_READY_TIMEOUT="${POD_READY_TIMEOUT:-90}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- Helper Functions ---
log_info() {
    echo -e "${BLUE}INFO:${NC} $1"
}

log_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

log_error() {
    echo -e "${RED}❌ $1${NC}"
}

# --- Main Script ---
echo "========================================================"
echo "DevWorkspace Operator Restart"
echo "========================================================"
echo "Started at: $(date)"
echo "Operator Namespace: $OPERATOR_NAMESPACE"
echo "--------------------------------------------------------"
echo ""

# Step 1: Delete devworkspace-controller-manager pod
log_info "Deleting devworkspace-controller-manager pod..."
if kubectl delete pod -n "$OPERATOR_NAMESPACE" -l app.kubernetes.io/name=devworkspace-controller --ignore-not-found=true; then
    log_success "devworkspace-controller-manager pod deleted"
else
    log_error "Failed to delete devworkspace-controller-manager pod"
    exit 1
fi

echo ""

# Step 2: Delete devworkspace-webhook-server pod
log_info "Deleting devworkspace-webhook-server pod..."
if kubectl delete pod -n "$OPERATOR_NAMESPACE" -l app.kubernetes.io/name=devworkspace-webhook-server --ignore-not-found=true; then
    log_success "devworkspace-webhook-server pod deleted"
else
    log_error "Failed to delete devworkspace-webhook-server pod"
    exit 1
fi

echo ""

# Step 3: Wait for pods to be ready
log_info "Waiting for pods to be ready..."
echo ""

log_info "Waiting for devworkspace-controller-manager pod to be ready..."
if kubectl wait --for=condition=ready pod -n "$OPERATOR_NAMESPACE" -l app.kubernetes.io/name=devworkspace-controller --timeout="${POD_READY_TIMEOUT}s"; then
    log_success "devworkspace-controller-manager pod is ready"
else
    log_error "devworkspace-controller-manager pod failed to become ready"
    exit 1
fi

echo ""
log_info "Waiting for devworkspace-webhook-server pod to be ready..."
if kubectl wait --for=condition=ready pod -n "$OPERATOR_NAMESPACE" -l app.kubernetes.io/name=devworkspace-webhook-server --timeout="${POD_READY_TIMEOUT}s"; then
    log_success "devworkspace-webhook-server pod is ready"
else
    log_error "devworkspace-webhook-server pod failed to become ready"
    exit 1
fi

log_success "DWO controllers restarted successfully"
echo ""

# Step 4: Show pod status
log_info "Current pod status:"
kubectl get pods -n "$OPERATOR_NAMESPACE" -l app.kubernetes.io/part-of=devworkspace-operator

echo ""
echo "========================================================"
log_success "DevWorkspace Operator restart complete!"
echo "========================================================"
echo "Completed at: $(date)"
echo ""
