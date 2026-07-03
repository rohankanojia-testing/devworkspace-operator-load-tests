#!/bin/bash
# Run track-dw-status.sh in the background during controller load tests.
#
# Usage:
#   ./scripts/track-dw-status-background.sh [poll_interval_seconds]
#   OUTPUT_FILE=outputs/run_20260703_163649/dw_status.csv ./scripts/track-dw-status-background.sh 10
#
# Monitor:
#   tail -5 outputs/dw_status.csv
#   ./scripts/track-dw-status-background.sh --status

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
POLL_INTERVAL="${1:-10}"
PID_FILE="${REPO_DIR}/outputs/track_dw.pid"
META_FILE="${REPO_DIR}/outputs/track_dw.meta"
TRACK_SCRIPT="${REPO_DIR}/scripts/track-dw-status.sh"

# Prefer user override if set (e.g. /Users/rokumar/temp-scripts/track_dw.sh)
if [[ -n "${TRACK_DW_SCRIPT:-}" && -x "${TRACK_DW_SCRIPT}" ]]; then
  TRACK_SCRIPT="${TRACK_DW_SCRIPT}"
fi

log_info() { echo -e "ℹ️  $*" >&2; }

show_status() {
  if [[ -f "${PID_FILE}" ]]; then
    local pid
    pid="$(cat "${PID_FILE}")"
    if kill -0 "${pid}" 2>/dev/null; then
      echo "RUNNING"
      log_info "PID: ${pid}"
      if [[ -f "${META_FILE}" ]]; then
        log_info "Meta: ${META_FILE}"
        grep -E '^(OUTPUT_FILE|POLL_INTERVAL)=' "${META_FILE}" 2>/dev/null || true
      fi
      local csv
      csv="$(grep -E '^OUTPUT_FILE=' "${META_FILE}" 2>/dev/null | cut -d= -f2- || echo outputs/dw_status.csv)"
      if [[ -f "${csv}" ]]; then
        echo "------------------------------------------"
        tail -3 "${csv}"
      fi
      return 0
    fi
  fi
  echo "STOPPED"
  return 1
}

if [[ "${1:-}" == "--status" ]]; then
  show_status
  exit $?
fi

if [[ "${1:-}" == "--stop" ]]; then
  if [[ -f "${PID_FILE}" ]]; then
    kill "$(cat "${PID_FILE}")" 2>/dev/null || true
    rm -f "${PID_FILE}"
    echo "Stopped track-dw-status"
  fi
  exit 0
fi

if [[ -f "${PID_FILE}" ]] && kill -0 "$(cat "${PID_FILE}")" 2>/dev/null; then
  echo "❌ track-dw-status already running (PID $(cat "${PID_FILE}"))"
  exit 1
fi

OUTPUT_FILE="${OUTPUT_FILE:-${REPO_DIR}/outputs/dw_status.csv}"
mkdir -p "$(dirname "${OUTPUT_FILE}")"

if [[ "${TRACK_SCRIPT}" == "${REPO_DIR}/scripts/track-dw-status.sh" ]]; then
  nohup env OUTPUT_FILE="${OUTPUT_FILE}" bash "${TRACK_SCRIPT}" "${POLL_INTERVAL}" \
    > "${REPO_DIR}/outputs/track_dw_background.log" 2>&1 &
else
  # External script (e.g. track_dw.sh) — run from its directory for default paths
  nohup bash -c "cd '$(dirname "${TRACK_SCRIPT}")' && OUTPUT_FILE='${OUTPUT_FILE}' bash '$(basename "${TRACK_SCRIPT}")' '${POLL_INTERVAL}'" \
    > "${REPO_DIR}/outputs/track_dw_background.log" 2>&1 &
fi

echo $! > "${PID_FILE}"
cat > "${META_FILE}" <<EOF
OUTPUT_FILE=${OUTPUT_FILE}
POLL_INTERVAL=${POLL_INTERVAL}
PID=$(cat "${PID_FILE}")
STARTED_AT=$(date -Iseconds 2>/dev/null || date)
TRACK_SCRIPT=${TRACK_SCRIPT}
EOF

echo "✅ DevWorkspace tracker started"
echo "PID:          $(cat "${PID_FILE}")"
echo "CSV:          ${OUTPUT_FILE}"
echo "Poll interval: ${POLL_INTERVAL}s"
echo "Status:       $0 --status"
echo "Stop:         $0 --stop"
