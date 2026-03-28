#!/usr/bin/env bash
set -euo pipefail

# ----------------
# Defaults (env → CLI override)
# ----------------
KUBECTL="${KUBECTL:-}"

N_USERS="${N_USERS:-10}"
LOAD_TEST_NAMESPACE="${LOAD_TEST_NAMESPACE:-dw-webhook-loadtest}"
WEBHOOK_NAMESPACE="${WEBHOOK_NAMESPACE:-openshift-operators}"
DEV_WORKSPACE_READY_TIMEOUT_IN_SECONDS="${DEV_WORKSPACE_READY_TIMEOUT_IN_SECONDS:-7200}"
DEVWORKSPACE_LINK="${DEVWORKSPACE_LINK-https://gist.githubusercontent.com/rohanKanojia/a68f7079c6045ea245a2e512dcc2b062/raw/cb2f0d7dce0badd9c8673d39b1b88de2965c3246/dw-restricted-access-annotation.json}"

DW_API_GROUP="workspace.devfile.io"
DW_RESOURCE="devworkspaces"
CLUSTER_ROLE_NAME="k6-devworkspace-webhook-server-role"
TOKEN_TTL="6h"
TOKENS_FILE=""
K6_SCRIPT="${K6_SCRIPT:-test-devworkspace-webhook-server-load/devworkspace_webhook_loadtest.js}"

# ----------------
# Helpers
# ----------------
log() {
  echo "$@" >&2
}

# Auto-detect CLI if KUBECTL is not explicitly set
detect_cli() {
  if [[ -z "$KUBECTL" ]]; then
    if command -v oc &> /dev/null; then
      KUBECTL="oc"
    elif command -v kubectl &> /dev/null; then
      KUBECTL="kubectl"
    else
      log "❌ Error: Neither 'oc' nor 'kubectl' found in PATH."
      exit 1
    fi
  fi
  log "🛠️  Using CLI: $KUBECTL"
}

print_help() {
  cat <<EOF
Usage: [KUBECTL=oc|kubectl] $0 [options]

Options:
  --number-of-users <int>                         Number of service accounts / users (default: ${N_USERS})
  --load-test-namespace <string>                  Namespace used for load testing (default: ${LOAD_TEST_NAMESPACE})
  --webhook-server-namespace <string>             Namespace where webhook server runs (default: ${WEBHOOK_NAMESPACE})
  --dev-workspace-ready-timeout-in-seconds <int>  Timeout for DevWorkspace readiness (default: ${DEV_WORKSPACE_READY_TIMEOUT_IN_SECONDS})
  -h, --help                                      Show this help message

Environment Variables:
  KUBECTL       The CLI tool to use (oc or kubectl). Auto-detected if not set.
EOF
}

parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --number-of-users)
        N_USERS="$2"; shift 2;;
      --load-test-namespace)
        LOAD_TEST_NAMESPACE="$2"; shift 2;;
      --webhook-server-namespace)
        WEBHOOK_NAMESPACE="$2"; shift 2;;
      --dev-workspace-ready-timeout-in-seconds)
        DEV_WORKSPACE_READY_TIMEOUT_IN_SECONDS="$2"; shift 2;;
      --devworkspace-link)
        DEVWORKSPACE_LINK="$2";shift 2;;
      -h|--help)
        print_help; exit 0;;
      *)
        log "❌ Unknown option: $1"
        print_help; exit 1;;
    esac
  done
}

cleanup() {
  [[ -n "${TOKENS_FILE:-}" && -f "${TOKENS_FILE}" ]] && rm -f "${TOKENS_FILE}"

  log "🧹 Force deleting all pods in namespace ${LOAD_TEST_NAMESPACE}"
  # Force delete all pods immediately (load test - no graceful shutdown needed)
  $KUBECTL delete pods --all -n "${LOAD_TEST_NAMESPACE}" --force --grace-period=0 --ignore-not-found 2>/dev/null || true

  log "🧹 Deleting DevWorkspaces in namespace ${LOAD_TEST_NAMESPACE}"
  # Delete all DevWorkspaces (will be faster now that pods are gone)
  $KUBECTL delete devworkspaces --all -n "${LOAD_TEST_NAMESPACE}" --ignore-not-found --wait=false 2>/dev/null || true

  log "🧹 Deleting namespace ${LOAD_TEST_NAMESPACE}"
  $KUBECTL delete ns "${LOAD_TEST_NAMESPACE}" --ignore-not-found
}

# ----------------
# Kubernetes setup
# ----------------
create_namespace() {
  log "📦 Creating namespace ${LOAD_TEST_NAMESPACE}"
  $KUBECTL create namespace "${LOAD_TEST_NAMESPACE}" --dry-run=client -o yaml | $KUBECTL apply -f -

  # Delete all ClusterRoleBindings and ClusterRoles with the label
  $KUBECTL delete clusterrolebinding -l app=k6-loadtest --ignore-not-found
  $KUBECTL delete clusterrole -l app=devworkspace-webhook-server-loadtest --ignore-not-found
}

create_rbac() {
  log "🔐 Creating RBAC ClusterRole ${CLUSTER_ROLE_NAME}"
  cat <<EOF | $KUBECTL apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ${CLUSTER_ROLE_NAME}
  labels:
    app: devworkspace-webhook-server-loadtest
rules:
- apiGroups: ["${DW_API_GROUP}"]
  resources: ["${DW_RESOURCE}"]
  verbs: ["create", "get", "list", "watch", "update", "patch", "delete"]
- apiGroups: [""]
  resources: ["pods", "pods/exec"]
  verbs: ["get", "list", "create", "update", "patch"]
- apiGroups: ["metrics.k8s.io"]
  resources: ["pods"]
  verbs: ["get", "list"]
EOF
}

# ----------------
# Token generation (NO stdout output)
# ----------------
generate_tokens_json() {
  log "👥 Creating ${N_USERS} service accounts and tokens"

  TOKENS_FILE="$(mktemp)"
  log "📄 Writing tokens to ${TOKENS_FILE}"

  echo "[" > "${TOKENS_FILE}"

  for i in $(seq 1 "${N_USERS}"); do
    local sa="user-${i}"

    $KUBECTL create serviceaccount "${sa}" -n "${LOAD_TEST_NAMESPACE}" \
      --dry-run=client -o yaml | $KUBECTL apply -f -

    $KUBECTL delete clusterrolebinding "${sa}-rb" --ignore-not-found

    $KUBECTL create clusterrolebinding "${sa}-rb" \
      --clusterrole="${CLUSTER_ROLE_NAME}" \
      --serviceaccount="${LOAD_TEST_NAMESPACE}:${sa}"

    $KUBECTL label clusterrolebinding "${sa}-rb" app=devworkspace-webhook-server-loadtest --overwrite

    local token
    token=$($KUBECTL create token "${sa}" -n "${LOAD_TEST_NAMESPACE}" --duration="${TOKEN_TTL}")

    cat >> "${TOKENS_FILE}" <<EOF
  {
    "user": "${sa}",
    "namespace": "${LOAD_TEST_NAMESPACE}",
    "token": "${token}"
  }$( [[ "$i" -lt "$N_USERS" ]] && echo "," )
EOF
  done

  echo "]" >> "${TOKENS_FILE}"
}


# ----------------
# k6 execution
# ----------------
run_k6_load_test() {
  log "🚀 Running k6 load test"

  export N_USERS
  export K6_USERS_FILE="${TOKENS_FILE}"
  export KUBE_API
  export LOAD_TEST_NAMESPACE
  export WEBHOOK_NAMESPACE
  export DEV_WORKSPACE_READY_TIMEOUT_IN_SECONDS
  export DEVWORKSPACE_LINK

  k6 run "${K6_SCRIPT}"
}

# ----------------
# Main
# ----------------
main() {
  parse_arguments "$@"
  detect_cli

  trap cleanup EXIT

  KUBE_API=$($KUBECTL config view --minify -o jsonpath='{.clusters[0].cluster.server}')

  create_namespace
  create_rbac
  generate_tokens_json

  run_k6_load_test
}

main "$@"