#!/usr/bin/env bash
# Usage: dashboard/scripts/add-result.sh <release> <csv-file> [controller|webhook|backup]
# Copies a load test CSV into dashboard/results/<release>/ under the name the
# dashboard expects. The test type defaults to controller.
set -euo pipefail

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "usage: $0 <release> <csv-file> [controller|webhook|backup]" >&2
  exit 1
fi
release="$1"; csv="$2"; type="${3:-controller}"
case "$release" in
  ""|*[!A-Za-z0-9._+-]*) echo "release name may only contain letters, digits, . _ + -" >&2; exit 1 ;;
esac
case "$type" in
  controller|webhook|backup) ;;
  *) echo "test type must be controller, webhook or backup" >&2; exit 1 ;;
esac
[ -f "$csv" ] || { echo "no such file: $csv" >&2; exit 1; }

here="$(cd "$(dirname "$0")/.." && pwd)"
dest="$here/results/$release"
mkdir -p "$dest"
cp "$csv" "$dest/${type}_load_test_results.csv"
echo "Added $dest/${type}_load_test_results.csv"
echo "Next: git add dashboard/results/$release && git commit -m 'chore(dashboard): add $type load test results for $release' && git push"
