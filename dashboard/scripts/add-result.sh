#!/usr/bin/env bash
# Usage: dashboard/scripts/add-result.sh <release> <path/to/controller_load_test_results.csv>
# Copies a load test CSV into dashboard/results/<release>/ ready to commit.
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <release> <csv-file>" >&2
  exit 1
fi
release="$1"; csv="$2"
case "$release" in
  ""|*[!A-Za-z0-9._+-]*) echo "release name may only contain letters, digits, . _ + -" >&2; exit 1 ;;
esac
[ -f "$csv" ] || { echo "no such file: $csv" >&2; exit 1; }

here="$(cd "$(dirname "$0")/.." && pwd)"
dest="$here/results/$release"
mkdir -p "$dest"
cp "$csv" "$dest/controller_load_test_results.csv"
echo "Added $dest/controller_load_test_results.csv"
echo "Next: git add dashboard/results/$release && git commit -m 'Add load test results for $release' && git push"
