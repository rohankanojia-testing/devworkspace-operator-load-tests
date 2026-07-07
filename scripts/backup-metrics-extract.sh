#!/usr/bin/env bash
# Shared metric extraction for backup load test logs.
# Supports both legacy k6 textSummary and formatted "Metrics Summary" output.

# Strip ANSI color codes from log content
backup_metrics_strip_ansi() {
  sed 's/\x1b\[[0-9;]*m//g'
}

backup_metrics_is_formatted_summary() {
  local input="$1"
  echo "$input" | grep -q 'Backup Load Test - Metrics Summary'
}

# Extract integer/count from counter, gauge, or formatted summary line
backup_metrics_extract_count() {
  local input="$1"
  local metric_name="$2"

  # Formatted summary: "  ✓ workspaces_stopped .................. 500"
  local formatted
  formatted=$(echo "$input" | grep -E "[✓✗ ] ${metric_name}[ .]+[0-9]" | head -1 | grep -oE '[0-9]+(\.[0-9]+)?$' || true)
  if [[ -n "$formatted" ]]; then
    printf '%s' "${formatted%%.*}"
    return 0
  fi
  local legacy_counter
  legacy_counter=$(echo "$input" | grep -E "^\s*✓?\s*✗?\s*${metric_name}" | head -1 | awk '{
    for (i=1; i<=NF; i++) {
      if ($i ~ /:$/ && $(i+1) ~ /^[0-9]+(\.[0-9]+)?$/) {
        printf "%s", $(i+1)
        exit
      }
      if ($i ~ /^[0-9]+$/ && $(i+1) ~ /^[0-9.]+\/s$/) {
        print $i
        exit
      }
    }
    print "0"
  }')
  if [[ -n "$legacy_counter" && "$legacy_counter" != "0" ]]; then
    printf '%s' "${legacy_counter%%.*}"
    return 0
  fi

  # Legacy gauge: "metric_name: 500 min=0 max=500"
  legacy_counter=$(echo "$input" | grep -E "^\s*✓?\s*✗?\s*${metric_name}" | head -1 | awk '{
    for (i=1; i<=NF; i++) {
      if ($i ~ /:$/ && $(i+1) ~ /^[0-9]+(\.[0-9]+)?$/) {
        printf "%s", $(i+1)
        exit
      }
    }
    print "0"
  }')
  if [[ -z "$legacy_counter" ]]; then
    echo "0"
    return 0
  fi
  printf '%s' "${legacy_counter%%.*}"
}

# Extract avg from trend metric (both formats)
backup_metrics_extract_avg() {
  local input="$1"
  local metric_name="$2"

  # Formatted summary: "restore_duration ... avg=5013 ms ..."
  local formatted
  formatted=$(echo "$input" | grep "${metric_name}" | grep 'avg=' | head -1 | sed -n 's/.*avg=\([0-9.]*\).*/\1/p')
  if [[ -n "$formatted" ]]; then
    printf '%s' "$formatted"
    return 0
  fi

  # Legacy k6 trend line
  local legacy_line
  legacy_line=$(echo "$input" | grep -E "^\s*✓?\s*✗?\s*${metric_name}" | head -1 || true)
  if [[ -z "$legacy_line" ]]; then
    echo "0"
    return 0
  fi
  echo "$legacy_line" | awk '{
    for (i=1; i<=NF; i++) {
      if ($i ~ /^avg=/) {
        printf "%s", substr($i, 5)
        exit
      }
    }
    printf "0"
  }'
}

# ImageStreamTag ratio: "imagestreamtags_backed_up .............. 500 / 500"
backup_metrics_extract_imagestreamtags() {
  local input="$1"
  local ratio
  ratio=$(echo "$input" | grep 'imagestreamtags_backed_up' | grep -oE '[0-9]+ / [0-9]+' | head -1 || true)
  if [[ -n "$ratio" ]]; then
    echo "$ratio"
    return 0
  fi
  # Legacy CSV line in formatted summary
  ratio=$(echo "$input" | grep 'imagestreams_created (CSV)' | grep -oE '[0-9]+ / [0-9]+' | head -1 || true)
  echo "$ratio"
}

# Map log metrics to legacy CSV columns (Config Type, DW Target, Backup Attempted, ...)
# Sets shell variables: BACKUP_ATTEMPTED, BACKUP_SUCCEEDED, BACKUP_PODS, BACKUP_FAILED,
# BACKUP_JOB_DURATION, RESTORE_*, AVG_* 
backup_metrics_map_legacy_csv() {
  local input="$1"
  local config_type="${2:-unknown}"

  BACKUP_ATTEMPTED=$(backup_metrics_extract_count "$input" "backup_jobs_total")
  BACKUP_SUCCEEDED=$(backup_metrics_extract_count "$input" "backup_jobs_succeeded")
  BACKUP_PODS=$(backup_metrics_extract_count "$input" "backup_pods_total")
  BACKUP_FAILED=$(backup_metrics_extract_count "$input" "backup_jobs_failed")
  BACKUP_JOB_DURATION=$(backup_metrics_extract_avg "$input" "backup_job_duration")

  # openshift-internal: use ImageStreamTag counts for attempted/succeeded when job totals are absent
  if [[ "$config_type" == *"openshift-internal"* ]] && [[ "${BACKUP_ATTEMPTED:-0}" -eq 0 ]]; then
    local ist_ratio backed_up expected
    ist_ratio=$(backup_metrics_extract_imagestreamtags "$input")
    if [[ -n "$ist_ratio" ]]; then
      backed_up=$(echo "$ist_ratio" | awk '{print $1}')
      expected=$(echo "$ist_ratio" | awk '{print $3}')
      BACKUP_ATTEMPTED="${expected:-0}"
      BACKUP_SUCCEEDED="${backed_up:-0}"
    else
      BACKUP_ATTEMPTED=$(backup_metrics_extract_count "$input" "workspaces_stopped")
      BACKUP_SUCCEEDED=$(backup_metrics_extract_count "$input" "workspaces_backed_up")
    fi
    if [[ "${BACKUP_FAILED:-0}" -eq 0 ]]; then
      BACKUP_FAILED=$(( BACKUP_ATTEMPTED - BACKUP_SUCCEEDED ))
      if [[ "$BACKUP_FAILED" -lt 0 ]]; then
        BACKUP_FAILED=0
      fi
    fi
  fi

  RESTORE_TOTAL=$(backup_metrics_extract_count "$input" "restore_workspaces_total")
  RESTORE_SUCCEEDED=$(backup_metrics_extract_count "$input" "restore_workspaces_succeeded")
  RESTORE_FAILED=$(backup_metrics_extract_count "$input" "restore_workspaces_failed")
  RESTORE_DURATION=$(backup_metrics_extract_avg "$input" "restore_duration")

  AVG_OP_CPU=$(backup_metrics_extract_avg "$input" "average_operator_cpu")
  AVG_OP_MEM=$(backup_metrics_extract_avg "$input" "average_operator_memory")
  AVG_ETCD_CPU=$(backup_metrics_extract_avg "$input" "average_etcd_cpu")
  AVG_ETCD_MEM=$(backup_metrics_extract_avg "$input" "average_etcd_memory")

  # Ensure numeric defaults for CSV consumers
  BACKUP_ATTEMPTED=${BACKUP_ATTEMPTED:-0}
  BACKUP_SUCCEEDED=${BACKUP_SUCCEEDED:-0}
  BACKUP_PODS=${BACKUP_PODS:-0}
  BACKUP_FAILED=${BACKUP_FAILED:-0}
  BACKUP_JOB_DURATION=${BACKUP_JOB_DURATION:-0}
  RESTORE_TOTAL=${RESTORE_TOTAL:-0}
  RESTORE_SUCCEEDED=${RESTORE_SUCCEEDED:-0}
  RESTORE_FAILED=${RESTORE_FAILED:-0}
  RESTORE_DURATION=${RESTORE_DURATION:-0}
  AVG_OP_CPU=${AVG_OP_CPU:-0}
  AVG_OP_MEM=${AVG_OP_MEM:-0}
  AVG_ETCD_CPU=${AVG_ETCD_CPU:-0}
  AVG_ETCD_MEM=${AVG_ETCD_MEM:-0}
}
