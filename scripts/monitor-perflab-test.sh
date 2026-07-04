#!/bin/bash
# Monitor PerformanceLabs test progress
# Usage: ./scripts/monitor-perflab-test.sh

export PERFLAB_USER="${PERFLAB_USER:-rokumar}"
export PERFLAB_HOST="${PERFLAB_HOST:-192.168.29.152}"

echo "=========================================="
echo "PERFORMANCELABS TEST MONITOR"
echo "=========================================="
echo "Remote: ${PERFLAB_USER}@${PERFLAB_HOST}"
echo "Time: $(date)"
echo "=========================================="
echo ""

# Check if tmux session exists
if ssh -F /dev/null -o StrictHostKeyChecking=no "${PERFLAB_USER}@${PERFLAB_HOST}" "tmux ls 2>/dev/null | grep -q 'loadtest'"; then
  echo "✅ Test is RUNNING"
  echo ""
  echo "Latest output (last 40 lines):"
  echo "----------------------------------------"
  ssh -F /dev/null -o StrictHostKeyChecking=no "${PERFLAB_USER}@${PERFLAB_HOST}" "tmux capture-pane -t loadtest -p | tail -40"
  echo "----------------------------------------"
  echo ""
  echo "To attach: ssh -F /dev/null -t ${PERFLAB_USER}@${PERFLAB_HOST} 'tmux attach -t loadtest'"
  echo "           (Detach with Ctrl+b d)"
else
  echo "❌ Test COMPLETED or tmux session ended"
  echo ""
  echo "Checking for results..."
  LATEST_RUN=$(ssh -F /dev/null -o StrictHostKeyChecking=no "${PERFLAB_USER}@${PERFLAB_HOST}" \
    "ls -td /home/rokumar/work/repos/devworkspace-operator-load-tests/outputs/run_* 2>/dev/null | head -1")

  if [[ -n "${LATEST_RUN}" ]]; then
    echo "Latest run: ${LATEST_RUN}"
    echo ""
    ssh -F /dev/null -o StrictHostKeyChecking=no "${PERFLAB_USER}@${PERFLAB_HOST}" \
      "cat ${LATEST_RUN}/summary.txt 2>/dev/null || echo 'Summary not found'"
    echo ""
    echo "To collect results locally, run:"
    echo "  export PERFLAB_USER=${PERFLAB_USER}"
    echo "  export PERFLAB_HOST=${PERFLAB_HOST}"
    echo "  export REMOTE_REPO=/home/rokumar/work/repos/devworkspace-operator-load-tests"
    echo "  ./scripts/test-perflab-workflow-crc-collect-results.sh"
  else
    echo "No results found"
  fi
fi
