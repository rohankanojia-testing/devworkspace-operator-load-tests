#!/bin/bash
# Run load tests in the background for CRC QE AWS 32-node mode (no tmux required).
#
# Usage:
#   ./scripts/run-qe-aws-loadtest-background.sh
#   ./scripts/run-qe-aws-loadtest-background.sh test-plans/devspaces-prerelease-test-plan.json
#
# Monitor:
#   tail -f outputs/loadtest_current.log          # stable symlink to latest log
#   cat outputs/loadtest.meta                     # PID, log path, start time
#   ./scripts/run-qe-aws-loadtest-background.sh --status

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_PLAN="${1:-test-plans/devspaces-prerelease-test-plan.json}"
PID_FILE="${REPO_DIR}/outputs/loadtest.pid"
META_FILE="${REPO_DIR}/outputs/loadtest.meta"
CURRENT_LOG_LINK="${REPO_DIR}/outputs/loadtest_current.log"

log_info() { echo -e "ℹ️  $*" >&2; }
log_success() { echo -e "✅ $*" >&2; }
log_error() { echo -e "❌ $*" >&2; }

read_meta() {
  local key="${1}"
  if [[ -f "${META_FILE}" ]]; then
    grep -E "^${key}=" "${META_FILE}" 2>/dev/null | head -1 | cut -d= -f2-
  fi
}

write_meta() {
  local log_file="${1}"
  local pid="${2}"
  local test_plan="${3}"
  cat > "${META_FILE}" <<EOF
LOG_FILE=${log_file}
PID=${pid}
TEST_PLAN=${test_plan}
STARTED_AT=$(date -Iseconds 2>/dev/null || date)
STATUS=RUNNING
EOF
  ln -sf "$(basename "${log_file}")" "${CURRENT_LOG_LINK}"
}

update_meta_status() {
  local status="${1}"
  if [[ -f "${META_FILE}" ]]; then
    if grep -q '^STATUS=' "${META_FILE}"; then
      sed -i '' "s/^STATUS=.*/STATUS=${status}/" "${META_FILE}" 2>/dev/null \
        || sed -i "s/^STATUS=.*/STATUS=${status}/" "${META_FILE}"
    else
      echo "STATUS=${status}" >> "${META_FILE}"
    fi
  fi
}

get_monitor_log() {
  local log_file
  log_file="$(read_meta LOG_FILE)"
  if [[ -n "${log_file}" && -f "${log_file}" ]]; then
    echo "${log_file}"
    return 0
  fi
  ls -t "${REPO_DIR}"/outputs/loadtest_background_*.log 2>/dev/null | head -1 || true
}

show_status() {
  local monitor_log
  monitor_log="$(get_monitor_log)"

  if [[ -f "${PID_FILE}" ]]; then
    local pid
    pid="$(cat "${PID_FILE}")"
    if kill -0 "${pid}" 2>/dev/null || pgrep -f 'run_all.*loadtest' >/dev/null 2>&1; then
      echo "RUNNING"
      log_info "PID file: ${PID_FILE} (PID ${pid})"
      log_info "Meta: ${META_FILE}"
      if [[ -n "${monitor_log}" ]]; then
        log_info "Log: ${monitor_log}"
        echo "------------------------------------------"
        tail -15 "${monitor_log}"
      fi
      return 0
    fi
  fi

  if pgrep -f 'run_all.*loadtest' >/dev/null 2>&1; then
    echo "RUNNING"
    if [[ -n "${monitor_log}" ]]; then
      log_info "Log: ${monitor_log}"
      echo "------------------------------------------"
      tail -15 "${monitor_log}"
    fi
    return 0
  fi

  echo "COMPLETED"
  update_meta_status "COMPLETED"
  if [[ -n "${monitor_log}" ]]; then
    log_info "Log: ${monitor_log}"
    echo "------------------------------------------"
    tail -15 "${monitor_log}"
  fi
  return 1
}

if [[ "${1:-}" == "--status" ]]; then
  show_status
  exit $?
fi

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  cat <<EOF
Usage: $0 [TEST_PLAN_FILE]
       $0 --status

Run load tests in the background for CRC QE AWS mode.

Default test plan: test-plans/devspaces-prerelease-test-plan.json
EOF
  exit 0
fi

if [[ ! -f "${REPO_DIR}/${TEST_PLAN}" ]]; then
  log_error "Test plan not found: ${REPO_DIR}/${TEST_PLAN}"
  exit 1
fi

if [[ -f "${PID_FILE}" ]]; then
  old_pid="$(cat "${PID_FILE}")"
  if kill -0 "${old_pid}" 2>/dev/null; then
    log_error "Load test already running (PID ${old_pid})"
    log_info "Check status: $0 --status"
    exit 1
  fi
  rm -f "${PID_FILE}"
fi

if pgrep -f 'run_all.*loadtest' >/dev/null 2>&1; then
  log_error "A load test suite is already running"
  log_info "Check status: $0 --status"
  exit 1
fi

mkdir -p "${REPO_DIR}/outputs"
LOG_FILE="${REPO_DIR}/outputs/loadtest_background_$(date +%Y%m%d_%H%M%S).log"

# Optional env prefix (e.g. RUN_ENV="RESTART_OPERATOR=false" to skip operator restart)
RUN_ENV="${RUN_ENV:-}"
_run_cmd="cd '${REPO_DIR}' && ${RUN_ENV} exec ./scripts/run_all_loadtests.sh '${TEST_PLAN}'"

# Fully detach from the launching shell (survives terminal/agent session exit)
if command -v setsid >/dev/null 2>&1; then
  setsid nohup stdbuf -oL -eL bash -c "${_run_cmd}" \
    > "${LOG_FILE}" 2>&1 < /dev/null &
else
  nohup stdbuf -oL -eL bash -c "${_run_cmd}" \
    > "${LOG_FILE}" 2>&1 < /dev/null &
fi

echo $! > "${PID_FILE}"
write_meta "${LOG_FILE}" "$(cat "${PID_FILE}")" "${TEST_PLAN}"

log_success "Load test started in background"
echo "PID:      $(cat "${PID_FILE}")"
echo "Log:      ${LOG_FILE}"
echo "Monitor:  tail -f ${LOG_FILE}"
echo "          tail -f ${CURRENT_LOG_LINK}"
echo "Meta:     ${META_FILE}"
echo "Plan:     ${TEST_PLAN}"
echo "Status:   $0 --status"
