#!/usr/bin/env bash
# Assembles the static dashboard into an output folder (default: dashboard/_site):
# copies the page, copies every results/<release>/controller_load_test_results.csv,
# and writes results/index.json listing the releases in version order.
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
out="${1:-$here/_site}"
csv_name="controller_load_test_results.csv"

rm -rf "$out"
mkdir -p "$out/results"
cp -r "$here/site/." "$out/"

first=1
{
  printf '{"releases":['
  while IFS= read -r release; do
    [ -f "$here/results/$release/$csv_name" ] || continue
    case "$release" in
      *[!A-Za-z0-9._+-]*) echo "skipping '$release': use only letters, digits, . _ + -" >&2; continue ;;
    esac
    mkdir -p "$out/results/$release"
    cp "$here/results/$release/$csv_name" "$out/results/$release/"
    [ "$first" = 1 ] || printf ','
    first=0
    printf '{"name":"%s","file":"results/%s/%s"}' "$release" "$release" "$csv_name"
  done < <(ls -1 "$here/results" | sort -V)
  printf ']}\n'
} > "$out/results/index.json"

echo "Built $out"
