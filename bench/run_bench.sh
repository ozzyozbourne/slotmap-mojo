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

(cd rust && cargo bench --bench slotmap --no-run 2>&1 | tail -1)
(cd .. && mojo build -I . bench/mojo/bench_slotmap.mojo -o bench/mojo/bench_slotmap)
rm -rf rust/target/criterion results/mojo_*.csv

# Rust and Mojo alternate per map, so a drift in the machine's speed during
# the run lands on both sides of each ratio. The whole sequence runs twice
# (once in quick mode) and compare.py keeps each case's minimum: on a shared
# runner the minimum is the estimate least affected by interference.
passes=$([ "$quick" = 1 ] && echo 1 || echo 2)
for pass in $(seq 1 "$passes"); do
    for map in SlotMap HopSlotMap DenseSlotMap SecondaryMap SparseSecondaryMap; do
        echo "== Rust $map ($mode, pass $pass)"
        (cd rust && cargo bench --bench slotmap -- --noplot $([ "$quick" = 1 ] && echo --quick) "^$map/")
        echo "== Mojo $map ($mode, pass $pass)"
        SLOTMAP_BENCH_QUICK="$quick" SLOTMAP_BENCH_MAP="$map" mojo/bench_slotmap -o "results/mojo_${map}_$pass.csv"
    done
done

echo "== Comparison"
python3 compare.py --rust rust/target/criterion --mojo results/mojo_*.csv \
    --out results --mode "$mode"
