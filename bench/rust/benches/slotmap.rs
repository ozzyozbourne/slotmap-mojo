//! Criterion benchmarks for the Rust `slotmap` crate. The Mojo port runs the
//! same workloads in `bench/mojo/bench_slotmap.mojo`; `bench/compare.py`
//! joins the results.
//!
//! Every benchmark times one pass over `n` elements. Setup that must be fresh
//! for each pass (an empty map to insert into, a full map to remove from) is
//! excluded from the timing with `iter_batched`. `BatchSize::PerIteration`
//! runs setup immediately before each timed pass, exactly like Mojo's
//! `Bencher.iter_preproc`, so both languages see the same cache state.
#![allow(deprecated)] // HopSlotMap is deprecated upstream.

use std::hint::black_box;

use criterion::{criterion_group, criterion_main, BatchSize, BenchmarkId, Criterion};
use slotmap::{DefaultKey, DenseSlotMap, HopSlotMap, SecondaryMap, SlotMap, SparseSecondaryMap};
use slotmap_bench::shuffle;

const SIZES: [usize; 3] = [1_000, 100_000, 1_000_000];

/// SlotMap, HopSlotMap and DenseSlotMap share an API, so one macro covers all
/// three: insert, get, remove, iterate a half-empty map, and re-insert into
/// freed slots.
macro_rules! primary {
    ($c:expr, $name:literal, $map:ident) => {{
        let mut group = $c.benchmark_group($name);
        for n in SIZES {
            let mut full = $map::<DefaultKey, u64>::new();
            let mut keys: Vec<DefaultKey> = (0..n as u64).map(|i| full.insert(i)).collect();
            shuffle(&mut keys);

            // Half the elements removed in random order: iteration must skip
            // the holes.
            let mut half = full.clone();
            for k in &keys[..n / 2] {
                half.remove(*k);
            }

            // All elements removed: inserting reuses the free list.
            let mut emptied = full.clone();
            for k in &keys {
                emptied.remove(*k);
            }

            group.bench_with_input(BenchmarkId::new("insert", n), &n, |b, &n| {
                b.iter_batched(
                    $map::<DefaultKey, u64>::new,
                    |mut m| {
                        for i in 0..n as u64 {
                            black_box(m.insert(i));
                        }
                        m
                    },
                    BatchSize::PerIteration,
                )
            });
            group.bench_with_input(BenchmarkId::new("get", n), &n, |b, _| {
                b.iter(|| {
                    let mut sum = 0u64;
                    for k in &keys {
                        sum = sum.wrapping_add(*full.get(*k).unwrap());
                    }
                    black_box(sum)
                })
            });
            group.bench_with_input(BenchmarkId::new("remove", n), &n, |b, _| {
                b.iter_batched(
                    || full.clone(),
                    |mut m| {
                        for k in &keys {
                            black_box(m.remove(*k));
                        }
                        m
                    },
                    BatchSize::PerIteration,
                )
            });
            group.bench_with_input(BenchmarkId::new("iter_half", n), &n, |b, _| {
                b.iter(|| {
                    let mut sum = 0u64;
                    for (_, v) in half.iter() {
                        sum = sum.wrapping_add(*v);
                    }
                    black_box(sum)
                })
            });
            group.bench_with_input(BenchmarkId::new("reinsert", n), &n, |b, &n| {
                b.iter_batched(
                    || emptied.clone(),
                    |mut m| {
                        for i in 0..n as u64 {
                            black_box(m.insert(i));
                        }
                        m
                    },
                    BatchSize::PerIteration,
                )
            });
        }
        group.finish();
    }};
}

/// SecondaryMap and SparseSecondaryMap: insert, get, remove and iterate, with
/// keys from a SlotMap.
macro_rules! secondary {
    ($c:expr, $name:literal, $new:expr) => {{
        let mut group = $c.benchmark_group($name);
        for n in SIZES {
            let mut sm = SlotMap::<DefaultKey, u64>::new();
            let mut keys: Vec<DefaultKey> = (0..n as u64).map(|i| sm.insert(i)).collect();
            shuffle(&mut keys);
            let mut full = $new();
            for (i, k) in keys.iter().enumerate() {
                full.insert(*k, i as u64);
            }

            group.bench_with_input(BenchmarkId::new("insert", n), &n, |b, _| {
                b.iter_batched(
                    $new,
                    |mut m| {
                        for (i, k) in keys.iter().enumerate() {
                            black_box(m.insert(*k, i as u64));
                        }
                        m
                    },
                    BatchSize::PerIteration,
                )
            });
            group.bench_with_input(BenchmarkId::new("get", n), &n, |b, _| {
                b.iter(|| {
                    let mut sum = 0u64;
                    for k in &keys {
                        sum = sum.wrapping_add(*full.get(*k).unwrap());
                    }
                    black_box(sum)
                })
            });
            group.bench_with_input(BenchmarkId::new("remove", n), &n, |b, _| {
                b.iter_batched(
                    || full.clone(),
                    |mut m| {
                        for k in &keys {
                            black_box(m.remove(*k));
                        }
                        m
                    },
                    BatchSize::PerIteration,
                )
            });
            group.bench_with_input(BenchmarkId::new("iter", n), &n, |b, _| {
                b.iter(|| {
                    let mut sum = 0u64;
                    for (_, v) in full.iter() {
                        sum = sum.wrapping_add(*v);
                    }
                    black_box(sum)
                })
            });
        }
        group.finish();
    }};
}

fn benches(c: &mut Criterion) {
    primary!(c, "SlotMap", SlotMap);
    primary!(c, "HopSlotMap", HopSlotMap);
    primary!(c, "DenseSlotMap", DenseSlotMap);
    secondary!(c, "SecondaryMap", SecondaryMap::<DefaultKey, u64>::new);
    // aHash, to match Mojo's default `Dict` hasher (AHasher).
    secondary!(
        c,
        "SparseSecondaryMap",
        SparseSecondaryMap::<DefaultKey, u64, ahash::RandomState>::default
    );
}

criterion_group!(slotmap_benches, benches);
criterion_main!(slotmap_benches);
