#!/usr/bin/env bash
# Builds and runs the Rust (Criterion) and Mojo (std.benchmark) benchmarks,
# then joins the results with compare.py into bench/results/.
#
# Thorough by default (about 25 minutes). SLOTMAP_BENCH_QUICK=1 does a short
# smoke run instead. Run from the pixi environment: `pixi run bench`.
set -euo pipefail
cd "$(dirname "$0")"
quick="${SLOTMAP_BENCH_QUICK:-0}"
mode=$([ "$quick" = 1 ] && echo quick || echo thorough)
mkdir -p results

echo "== Rust ($mode)"
rm -rf rust/target/criterion
(cd rust && cargo bench --bench slotmap -- --noplot $([ "$quick" = 1 ] && echo --quick))

echo "== Mojo ($mode)"
(cd .. && mojo build -I . bench/mojo/bench_slotmap.mojo -o bench/mojo/bench_slotmap)
SLOTMAP_BENCH_QUICK="$quick" mojo/bench_slotmap -o results/mojo.csv

echo "== Comparison"
python3 compare.py --rust rust/target/criterion --mojo results/mojo.csv \
    --out results --mode "$mode"
