#![allow(deprecated)]
//! Quick micro-benchmarks for comparing against the Mojo probes.
use std::hint::black_box;
use std::time::Instant;
use slotmap::{DefaultKey, DenseSlotMap, HopSlotMap, Key, SlotMap};

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

#[inline(never)]
pub fn get_all(m: &SlotMap<DefaultKey, u64>, keys: &[DefaultKey]) -> u64 {
    let mut s = 0u64;
    for k in keys {
        s = s.wrapping_add(*m.get(*k).unwrap());
    }
    s
}

#[inline(never)]
pub fn iter_sum(m: &SlotMap<DefaultKey, u64>) -> u64 {
    let mut s = 0u64;
    for (_, v) in m.iter() {
        s = s.wrapping_add(*v);
    }
    s
}

fn main() {
    {
        let mut m = SlotMap::new();
        let keys: Vec<DefaultKey> = (0..1000u64).map(|i| m.insert(i)).collect();
        println!("{} {}", get_all(&m, &keys), iter_sum(&m));
    }
    for &n in &[100_000usize, 1_000_000] {
        println!("n = {n}");
        {
            let mut m = SlotMap::new();
            let keys: Vec<DefaultKey> = (0..n as u64).map(|i| m.insert(i)).collect();
            let mut sk = keys.clone();
            slotmap_bench::shuffle(&mut sk);
            best(|| get_all(&m, &sk), n, "  SlotMap get shuffled");
            best(|| iter_sum(&m), n, "  SlotMap iter (full)");
            let mut d = DenseSlotMap::new();
            let dkeys: Vec<DefaultKey> = (0..n as u64).map(|i| d.insert(i)).collect();
            let mut sdk = dkeys.clone();
            slotmap_bench::shuffle(&mut sdk);
            best(|| { let mut c = d.clone(); let mut s = 0u64; for k in &sdk { s = s.wrapping_add(c.remove(*k).unwrap_or(0)); } s }, n, "  Dense remove (incl. clone)");
            let mut h = HopSlotMap::new();
            let hkeys: Vec<DefaultKey> = (0..n as u64).map(|i| h.insert(i)).collect();
            let mut shk = hkeys.clone();
            slotmap_bench::shuffle(&mut shk);
            best(|| { let mut c = h.clone(); let mut s = 0u64; for k in &shk { s = s.wrapping_add(c.remove(*k).unwrap_or(0)); } s }, n, "  Hop remove (incl. clone)");
            best(|| { let mut c = m.clone(); let mut s = 0u64; for k in &sk { s = s.wrapping_add(c.remove(*k).unwrap_or(0)); } s }, n, "  SlotMap remove (incl. clone)");
        }
        best(|| { let mut m = SlotMap::new(); let mut s = 0u64; for i in 0..n as u64 { s += m.insert(i).data().as_ffi() & 0xffff_ffff; } s + m.len() as u64 }, n, "  SlotMap insert fresh (sum)");
        best(|| { let mut m: SlotMap<DefaultKey, u64> = SlotMap::with_capacity(n); let mut s = 0u64; for i in 0..n as u64 { s += m.insert(i).data().as_ffi() & 0xffff_ffff; } s + m.len() as u64 }, n, "  SlotMap insert presized (sum)");
        best(|| { let mut m = SlotMap::new(); for i in 0..n as u64 { black_box(m.insert(i)); } m.len() as u64 }, n, "  SlotMap insert fresh (black_box)");
        best(|| { let mut v = Vec::new(); for i in 0..n as u64 { v.push(i); } v.len() as u64 }, n, "  Vec push fresh");
    }
}
