#!/usr/bin/env bash
set -euo pipefail

# Monitor backup job pod counts
#
# Usage: ./monitor-backup-pods.sh [interval_seconds]
# Example: ./monitor-backup-pods.sh 10

INTERVAL=${1:-5}  # Default 5 seconds
BACKUP_LABEL="controller.devfile.io/backup-job=true"

echo "Monitoring backup job pods (Ctrl+C to stop)..."
echo "Interval: ${INTERVAL}s"
echo ""

while true; do
  TIMESTAMP=$(date +"%H:%M:%S")

  # Get job counts
  TOTAL_JOBS=$(kubectl get jobs -l "$BACKUP_LABEL" --all-namespaces --no-headers 2>/dev/null | wc -l || echo "0")
  COMPLETED_JOBS=$(kubectl get jobs -l "$BACKUP_LABEL" --all-namespaces -o json 2>/dev/null | \
    jq '[.items[] | select(.status.succeeded == 1)] | length' || echo "0")
  FAILED_JOBS=$(kubectl get jobs -l "$BACKUP_LABEL" --all-namespaces -o json 2>/dev/null | \
    jq '[.items[] | select(.status.conditions[]? | select(.type == "Failed" and .status == "True"))] | length' || echo "0")
  RUNNING_JOBS=$((TOTAL_JOBS - COMPLETED_JOBS - FAILED_JOBS))

  # Get pod counts directly
  ALL_PODS=$(kubectl get pods -l "controller.devfile.io/backup-job" --all-namespaces --no-headers 2>/dev/null | wc -l || echo "0")
  RUNNING_PODS=$(kubectl get pods -l "controller.devfile.io/backup-job" --all-namespaces --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l || echo "0")
  SUCCEEDED_PODS=$(kubectl get pods -l "controller.devfile.io/backup-job" --all-namespaces --field-selector=status.phase=Succeeded --no-headers 2>/dev/null | wc -l || echo "0")
  FAILED_PODS=$(kubectl get pods -l "controller.devfile.io/backup-job" --all-namespaces --field-selector=status.phase=Failed --no-headers 2>/dev/null | wc -l || echo "0")
  PENDING_PODS=$(kubectl get pods -l "controller.devfile.io/backup-job" --all-namespaces --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l || echo "0")

  # Clear previous line and print new status
  echo -ne "\r\033[K"
  echo "[$TIMESTAMP] Jobs: $TOTAL_JOBS total ($COMPLETED_JOBS done, $RUNNING_JOBS running, $FAILED_JOBS failed) | Pods: $ALL_PODS total ($RUNNING_PODS running, $SUCCEEDED_PODS succeeded, $FAILED_PODS failed, $PENDING_PODS pending)"

  sleep "$INTERVAL"
done
