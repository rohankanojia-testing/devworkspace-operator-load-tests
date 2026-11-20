#!/usr/bin/env bash
# Assembles the static dashboard into an output folder (default: dashboard/_site):
# copies the page, copies each release's result CSVs, and writes results/index.json
# listing the releases in version order with the test types each one has.
#
# A release folder may hold any of:
#   controller_load_test_results.csv, webhook_load_test_results.csv, backup_load_test_results.csv
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
out="${1:-$here/_site}"
types="controller webhook backup"

rm -rf "$out"
mkdir -p "$out/results"
cp -r "$here/site/." "$out/"

first=1
{
  printf '{"releases":['
  while IFS= read -r release; do
    [ -d "$here/results/$release" ] || continue
    case "$release" in
      *[!A-Za-z0-9._+-]*) echo "skipping '$release': use only letters, digits, . _ + -" >&2; continue ;;
    esac
    files=""
    for type in $types; do
      csv="${type}_load_test_results.csv"
      [ -f "$here/results/$release/$csv" ] || continue
      mkdir -p "$out/results/$release"
      cp "$here/results/$release/$csv" "$out/results/$release/"
      [ -z "$files" ] || files="$files,"
      files="$files\"$type\":\"results/$release/$csv\""
    done
    [ -n "$files" ] || continue
    [ "$first" = 1 ] || printf ','
    first=0
    printf '{"name":"%s","files":{%s}}' "$release" "$files"
  done < <(ls -1 "$here/results" | sort -V)
  printf ']}\n'
} > "$out/results/index.json"

echo "Built $out"
