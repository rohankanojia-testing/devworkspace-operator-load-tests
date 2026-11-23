#!/bin/bash
set -euo pipefail

# Trim raw k6 load-test logs down to the sections worth reading:
# the end-of-test summary (checks + custom metrics), the final progress
# line, any threshold-crossed errors, and the cleanup lines.
#
# Everything else (per-iteration HTTP noise, VU logs, setup chatter) is dropped.
# A single log that contains several test runs is split per run with a divider.
#
# Accepts a file, a directory, or stdin:
#   - file:       trims that file
#   - directory:  trims every *.log it finds (prefers a logs/ subdir, e.g. an
#                 outputs/run_*/ dir), one after another, each under a header
#   - stdin:      trims the piped stream
#
# Usage:
#   ./scripts/trim-loadtest-output.sh <logfile>
#   ./scripts/trim-loadtest-output.sh outputs/run_20261121_052623
#   ./scripts/trim-loadtest-output.sh outputs/run_20261121_052623/logs
#   ./scripts/trim-loadtest-output.sh < logfile
#   cat logfile | ./scripts/trim-loadtest-output.sh
#
# Options:
#   --start <regex>   Line that begins a summary block
#                     (default: the "DevWorkspace created" checks line)
#   -h, --help        Show this help

log_error() { echo -e "❌ $*" >&2; }
log_info()  { echo -e "ℹ️  $*" >&2; }

# Start of a summary block. The k6 end-of-test summary for these tests opens
# with the custom checks group, immediately followed by the indented metrics.
START_RE='✓[[:space:]]+DevWorkspace created'
INPUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --start)
      START_RE="$2"
      shift 2
      ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*)
      log_error "Unknown option: $1"
      exit 1
      ;;
    *)
      INPUT="$1"
      shift
      ;;
  esac
done

SEP="========================================"

# Core trimmer: reads one file (or stdin when given no path) and prints its
# trimmed summary block(s). Returns 2 when no block is found.
trim_stream() {
  local file="${1:-}"
  awk -v start_re="$START_RE" -v sep="$SEP" '
    function is_summary_line(l) {
      if (l ~ start_re)                                  return 1
      if (l ~ /[✓✗]/)                                   return 1   # check / metric status
      if (l ~ /[[:space:]]:[[:space:]]/)                return 1   # "metric...: avg=..." rows
      if (l ~ /(avg=|min=|max=|med=|p\(9[05]\)=)/)      return 1   # metric value rows
      if (l ~ /[0-9]+\.[0-9]+\/s|[0-9]+\/s/)            return 1   # counter rates
      if (l ~ /^running \(/)                            return 1   # final progress summary
      if (l ~ /VUs/ && l ~ /iters|iterations/)          return 1   # progress bar line
      if (l ~ /level=error.*thresholds/)                return 1   # threshold crossed
      if (l ~ /load test (failed|passed)/)              return 1
      if (l ~ /Stopping background watchers/)           return 1
      if (l ~ /Deleting Namespace|namespace .* deleted/) return 1
      if (l ~ /^Done$/)                                 return 1
      return 0
    }
    {
      if ($0 ~ start_re) {
        if (blocks > 0) print "\n" sep "\n"
        blocks++
        printing = 1
      }
      if (printing) {
        if (is_summary_line($0)) {
          print
          gap = 0
        } else {
          # Tolerate a single stray line inside a block; two in a row ends it.
          gap++
          if (gap >= 2) printing = 0
        }
      }
    }
    END { if (blocks == 0) exit 2 }
  ' ${file:+"$file"}
}

# Trim a single file, printing a banner, and report whether a block was found.
trim_one_file() {
  local file="$1"
  echo "################################################################"
  echo "# ${file}"
  echo "################################################################"
  if trim_stream "$file"; then
    echo
    return 0
  else
    echo "  (no k6 summary block found)"
    echo
    return 1
  fi
}

# --- stdin mode ---------------------------------------------------------------
if [[ -z "$INPUT" ]]; then
  if trim_stream; then
    exit 0
  else
    log_error "No summary block found (start pattern not matched)."
    exit 2
  fi
fi

if [[ ! -e "$INPUT" ]]; then
  log_error "No such file or directory: ${INPUT}"
  exit 1
fi

# --- single file mode ---------------------------------------------------------
if [[ -f "$INPUT" ]]; then
  trim_stream "$INPUT" || { log_error "No summary block found in ${INPUT}."; exit 2; }
  exit 0
fi

# --- directory mode -----------------------------------------------------------
# Prefer a logs/ subdir (outputs/run_*/logs), else *.log directly in the dir.
search_dir="$INPUT"
if [[ -d "${INPUT}/logs" ]]; then
  search_dir="${INPUT}/logs"
fi

logfiles=()
while IFS= read -r f; do
  logfiles+=("$f")
done < <(find "$search_dir" -maxdepth 1 -type f -name '*.log' | sort)

if [[ ${#logfiles[@]} -eq 0 ]]; then
  log_error "No *.log files found in ${search_dir}"
  exit 1
fi

log_info "Trimming ${#logfiles[@]} log file(s) from ${search_dir}"
found=0
for f in "${logfiles[@]}"; do
  if trim_one_file "$f"; then
    found=$((found + 1))
  fi
done

log_info "Found summary blocks in ${found}/${#logfiles[@]} log file(s)."
