#!/usr/bin/env bash
# Quick snapshot of backup job pod counts

echo "=== Backup Job Pods Summary ==="
echo ""
echo "Jobs:"
echo "  Total:     $(kubectl get jobs -l controller.devfile.io/backup-job=true --all-namespaces --no-headers 2>/dev/null | wc -l)"
echo "  Succeeded: $(kubectl get jobs -l controller.devfile.io/backup-job=true --all-namespaces -o json 2>/dev/null | jq '[.items[] | select(.status.succeeded == 1)] | length')"
echo "  Failed:    $(kubectl get jobs -l controller.devfile.io/backup-job=true --all-namespaces -o json 2>/dev/null | jq '[.items[] | select(.status.conditions[]? | select(.type == "Failed" and .status == "True"))] | length')"
echo ""
echo "Pods:"
echo "  Total:     $(kubectl get pods -l controller.devfile.io/backup-job --all-namespaces --no-headers 2>/dev/null | wc -l)"
echo "  Running:   $(kubectl get pods -l controller.devfile.io/backup-job --all-namespaces --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)"
echo "  Succeeded: $(kubectl get pods -l controller.devfile.io/backup-job --all-namespaces --field-selector=status.phase=Succeeded --no-headers 2>/dev/null | wc -l)"
echo "  Failed:    $(kubectl get pods -l controller.devfile.io/backup-job --all-namespaces --field-selector=status.phase=Failed --no-headers 2>/dev/null | wc -l)"
echo "  Pending:   $(kubectl get pods -l controller.devfile.io/backup-job --all-namespaces --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l)"
