#!/bin/bash
# ============================================================================
# Performance Labs load-test launcher
# ============================================================================
#
# SSH into a Performance Labs host, run a JSON test plan in a durable tmux
# session, monitor progress, and copy results back locally.
#
# Prerequisites:
#   export PERFLAB_USER=root
#   export PERFLAB_HOST=perflab.example.com
#   Optional: export REMOTE_REPO=/home/devworkspace-operator-load-tests
#
# Usage:
#   ./scripts/run-perflab-loadtest.sh start [--type controller|webhook|backup] \
#       [--plan PATH] [--kill-existing] [--skip-dwoc-patch] \
#       [--no-restart-operator] [--no-tracker] [--session NAME]
#   ./scripts/run-perflab-loadtest.sh status
#   ./scripts/run-perflab-loadtest.sh attach
#   ./scripts/run-perflab-loadtest.sh stop [--tracker-only]
#   ./scripts/run-perflab-loadtest.sh collect [--run-dir REMOTE_PATH] [--force]
#   ./scripts/run-perflab-loadtest.sh help
#
# Examples:
#   ./scripts/run-perflab-loadtest.sh start
#   ./scripts/run-perflab-loadtest.sh start --plan test-plans/1500-single-only-test-plan.json --kill-existing
#   ./scripts/run-perflab-loadtest.sh start --type webhook --kill-existing
#   ./scripts/run-perflab-loadtest.sh status
#   ./scripts/run-perflab-loadtest.sh collect
# ============================================================================

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REMOTE_REPO="${REMOTE_REPO:-/home/devworkspace-operator-load-tests}"
TMUX_SESSION="${TMUX_SESSION:-loadtest}"
SESSION_ENV="${REPO_DIR}/outputs/loadtest_session.env"
POLL_INTERVAL="${POLL_INTERVAL:-10}"

# SSH: match other perflab helpers (ignore local ProxyJump unless overridden)
SSH_BASE_OPTS=(-F /dev/null -o StrictHostKeyChecking=no -o UserKnownHostsFile="${HOME}/.ssh/known_hosts" -o ConnectTimeout=30)
# shellcheck disable=SC2206
if [[ -n "${PERFLAB_SSH_OPTS:-}" ]]; then
  # Allow: PERFLAB_SSH_OPTS="-o ProxyJump=bastion"
  read -r -a EXTRA_SSH_OPTS <<< "${PERFLAB_SSH_OPTS}"
  SSH_BASE_OPTS+=("${EXTRA_SSH_OPTS[@]}")
fi

log_info() { echo -e "ℹ️  $*" >&2; }
log_success() { echo -e "✅ $*" >&2; }
log_error() { echo -e "❌ $*" >&2; }
log_warn() { echo -e "⚠️  $*" >&2; }

usage() {
  cat <<'EOF'
Performance Labs load-test launcher (SSH + tmux)

Prerequisites:
  export PERFLAB_USER=root
  export PERFLAB_HOST=perflab.example.com
  # optional: export REMOTE_REPO=/home/devworkspace-operator-load-tests

Commands:
  start [--type controller|webhook|backup] [--plan PATH]
        [--kill-existing] [--skip-dwoc-patch] [--no-restart-operator]
        [--no-tracker] [--session NAME]
  status
  attach
  stop [--tracker-only]
  collect [--run-dir REMOTE_PATH] [--force]
  help

Examples:
  ./scripts/run-perflab-loadtest.sh start --kill-existing
  ./scripts/run-perflab-loadtest.sh start --plan test-plans/1500-single-only-test-plan.json --kill-existing
  ./scripts/run-perflab-loadtest.sh start --type webhook --kill-existing
  ./scripts/run-perflab-loadtest.sh status
  ./scripts/run-perflab-loadtest.sh collect
EOF
}

require_perflab_env() {
  if [[ -z "${PERFLAB_USER:-}" || -z "${PERFLAB_HOST:-}" ]]; then
    log_error "PERFLAB_USER and PERFLAB_HOST must be set"
    echo "  export PERFLAB_USER=root"
    echo "  export PERFLAB_HOST=perflab.example.com"
    exit 1
  fi
}

run_remote() {
  require_perflab_env
  ssh "${SSH_BASE_OPTS[@]}" "${PERFLAB_USER}@${PERFLAB_HOST}" "$@"
}

scp_to_remote() {
  require_perflab_env
  scp "${SSH_BASE_OPTS[@]}" "$@"
}

scp_from_remote() {
  require_perflab_env
  scp "${SSH_BASE_OPTS[@]}" "$@"
}

load_session_env() {
  if [[ -f "${SESSION_ENV}" ]]; then
    # shellcheck disable=SC1090
    set -a
    # shellcheck source=/dev/null
    source "${SESSION_ENV}"
    set +a
  fi
}

save_session_env() {
  mkdir -p "${REPO_DIR}/outputs"
  cat > "${SESSION_ENV}" <<EOF
CLUSTER_MODE=perflab
TEST_TYPE=${TEST_TYPE}
TEST_PLAN=${TEST_PLAN_REL}
TEST_RUNNER=${TEST_RUNNER}
PERFLAB_USER=${PERFLAB_USER}
PERFLAB_HOST=${PERFLAB_HOST}
REMOTE_REPO=${REMOTE_REPO}
TMUX_SESSION=${TMUX_SESSION}
RUN_DIR=${RUN_DIR:-}
CAPACITY_LOG_FILE=${CAPACITY_LOG_FILE:-}
DWOC_LOG_FILE=${DWOC_LOG_FILE:-}
DWO_VERSION=${DWO_VERSION:-}
STARTED_AT=${STARTED_AT:-}
RESTART_OPERATOR=${RESTART_OPERATOR:-true}
EOF
  log_success "Session saved: ${SESSION_ENV}"
}

default_plan_for_type() {
  case "$1" in
    controller) echo "test-plans/controller-test-plan.json" ;;
    webhook)    echo "test-plans/webhook-performancelabs-test-plan.json" ;;
    backup)     echo "test-plans/backup-restore-openshift-internal-test-plan.json" ;;
    *)
      log_error "Unknown type: $1 (controller|webhook|backup)"
      exit 1
      ;;
  esac
}

runner_for_type() {
  case "$1" in
    controller) echo "./scripts/run_all_loadtests.sh" ;;
    webhook)    echo "./scripts/run_all_webhook_loadtests.sh" ;;
    backup)     echo "./scripts/run_all_backup_loadtests.sh" ;;
  esac
}

parse_script_for_type() {
  case "$1" in
    controller) echo "./scripts/parse-controller-outputs.sh" ;;
    webhook)    echo "./scripts/parse-webhook-outputs.sh" ;;
    backup)     echo "./scripts/parse-backup-outputs.sh" ;;
  esac
}

report_script_for_type() {
  case "$1" in
    controller) echo "./scripts/generate-prerelease-loadtest-report.sh" ;;
    webhook)    echo "./scripts/generate-webhook-loadtest-report.sh" ;;
    backup)     echo "./scripts/generate-backup-loadtest-report.sh" ;;
  esac
}

run_glob_for_type() {
  case "$1" in
    controller) echo "run_*" ;;
    webhook)    echo "webhook_run_*" ;;
    backup)     echo "backup_run_*" ;;
  esac
}

tmux_session_exists() {
  run_remote "tmux has-session -t '${TMUX_SESSION}' 2>/dev/null"
}

suite_process_running() {
  # Match real suite/k6 processes; ignore idle tmux command lines that still
  # contain the script path after the suite exits (tmux ...; exec bash).
  run_remote "pgrep -af 'run_all_(loadtests|webhook_loadtests|backup_loadtests)\\.sh|runk6\\.sh|k6 run' 2>/dev/null | grep -vE 'tmux |pgrep|run-perflab-loadtest' | grep -q ."
}

latest_remote_run_dir() {
  local type="${1:-controller}"
  local glob
  glob="$(run_glob_for_type "${type}")"
  run_remote "ls -td ${REMOTE_REPO}/outputs/${glob} 2>/dev/null | head -1"
}

cmd_start() {
  local TEST_TYPE="controller"
  local PLAN_ARG=""
  local KILL_EXISTING=false
  local SKIP_DWOC=false
  local RESTART_OPERATOR=true
  local START_TRACKER=true

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --type)
        TEST_TYPE="$2"
        shift 2
        ;;
      --plan)
        PLAN_ARG="$2"
        shift 2
        ;;
      --kill-existing)
        KILL_EXISTING=true
        shift
        ;;
      --skip-dwoc-patch)
        SKIP_DWOC=true
        shift
        ;;
      --no-restart-operator)
        RESTART_OPERATOR=false
        shift
        ;;
      --no-tracker)
        START_TRACKER=false
        shift
        ;;
      --session)
        TMUX_SESSION="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        log_error "Unknown start option: $1"
        usage
        exit 1
        ;;
    esac
  done

  require_perflab_env
  mkdir -p "${REPO_DIR}/outputs"

  local TEST_PLAN_REL TEST_PLAN_LOCAL TEST_RUNNER
  TEST_PLAN_REL="${PLAN_ARG:-$(default_plan_for_type "${TEST_TYPE}")}"
  if [[ "${TEST_PLAN_REL}" != /* ]]; then
    TEST_PLAN_LOCAL="${REPO_DIR}/${TEST_PLAN_REL}"
  else
    TEST_PLAN_LOCAL="${TEST_PLAN_REL}"
    TEST_PLAN_REL="test-plans/$(basename "${TEST_PLAN_LOCAL}")"
  fi
  TEST_RUNNER="$(runner_for_type "${TEST_TYPE}")"

  if [[ ! -f "${TEST_PLAN_LOCAL}" ]]; then
    log_error "Test plan not found: ${TEST_PLAN_LOCAL}"
    exit 1
  fi

  if [[ ! -f "${REPO_DIR}/scripts/run_all_loadtests.sh" ]]; then
    log_error "Not in the load-testing repository (${REPO_DIR})"
    exit 1
  fi

  echo "=========================================="
  echo "PERFORMANCELABS LOAD TEST — START"
  echo "=========================================="
  echo "Host:     ${PERFLAB_USER}@${PERFLAB_HOST}"
  echo "Remote:   ${REMOTE_REPO}"
  echo "Type:     ${TEST_TYPE}"
  echo "Plan:     ${TEST_PLAN_REL}"
  echo "Runner:   ${TEST_RUNNER}"
  echo "Session:  ${TMUX_SESSION}"
  echo "Restart:  ${RESTART_OPERATOR}"
  echo "=========================================="

  log_info "Verifying SSH + cluster access..."
  if ! run_remote "echo 'SSH OK' && oc whoami && command -v kubectl && command -v k6 && command -v tmux" >/dev/null; then
    log_error "SSH or remote prerequisites failed (need oc, kubectl, k6, tmux)"
    exit 1
  fi
  log_success "SSH OK as $(run_remote 'oc whoami')"

  log_info "Checking remote repo..."
  if ! run_remote "test -f ${REMOTE_REPO}/scripts/run_all_loadtests.sh"; then
    log_error "Remote repo missing at ${REMOTE_REPO}"
    exit 1
  fi
  log_success "Remote repo OK"

  local CAPACITY_LOG_FILE DWO_VERSION DWOC_LOG_FILE STARTED_AT RUN_DIR
  CAPACITY_LOG_FILE="${REPO_DIR}/outputs/cluster_capacity_$(date +%Y%m%d_%H%M%S).txt"
  log_info "Cluster capacity..."
  run_remote "kubectl get nodes -o custom-columns=NAME:.metadata.name,CPU:.status.allocatable.cpu,MEMORY:.status.allocatable.memory" \
    | tee "${CAPACITY_LOG_FILE}"
  log_success "Capacity logged: ${CAPACITY_LOG_FILE}"

  local DWO_LOG
  DWO_LOG="${REPO_DIR}/outputs/dwo_version_$(date +%Y%m%d_%H%M%S).txt"
  {
    echo "=== DevWorkspace Operator ==="
    run_remote "kubectl get csv -n openshift-operators 2>/dev/null | grep -iE 'NAME|devworkspace' || true"
    run_remote "kubectl get deploy -n openshift-operators 2>/dev/null | grep -i workspace || true"
  } | tee "${DWO_LOG}"
  DWO_VERSION=$(run_remote "kubectl get csv -n openshift-operators -o jsonpath='{.items[?(@.spec.displayName==\"DevWorkspace Operator\")].spec.version}' 2>/dev/null" | tr -d '[:space:]' || true)
  if [[ -z "${DWO_VERSION}" ]]; then
    log_warn "DWO version not detected — continuing anyway"
  else
    log_success "DWO version: ${DWO_VERSION}"
  fi

  if [[ "${SKIP_DWOC}" == "false" ]]; then
    DWOC_LOG_FILE="${REPO_DIR}/outputs/dwoc_config_$(date +%Y%m%d_%H%M%S).txt"
    log_info "Patching DevWorkspaceOperatorConfig..."
    {
      echo "=== BEFORE PATCH ==="
      run_remote "kubectl get devworkspaceoperatorconfig devworkspace-operator-config -n openshift-operators -o yaml 2>/dev/null || echo 'DevWorkspaceOperatorConfig not found'"
    } | tee "${DWOC_LOG_FILE}"

    if run_remote "kubectl get devworkspaceoperatorconfig devworkspace-operator-config -n openshift-operators" >/dev/null 2>&1; then
      run_remote "kubectl patch devworkspaceoperatorconfig devworkspace-operator-config -n openshift-operators --type merge --patch '{\"config\":{\"workspace\":{\"imagePullPolicy\":\"IfNotPresent\",\"progressTimeout\":\"3600s\"}}}'"
    else
      run_remote 'kubectl apply -f - <<EOF
apiVersion: controller.devfile.io/v1alpha1
kind: DevWorkspaceOperatorConfig
metadata:
  name: devworkspace-operator-config
  namespace: openshift-operators
config:
  workspace:
    imagePullPolicy: IfNotPresent
    progressTimeout: 3600s
EOF'
    fi

    {
      echo ""
      echo "=== AFTER PATCH ==="
      run_remote "kubectl get devworkspaceoperatorconfig devworkspace-operator-config -n openshift-operators -o yaml"
      echo ""
      echo "=== VERIFICATION ==="
      run_remote "kubectl get devworkspaceoperatorconfig devworkspace-operator-config -n openshift-operators -o jsonpath='imagePullPolicy={.config.workspace.imagePullPolicy} progressTimeout={.config.workspace.progressTimeout}{\"\\n\"}'"
    } | tee -a "${DWOC_LOG_FILE}"
    log_success "DWOC patched (imagePullPolicy=IfNotPresent, progressTimeout=3600s)"
  else
    log_info "Skipping DWOC patch (--skip-dwoc-patch)"
  fi

  if tmux_session_exists; then
    if [[ "${KILL_EXISTING}" == "true" ]]; then
      log_warn "Killing existing tmux session '${TMUX_SESSION}'..."
      run_remote "tmux kill-session -t '${TMUX_SESSION}' 2>/dev/null || true"
      run_remote "cd ${REMOTE_REPO} && ./scripts/track-dw-status-background.sh --stop 2>/dev/null || true"
    else
      log_error "tmux session '${TMUX_SESSION}' already exists"
      echo "  Attach:  $0 attach"
      echo "  Kill:    $0 stop   OR   start --kill-existing"
      exit 1
    fi
  fi

  log_info "Syncing test plan to remote..."
  run_remote "mkdir -p ${REMOTE_REPO}/test-plans"
  scp_to_remote "${TEST_PLAN_LOCAL}" "${PERFLAB_USER}@${PERFLAB_HOST}:${REMOTE_REPO}/${TEST_PLAN_REL}"
  log_success "Plan synced: ${TEST_PLAN_REL}"

  STARTED_AT="$(date -Iseconds)"
  local REMOTE_CMD
  REMOTE_CMD="cd ${REMOTE_REPO} && RESTART_OPERATOR=${RESTART_OPERATOR} ${TEST_RUNNER} ${TEST_PLAN_REL}; exec bash"

  log_info "Starting tmux session '${TMUX_SESSION}'..."
  run_remote "tmux new-session -d -s '${TMUX_SESSION}' '${REMOTE_CMD}'"
  sleep 3

  if ! tmux_session_exists; then
    log_error "Failed to create tmux session"
    exit 1
  fi
  log_success "tmux session started"

  # Wait briefly for run directory (controller uses run_*; others differ)
  log_info "Waiting for remote output directory..."
  RUN_DIR=""
  local i
  for i in $(seq 1 24); do
    RUN_DIR="$(latest_remote_run_dir "${TEST_TYPE}" || true)"
    if [[ -n "${RUN_DIR}" ]]; then
      local age
      age=$(run_remote "echo \$(( \$(date +%s) - \$(stat -c %Y '${RUN_DIR}' 2>/dev/null || echo 0) ))" || echo 9999)
      if [[ "${age}" -lt 120 ]]; then
        break
      fi
      RUN_DIR=""
    fi
    sleep 5
  done

  if [[ -z "${RUN_DIR}" ]]; then
    log_warn "Could not detect a fresh run directory yet — check status shortly"
  else
    log_success "Run directory: ${RUN_DIR}"
  fi

  if [[ "${TEST_TYPE}" == "controller" && "${START_TRACKER}" == "true" && -n "${RUN_DIR}" ]]; then
    log_info "Starting DevWorkspace phase tracker..."
    local rel_csv="${RUN_DIR#${REMOTE_REPO}/}/dw_status.csv"
    run_remote "cd ${REMOTE_REPO} && ./scripts/track-dw-status-background.sh --stop 2>/dev/null || true"
    run_remote "cd ${REMOTE_REPO} && OUTPUT_FILE=${rel_csv} ./scripts/track-dw-status-background.sh ${POLL_INTERVAL}"
  elif [[ "${START_TRACKER}" == "true" && "${TEST_TYPE}" != "controller" ]]; then
    log_info "Tracker skipped (controller-only)"
  fi

  save_session_env

  echo ""
  echo "=========================================="
  echo "TEST RUNNING"
  echo "=========================================="
  run_remote "tmux capture-pane -t '${TMUX_SESSION}' -p | tail -25"
  echo "=========================================="
  echo "Monitor:  $0 status"
  echo "Attach:   $0 attach"
  echo "Collect:  $0 collect   # after suite finishes"
  echo "=========================================="
}

cmd_status() {
  load_session_env
  require_perflab_env
  local type="${TEST_TYPE:-controller}"

  echo "=========================================="
  echo "PERFORMANCELABS STATUS — $(date)"
  echo "=========================================="
  echo "Host: ${PERFLAB_USER}@${PERFLAB_HOST}"
  echo "Type: ${type}"
  [[ -n "${TEST_PLAN:-}" ]] && echo "Plan: ${TEST_PLAN}"
  [[ -n "${RUN_DIR:-}" ]] && echo "Run:  ${RUN_DIR}"
  echo "=========================================="

  local tmux_ok=false
  local suite_ok=false
  if tmux_session_exists; then
    tmux_ok=true
  fi
  if suite_process_running; then
    suite_ok=true
  fi

  if [[ "${suite_ok}" == "true" ]]; then
    echo "STATUS: RUNNING"
  elif [[ "${tmux_ok}" == "true" ]]; then
    echo "STATUS: IDLE tmux (suite likely finished — shell left open)"
  else
    echo "STATUS: COMPLETED / no session"
  fi

  echo ""
  echo "=== Processes ==="
  run_remote "pgrep -af 'run_all_|runk6|k6 run' 2>/dev/null | grep -vE 'tmux |pgrep|run-perflab-loadtest' | head -8 || echo '(none)'"

  local run_dir="${RUN_DIR:-}"
  if [[ -z "${run_dir}" ]]; then
    run_dir="$(latest_remote_run_dir "${type}" || true)"
  fi

  if [[ -n "${run_dir}" ]]; then
    echo ""
    echo "=== Run dir: ${run_dir} ==="
    run_remote "ls -lah '${run_dir}' '${run_dir}/logs' 2>/dev/null | head -40"

    echo ""
    echo "=== Summary (if any) ==="
    run_remote "cat '${run_dir}/summary.txt' 2>/dev/null || echo '(no summary.txt yet)'"

    echo ""
    echo "=== Latest log progress ==="
    run_remote "LATEST=\$(ls -t '${run_dir}'/logs/*.log 2>/dev/null | head -1); echo \"Log: \$LATEST\"; [[ -n \"\$LATEST\" ]] && tail -15 \"\$LATEST\""

    if [[ "${type}" == "controller" ]]; then
      echo ""
      echo "=== DW status (last 5) ==="
      run_remote "tail -5 '${run_dir}/dw_status.csv' 2>/dev/null || echo '(no dw_status.csv)'"
    fi
  fi

  if [[ "${tmux_ok}" == "true" ]]; then
    echo ""
    echo "=== tmux pane (last 25) ==="
    run_remote "tmux capture-pane -t '${TMUX_SESSION}' -p | tail -25"
  fi
}

cmd_attach() {
  load_session_env
  require_perflab_env
  if ! tmux_session_exists; then
    log_error "No tmux session '${TMUX_SESSION}'"
    exit 1
  fi
  log_info "Attaching to ${TMUX_SESSION} (detach: Ctrl+b d)..."
  ssh -t "${SSH_BASE_OPTS[@]}" "${PERFLAB_USER}@${PERFLAB_HOST}" "tmux attach-session -t '${TMUX_SESSION}'"
}

cmd_stop() {
  load_session_env
  require_perflab_env
  local tracker_only=false
  if [[ "${1:-}" == "--tracker-only" ]]; then
    tracker_only=true
  fi

  log_info "Stopping DW tracker on remote..."
  run_remote "cd ${REMOTE_REPO} && ./scripts/track-dw-status-background.sh --stop 2>/dev/null || true"

  if [[ "${tracker_only}" == "true" ]]; then
    log_success "Tracker stopped"
    return 0
  fi

  if tmux_session_exists; then
    log_warn "Killing tmux session '${TMUX_SESSION}'..."
    run_remote "tmux kill-session -t '${TMUX_SESSION}'"
    log_success "tmux session killed"
  else
    log_info "No tmux session '${TMUX_SESSION}'"
  fi
}

cmd_collect() {
  load_session_env
  require_perflab_env

  local FORCE=false
  local RUN_DIR_ARG=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force) FORCE=true; shift ;;
      --run-dir) RUN_DIR_ARG="$2"; shift 2 ;;
      *) log_error "Unknown collect option: $1"; exit 1 ;;
    esac
  done

  local type="${TEST_TYPE:-controller}"
  local run_dir="${RUN_DIR_ARG:-${RUN_DIR:-}}"

  if suite_process_running && [[ "${FORCE}" != "true" ]]; then
    log_error "Suite still running. Wait for completion, or pass --force"
    cmd_status || true
    exit 1
  fi

  if [[ -z "${run_dir}" ]]; then
    run_dir="$(latest_remote_run_dir "${type}")"
  fi
  if [[ -z "${run_dir}" ]]; then
    log_error "No remote run directory found"
    exit 1
  fi

  echo "=========================================="
  echo "COLLECT RESULTS"
  echo "=========================================="
  echo "Remote: ${run_dir}"
  echo "Type:   ${type}"
  echo "=========================================="

  log_info "Stopping tracker..."
  run_remote "cd ${REMOTE_REPO} && ./scripts/track-dw-status-background.sh --stop 2>/dev/null || true"

  local parse_script report_script
  parse_script="$(parse_script_for_type "${type}")"
  report_script="$(report_script_for_type "${type}")"

  log_info "Parsing outputs on remote..."
  run_remote "cd ${REMOTE_REPO} && ${parse_script} ${run_dir}/" || log_warn "Parse script returned non-zero"

  local capacity_log="${CAPACITY_LOG_FILE:-}"
  if [[ -z "${capacity_log}" || ! -f "${capacity_log}" ]]; then
    capacity_log="$(ls -t "${REPO_DIR}"/outputs/cluster_capacity_*.txt 2>/dev/null | head -1 || true)"
  fi

  log_info "Generating report on remote..."
  if [[ -n "${capacity_log}" && -f "${capacity_log}" ]]; then
    scp_to_remote "${capacity_log}" "${PERFLAB_USER}@${PERFLAB_HOST}:${REMOTE_REPO}/outputs/"
    run_remote "cd ${REMOTE_REPO} && ${report_script} ${run_dir} ${REMOTE_REPO}/outputs/$(basename "${capacity_log}")" \
      || log_warn "Report generator returned non-zero"
  else
    run_remote "cd ${REMOTE_REPO} && ${report_script} ${run_dir}" \
      || log_warn "Report generator returned non-zero"
  fi

  local local_dest="${REPO_DIR}/outputs"
  mkdir -p "${local_dest}"
  log_info "Copying ${run_dir} → ${local_dest}/"
  scp_from_remote -r "${PERFLAB_USER}@${PERFLAB_HOST}:${run_dir}" "${local_dest}/"

  # Snapshots (best-effort)
  scp_from_remote \
    "${PERFLAB_USER}@${PERFLAB_HOST}:${REMOTE_REPO}/outputs/cluster_capacity_*.txt" \
    "${PERFLAB_USER}@${PERFLAB_HOST}:${REMOTE_REPO}/outputs/dwo_version_*.txt" \
    "${PERFLAB_USER}@${PERFLAB_HOST}:${REMOTE_REPO}/outputs/dwoc_config_*.txt" \
    "${local_dest}/" 2>/dev/null || true

  local local_run="${local_dest}/$(basename "${run_dir}")"
  log_success "Local copy: ${local_run}"
  ls -lah "${local_run}" || true

  # Prefer regenerating report locally with capacity for controller
  if [[ "${type}" == "controller" && -f "${REPO_DIR}/scripts/generate-prerelease-loadtest-report.sh" ]]; then
    if [[ -n "${capacity_log}" && -f "${capacity_log}" ]]; then
      log_info "Refreshing local report with capacity snapshot..."
      "${REPO_DIR}/scripts/generate-prerelease-loadtest-report.sh" "${local_run}" "${capacity_log}" || true
    fi
  fi

  echo ""
  echo "=========================================="
  echo "REPORT FILES"
  echo "=========================================="
  find "${local_run}" -maxdepth 1 \( -name '*.csv' -o -name '*.md' -o -name 'summary.txt' \) -print 2>/dev/null || true
  if [[ -f "${local_run}/controller_load_test_results.csv" ]]; then
    echo ""
    echo "CSV:"
    cat "${local_run}/controller_load_test_results.csv"
  fi
  if [[ -f "${local_run}/summary.txt" ]]; then
    echo ""
    cat "${local_run}/summary.txt"
  fi
  echo "=========================================="
  echo "Import CSV into Google Sheets (File → Import → Comma)."
  echo "=========================================="
}

main() {
  local cmd="${1:-help}"
  shift || true

  case "${cmd}" in
    start)   cmd_start "$@" ;;
    status)  cmd_status "$@" ;;
    attach)  cmd_attach "$@" ;;
    stop)    cmd_stop "$@" ;;
    collect) cmd_collect "$@" ;;
    help|-h|--help) usage ;;
    *)
      log_error "Unknown command: ${cmd}"
      usage
      exit 1
      ;;
  esac
}

main "$@"
