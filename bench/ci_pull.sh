#!/usr/bin/env bash
# Downloads a Benchmark workflow run's results into bench/history and prints
# the table with a "was" column against the previous history file.
#
#   bench/ci_pull.sh <run-id> <NN-shortsha-name>     e.g. 36059220385 02-660560d-layout
set -euo pipefail
cd "$(dirname "$0")"
run="$1"; name="$2"
tmp=$(mktemp -d)
gh run download "$run" -n bench-results -D "$tmp" >/dev/null
prev=$(ls history/*.json 2>/dev/null | grep -v log.json | sort | tail -1 || true)
cp "$tmp/results/results.json" "history/$name.json"
python3 compare.py --rust "$tmp/rust/target/criterion" --mojo "$tmp"/results/mojo*.csv \
    --out "$tmp/out" --mode thorough ${prev:+--baseline "$prev"} | sed -n '1,400p'
echo "saved history/$name.json (baseline was ${prev:-none})"
rm -rf "$tmp"
