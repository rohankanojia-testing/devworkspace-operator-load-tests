#!/bin/bash
# Poll DevWorkspace phases cluster-wide and append counts to CSV.
# Based on track_dw.sh — use during controller load tests.
#
# Usage:
#   ./scripts/track-dw-status.sh [poll_interval_seconds]
#   OUTPUT_FILE=outputs/run_20260703_163649/dw_status.csv ./scripts/track-dw-status.sh 10
#
# Stop with Ctrl+C to print max Running summary.

set -euo pipefail

OUTPUT_FILE="${OUTPUT_FILE:-outputs/dw_status.csv}"
POLL_INTERVAL="${1:-10}"

PHASES=("Starting" "Running" "Stopped" "Failing" "Failed" "Terminating")

get_emoji() {
  case "$1" in
    Starting) echo "🟡" ;;
    Running) echo "🟢" ;;
    Stopped) echo "⏸️" ;;
    Failing) echo "🟠" ;;
    Failed) echo "🔴" ;;
    Terminating) echo "⚫" ;;
    *) echo "❓" ;;
  esac
}

setup() {
  mkdir -p "$(dirname "${OUTPUT_FILE}")"
  echo "🔁 Initializing output file: ${OUTPUT_FILE}"
  rm -f "${OUTPUT_FILE}"
  echo "timestamp,${PHASES[*]}" | sed 's/ /,/g' > "${OUTPUT_FILE}"
}

print_report() {
  echo -e "\n📊 --- Report: Max Running DevWorkspaces ---"
  awk -F',' '
    NR==1 { next }
    {
      if ($3 > max) {
        max = $3
        line = $0
      }
    }
    END {
      print "🟢 Max Running:", max
      print "⏱️ Timestamp:", $1
      print "📄 Row:", line
    }
  ' "${OUTPUT_FILE}"
  exit 0
}

collect_status() {
  local timestamp
  timestamp=$(date +"%H:%M:%S")

  if ! json=$(oc get dw --all-namespaces -o json 2>/dev/null); then
    echo "${timestamp},ERROR" >> "${OUTPUT_FILE}"
    echo "${timestamp} ❌ Failed to fetch DevWorkspaces"
    return
  fi

  local counts=()
  local display=""

  for phase in "${PHASES[@]}"; do
    count=$(echo "$json" | jq "[.items[] | select(.status.phase == \"${phase}\")] | length")
    counts+=("${count}")
    display+="$(get_emoji "${phase}") ${phase}:${count}  "
  done

  echo "${timestamp},${counts[*]}" | sed 's/ /,/g' >> "${OUTPUT_FILE}"
  echo "${timestamp} → ${display}"
}

trap print_report INT

setup

while true; do
  collect_status
  sleep "${POLL_INTERVAL}"
done
