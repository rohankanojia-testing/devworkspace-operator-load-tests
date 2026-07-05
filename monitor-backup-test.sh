#!/bin/bash
# Monitor backup load test progress on PerformanceLabs CRC

PERFLAB_USER="${PERFLAB_USER:-rokumar}"
PERFLAB_HOST="${PERFLAB_HOST:-192.168.29.152}"

run_remote() {
  ssh -F /dev/null -o StrictHostKeyChecking=no "${PERFLAB_USER}@${PERFLAB_HOST}" "$@"
}

echo "=========================================="
echo "BACKUP LOAD TEST MONITOR"
echo "=========================================="
echo "Remote: ${PERFLAB_USER}@${PERFLAB_HOST}"
echo "Time: $(date)"
echo "=========================================="
echo ""

# Check if tmux session exists
if run_remote "tmux ls 2>/dev/null | grep -q 'loadtest'"; then
  echo "✅ Test suite is RUNNING"
  echo ""

  # Get latest run directory
  RUN_DIR=$(run_remote "ls -td ~/work/repos/devworkspace-operator-load-tests/outputs/backup_run_* 2>/dev/null | head -1")

  echo "Run directory: $RUN_DIR"
  echo ""

  # Show summary if exists
  if run_remote "test -f $RUN_DIR/summary.txt 2>/dev/null"; then
    echo "=== Partial Summary ==="
    run_remote "cat $RUN_DIR/summary.txt 2>/dev/null | tail -30"
  fi

  echo ""
  echo "=== Current Test Output (last 25 lines) ==="
  run_remote "tmux capture-pane -t loadtest -p | tail -25"

  echo ""
  echo "=== DevWorkspaces Status ==="
  DW_COUNT=$(run_remote "oc get dw --all-namespaces -l load-test=test-type --no-headers 2>/dev/null | wc -l" | tr -d ' ')
  echo "DevWorkspaces: $DW_COUNT"

  if [[ "$DW_COUNT" -gt 0 ]]; then
    run_remote "oc get dw --all-namespaces -l load-test=test-type --no-headers 2>/dev/null | awk '{print \$4}' | sort | uniq -c"
  fi

  echo ""
  echo "=== Backup Jobs ==="
  BACKUP_JOBS=$(run_remote "oc get jobs --all-namespaces -l devworkspace.devfile.io/backup-job=true --no-headers 2>/dev/null | wc -l" | tr -d ' ')
  echo "Backup jobs: $BACKUP_JOBS"

  if [[ "$BACKUP_JOBS" -gt 0 ]]; then
    run_remote "oc get jobs --all-namespaces -l devworkspace.devfile.io/backup-job=true --no-headers 2>/dev/null | awk '{print \$4}' | sort | uniq -c | head -5"
  fi

  echo ""
  echo "To attach: ssh -t ${PERFLAB_USER}@${PERFLAB_HOST} 'tmux attach -t loadtest'"
  echo "           (Detach with Ctrl+b d)"

else
  echo "❌ Test suite COMPLETED or tmux session ended"
  echo ""

  # Get latest run directory
  RUN_DIR=$(run_remote "ls -td ~/work/repos/devworkspace-operator-load-tests/outputs/backup_run_* 2>/dev/null | head -1")

  if [[ -n "$RUN_DIR" ]]; then
    echo "Latest run: $RUN_DIR"
    echo ""

    if run_remote "test -f $RUN_DIR/summary.txt 2>/dev/null"; then
      echo "=== Final Summary ==="
      run_remote "cat $RUN_DIR/summary.txt"
    fi

    echo ""
    echo "To generate reports, run:"
    echo "  ./scripts/generate-backup-loadtest-report.sh $RUN_DIR"
  else
    echo "No run directory found"
  fi
fi
