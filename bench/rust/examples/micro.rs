//! Quick micro-benchmarks for comparing against the Mojo probes.
use std::hint::black_box;
use std::time::Instant;
use slotmap::{DefaultKey, Key, SlotMap};

fn best<F: FnMut() -> u64>(mut f: F, n: usize, name: &str) {
    let mut b = u128::MAX;
    for _ in 0..20 {
        let t0 = Instant::now();
        let s = f();
        let d = t0.elapsed().as_nanos();
        black_box(s);
        b = b.min(d);
    }
    println!("{name} {:.2} ns/elem", b as f64 / n as f64);
}

fn main() {
    for &n in &[100_000usize, 1_000_000] {
        println!("n = {n}");
        best(|| { let mut m = SlotMap::new(); let mut s = 0u64; for i in 0..n as u64 { s += m.insert(i).data().as_ffi() & 0xffff_ffff; } s + m.len() as u64 }, n, "  SlotMap insert fresh (sum)");
        best(|| { let mut m: SlotMap<DefaultKey, u64> = SlotMap::with_capacity(n); let mut s = 0u64; for i in 0..n as u64 { s += m.insert(i).data().as_ffi() & 0xffff_ffff; } s + m.len() as u64 }, n, "  SlotMap insert presized (sum)");
        best(|| { let mut m = SlotMap::new(); for i in 0..n as u64 { black_box(m.insert(i)); } m.len() as u64 }, n, "  SlotMap insert fresh (black_box)");
        best(|| { let mut v = Vec::new(); for i in 0..n as u64 { v.push(i); } v.len() as u64 }, n, "  Vec push fresh");
    }
}
